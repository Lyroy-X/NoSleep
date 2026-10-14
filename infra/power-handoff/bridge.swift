import Foundation
import IOKit.pwr_mgt
import CryptoKit
import Darwin

// Standalone assertion bridge. There is deliberately no global power setter,
// NoSleep lifecycle call, or operator signal sender in this executable.
enum BridgeError: String, Error {
    case sleepDisabledRequired, powerReadFailed, assertionCreateFailed, assertionNotHeld
    case processIdentityFailed, targetProofFailed, oldStillPresent, oldNotResumed
    case invalidArguments, privateDirectoryRequired, commandRefused, guestOnly
    case handoffFailed, persistenceFailed
}
struct BridgeFailures: Codable, Equatable {
    var global = false, assertion = false, read = false, persistence = false
    var any: Bool { global || assertion || read || persistence }
}
enum FailureKind { case global, assertion, read, persistence }
enum ReleaseAction: String { case new = "released-to-new", resumedOld = "released-to-old", restartedOld = "released-to-restarted-old" }
protocol BridgePersistence {
    func failure(_ flags: BridgeFailures) throws
    func prepare(_ action: ReleaseAction, pid: Int32) throws
    func completed(_ action: ReleaseAction, pid: Int32) throws
}
struct ClosurePersistence: BridgePersistence {
    let writeFailure: (BridgeFailures) throws -> Void
    let writePrepared: (ReleaseAction, Int32) throws -> Void
    let writeCompleted: (ReleaseAction, Int32) throws -> Void
    func failure(_ flags: BridgeFailures) throws { try writeFailure(flags) }
    func prepare(_ action: ReleaseAction, pid: Int32) throws { try writePrepared(action, pid) }
    func completed(_ action: ReleaseAction, pid: Int32) throws { try writeCompleted(action, pid) }
}
enum AssertionKind: String, CaseIterable, Hashable { case idle = "PreventUserIdleSystemSleep", display = "PreventUserIdleDisplaySleep" }
protocol PowerAccess {
    func sleepDisabled() throws -> Bool
    func create(_ kind: AssertionKind) throws -> UInt32
    func held(_ id: UInt32) -> Bool
    func release(_ id: UInt32)
    func assertionsHeld(_ kinds: [AssertionKind], by pid: Int32) throws -> Bool
}
struct ProcessIdentity: Codable, Equatable {
    let pid: Int32, executable: String, sha256: String
    let startSeconds: UInt64, startMicroseconds: UInt64, status: UInt32
    func sameLifetime(as other: ProcessIdentity) -> Bool {
        pid == other.pid && executable == other.executable && sha256 == other.sha256 &&
            startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
    }
}
protocol IdentityAccess { func read(_ pid: Int32) throws -> ProcessIdentity? }
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

final class RealIdentity: IdentityAccess {
    func read(_ pid: Int32) throws -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if count == 0 {
            if errno == ESRCH { return nil }
            throw BridgeError.processIdentityFailed
        }
        guard count == MemoryLayout<proc_bsdinfo>.size, info.pbi_uid == getuid() else { throw BridgeError.processIdentityFailed }
        if info.pbi_status == 5 { return nil } // SZOMB: cannot execute user cleanup.
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw BridgeError.processIdentityFailed }
        let executable = String(cString: path)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe)
        guard bytes.count <= 64 * 1024 * 1024 else { throw BridgeError.processIdentityFailed }
        return ProcessIdentity(pid: pid, executable: executable, sha256: sha256(bytes),
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, status: info.pbi_status)
    }
}
final class RealPower: PowerAccess {
    let name = "NoSleep power handoff " + UUID().uuidString
    func sleepDisabled() throws -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { throw BridgeError.powerReadFailed }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { throw BridgeError.powerReadFailed }
        return value.boolValue
    }
    func create(_ kind: AssertionKind) throws -> UInt32 {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(kind.rawValue as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            (name + " " + kind.rawValue) as CFString, &id)
        guard status == kIOReturnSuccess, id != 0 else { throw BridgeError.assertionCreateFailed }
        return id
    }
    func held(_ id: UInt32) -> Bool {
        guard let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else { return false }
        return (properties[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn)
    }
    func release(_ id: UInt32) { _ = IOPMAssertionRelease(id) }
    func assertionsHeld(_ kinds: [AssertionKind], by pid: Int32) throws -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dictionary = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { throw BridgeError.powerReadFailed }
        let entries = dictionary[NSNumber(value: pid)] ?? []
        let types = Set(entries.compactMap { item -> String? in
            guard (item[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn) else { return nil }
            return item[kIOPMAssertionTypeKey] as? String
        })
        return kinds.allSatisfy { types.contains($0.rawValue) }
    }
}

final class AssertionBridge {
    let power: PowerAccess
    let wantedDisplay: Bool
    let persistence: BridgePersistence
    private(set) var failures = BridgeFailures()
    private(set) var sampledSleepDisabled: Bool?
    var requiredAssertions: [AssertionKind] { wantedDisplay ? [.idle, .display] : [.idle] }
    private(set) var owned: [UInt32] = []
    init(_ power: PowerAccess, wantedDisplay: Bool, persistence: BridgePersistence) {
        self.power = power; self.wantedDisplay = wantedDisplay; self.persistence = persistence
    }
    func noteFailure(_ kind: FailureKind) throws {
        let prior = failures
        switch kind {
        case .global: failures.global = true
        case .assertion: failures.assertion = true
        case .read: failures.read = true
        case .persistence: failures.persistence = true
        }
        guard failures != prior else { return }
        do { try persistence.failure(failures) }
        catch {
            failures.persistence = true
            try? persistence.failure(failures)
            throw BridgeError.persistenceFailed
        }
    }
    func observeProtection() throws {
        if !bothOwnedHeld { try noteFailure(.assertion) }
        do {
            let disabled = try power.sleepDisabled(); sampledSleepDisabled = disabled
            if !disabled { try noteFailure(.global) }
        }
        catch let error as BridgeError where error == .persistenceFailed { throw error }
        catch { sampledSleepDisabled = nil; try noteFailure(.read) }
        guard !failures.any else { throw BridgeError.handoffFailed }
    }
    private func readIdentity(_ pid: Int32, using identity: IdentityAccess) throws -> ProcessIdentity? {
        do { return try identity.read(pid) }
        catch { try noteFailure(.read); throw BridgeError.handoffFailed }
    }
    private func requiredHeld(by pid: Int32) throws -> Bool {
        do { return try power.assertionsHeld(requiredAssertions, by: pid) }
        catch { try noteFailure(.read); throw BridgeError.handoffFailed }
    }
    func start() throws {
        guard owned.isEmpty else { throw BridgeError.assertionCreateFailed }
        guard try power.sleepDisabled() else { throw BridgeError.sleepDisabledRequired }
        do {
            for kind in AssertionKind.allCases {
                let id = try power.create(kind); owned.append(id)
                guard power.held(id) else { throw BridgeError.assertionNotHeld }
            }
            guard try power.sleepDisabled() else { throw BridgeError.sleepDisabledRequired }
        } catch { releaseOwned(); throw error }
    }
    var bothOwnedHeld: Bool { owned.count == 2 && owned.allSatisfy { power.held($0) } }
    func releaseOwned() { for id in owned { power.release(id) }; owned.removeAll() }
    private func finalProof(_ target: ProcessIdentity, identity: IdentityAccess) throws {
        try observeProtection()
        guard let before = try readIdentity(target.pid, using: identity), before.sameLifetime(as: target), before.status != 4,
              try requiredHeld(by: target.pid),
              let after = try readIdentity(target.pid, using: identity), after.sameLifetime(as: target), after.status != 4,
              try requiredHeld(by: target.pid),
              let confirmed = try readIdentity(target.pid, using: identity), confirmed.sameLifetime(as: target), confirmed.status != 4 else { throw BridgeError.targetProofFailed }
        try observeProtection() // After the last slow PID/assertion/hash read, before own release.
    }
    private func transfer(_ action: ReleaseAction, target: ProcessIdentity, identity: IdentityAccess) throws {
        do { try persistence.prepare(action, pid: target.pid) }
        catch { try noteFailure(.persistence); throw BridgeError.persistenceFailed }
        do { try finalProof(target, identity: identity) }
        catch let error as BridgeError { throw error }
        catch { try noteFailure(.read); throw BridgeError.handoffFailed }
        releaseOwned()
        do { try persistence.completed(action, pid: target.pid) }
        catch {
            // A failed completion receipt is never a successful handoff. Rehold
            // only this bridge's assertions while global/target protection exists.
            try? start()
            try noteFailure(.persistence)
            throw BridgeError.persistenceFailed
        }
    }
    func releaseToNew(pid: Int32, old: ProcessIdentity, expectedPath: String, expectedSHA: String, identity: IdentityAccess, action: ReleaseAction = .new) throws {
        try observeProtection()
        guard pid > 1, pid != old.pid, pid != getpid() else { throw BridgeError.targetProofFailed }
        guard try readIdentity(old.pid, using: identity) == nil else { throw BridgeError.oldStillPresent }
        guard let target = try readIdentity(pid, using: identity), target.executable == expectedPath, target.sha256 == expectedSHA,
              target.status != 4, try requiredHeld(by: pid),
              let confirmed = try readIdentity(pid, using: identity), confirmed.sameLifetime(as: target), confirmed.status != 4 else { throw BridgeError.targetProofFailed }
        try transfer(action, target: target, identity: identity)
    }
    func abortAfterOldResumed(old: ProcessIdentity, identity: IdentityAccess) throws {
        try observeProtection()
        guard let target = try readIdentity(old.pid, using: identity), target.sameLifetime(as: old),
              target.status != 4, try requiredHeld(by: old.pid),
              let confirmed = try readIdentity(old.pid, using: identity), confirmed.sameLifetime(as: old), confirmed.status != 4 else { throw BridgeError.oldNotResumed }
        try transfer(.resumedOld, target: target, identity: identity)
    }
}

struct Command: Decodable { let session: String, request: UUID, action: String; let pid: Int32? }
struct Snapshot: Codable {
    let session: String, pid: Int32, old: ProcessIdentity, newExecutable: String, newSHA256: String
    let wantedDisplay: Bool
    var phase = "holding", samples = 0, sleepDisabled = false, ownAssertionsOn = false
    var globalFailureObserved = false, assertionFailureObserved = false, readFailureObserved = false
    var persistenceFailureObserved = false
    var releaseTargetPID: Int32?
    var request: UUID?
    var lastCommand = "none"
    mutating func record(_ flags: BridgeFailures) {
        globalFailureObserved = flags.global; assertionFailureObserved = flags.assertion
        readFailureObserved = flags.read; persistenceFailureObserved = flags.persistence
    }
}
func privateDirectory(_ path: String) throws -> URL {
    var info = stat()
    guard path.hasPrefix("/"), lstat(path, &info) == 0, info.st_uid == getuid(),
          info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw BridgeError.privateDirectoryRequired }
    return URL(fileURLWithPath: path, isDirectory: true)
}
enum HandoffEventKind: String, Codable { case holding, failure, prepared, released, refused }
struct HandoffEvent: Codable {
    let session: String, kind: HandoffEventKind, uptime: TimeInterval, phase: String
    let globalFailure: Bool, assertionFailure: Bool, readFailure: Bool, persistenceFailure: Bool
    let ownAssertionsOn: Bool, targetPID: Int32?, request: UUID?
}
func writeAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BridgeError.persistenceFailed }; offset += count
        }
    }
}
func flush(_ fd: Int32) throws {
    while fsync(fd) != 0 { if errno != EINTR { throw BridgeError.persistenceFailed } }
}
func saveSnapshot(_ value: Snapshot, to path: URL, event: HandoffEventKind? = nil) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bytes = try encoder.encode(value)
    guard bytes.count < 8192 else { throw BridgeError.commandRefused }
    _ = try privateDirectory(path.deletingLastPathComponent().path)
    let directory = open(path.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw BridgeError.persistenceFailed }
    defer { close(directory) }
    if let event {
        let item = HandoffEvent(session: value.session, kind: event, uptime: ProcessInfo.processInfo.systemUptime,
            phase: value.phase, globalFailure: value.globalFailureObserved, assertionFailure: value.assertionFailureObserved,
            readFailure: value.readFailureObserved, persistenceFailure: value.persistenceFailureObserved,
            ownAssertionsOn: value.ownAssertionsOn, targetPID: value.releaseTargetPID, request: value.request)
        let eventEncoder = JSONEncoder(); eventEncoder.outputFormatting = [.sortedKeys]
        var data = try eventEncoder.encode(item); data.append(0x0a)
        guard data.count <= 1024 else { throw BridgeError.persistenceFailed }
        let events = openat(directory, "events.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard events >= 0 else { throw BridgeError.persistenceFailed }
        defer { close(events) }
        var info = stat()
        guard fstat(events, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size + Int64(data.count) <= 65536 else { throw BridgeError.persistenceFailed }
        try writeAll(data, fd: events); try flush(events); try flush(directory)
    }
    let name = "state." + UUID().uuidString + ".tmp"
    let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw BridgeError.persistenceFailed }
    defer { close(descriptor); _ = unlinkat(directory, name, 0) }
    try writeAll(bytes, fd: descriptor); try flush(descriptor)
    guard renameat(directory, name, directory, path.lastPathComponent) == 0 else { throw BridgeError.persistenceFailed }
    try flush(directory)
}
func commandBytes(_ path: URL) throws -> Data? {
    var before = stat()
    if lstat(path.path, &before) != 0 { if errno == ENOENT { return nil }; throw BridgeError.commandRefused }
    guard before.st_uid == getuid(), before.st_mode & S_IFMT == S_IFREG,
          before.st_mode & 0o077 == 0, before.st_size <= 1024 else { throw BridgeError.commandRefused }
    let bytes = try Data(contentsOf: path)
    var after = stat()
    guard bytes.count <= 1024, lstat(path.path, &after) == 0,
          before.st_ino == after.st_ino, before.st_dev == after.st_dev else { throw BridgeError.commandRefused }
    return bytes
}
func hold(_ arguments: [String]) throws {
    var options: [String: String] = [:]
    guard arguments.count == 16 else { throw BridgeError.invalidArguments }
    for offset in stride(from: 0, to: arguments.count, by: 2) {
        guard options[arguments[offset]] == nil else { throw BridgeError.invalidArguments }
        options[arguments[offset]] = arguments[offset + 1]
    }
    guard Set(options.keys) == Set(["--old-pid", "--old-executable", "--old-sha256", "--new-executable", "--new-sha256", "--state-dir", "--session", "--wanted-display"]),
          let displayValue = options["--wanted-display"], displayValue == "0" || displayValue == "1",
          let oldPID = options["--old-pid"].flatMap(Int32.init), oldPID > 1, oldPID != getpid(),
          let oldPath = options["--old-executable"], oldPath.hasPrefix("/"),
          let oldSHA = options["--old-sha256"], oldSHA.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          let newPath = options["--new-executable"], newPath.hasPrefix("/"),
          let newSHA = options["--new-sha256"], newSHA.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          let session = options["--session"], UUID(uuidString: session) != nil else { throw BridgeError.invalidArguments }
    let directory = try privateDirectory(options["--state-dir"]!)
    let state = directory.appendingPathComponent("state.json"), command = directory.appendingPathComponent("command.json")
    guard !FileManager.default.fileExists(atPath: state.path), !FileManager.default.fileExists(atPath: command.path) else { throw BridgeError.privateDirectoryRequired }
    let identities = RealIdentity()
    guard let old = try identities.read(oldPID), old.executable == oldPath, old.sha256 == oldSHA, old.status != 4 else { throw BridgeError.processIdentityFailed }
    var snapshot = Snapshot(session: session, pid: getpid(), old: old, newExecutable: newPath, newSHA256: newSHA,
                            wantedDisplay: displayValue == "1")
    weak var observedBridge: AssertionBridge?
    let persistence = ClosurePersistence(writeFailure: { flags in
        snapshot.record(flags); snapshot.phase = "failed-holding"
        snapshot.ownAssertionsOn = observedBridge?.bothOwnedHeld == true
        snapshot.sleepDisabled = observedBridge?.sampledSleepDisabled ?? false
        try saveSnapshot(snapshot, to: state, event: .failure)
    }, writePrepared: { _, pid in
        snapshot.phase = "release-prepared"; snapshot.releaseTargetPID = pid
        snapshot.lastCommand = "prepared"
        snapshot.ownAssertionsOn = observedBridge?.bothOwnedHeld == true
        try saveSnapshot(snapshot, to: state, event: .prepared)
    }, writeCompleted: { action, pid in
        snapshot.phase = action.rawValue; snapshot.releaseTargetPID = pid; snapshot.ownAssertionsOn = false
        snapshot.lastCommand = "accepted"
        try saveSnapshot(snapshot, to: state, event: .released)
    })
    let bridge = AssertionBridge(RealPower(), wantedDisplay: displayValue == "1", persistence: persistence)
    observedBridge = bridge; try bridge.start()
    // Terminal interruption must not silently end a handoff. Only a verified
    // control request releases these assertions. SIGKILL/crash remain OS limits.
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN); signal(SIGHUP, SIG_IGN)
    var lastRequest: UUID?, lastSave: TimeInterval = 0
    snapshot.ownAssertionsOn = bridge.bothOwnedHeld; snapshot.sleepDisabled = true
    do { try saveSnapshot(snapshot, to: state, event: .holding) }
    catch { try? bridge.noteFailure(.persistence) } // Keep holding even without a writable receipt.
    print("{\"bridgeHolding\":true,\"ownsIdleAndDisplayAssertions\":true,\"globalPowerWrites\":0}"); fflush(stdout)
    while !bridge.owned.isEmpty {
        var commandWasNew = false
        snapshot.samples += 1; snapshot.ownAssertionsOn = bridge.bothOwnedHeld
        do { try bridge.observeProtection() } catch {}
        snapshot.sleepDisabled = bridge.sampledSleepDisabled ?? false
        snapshot.record(bridge.failures)
        do {
            if let bytes = try commandBytes(command) {
                let request = try JSONDecoder().decode(Command.self, from: bytes)
                guard request.session == session else { throw BridgeError.commandRefused }
                if request.request != lastRequest {
                    lastRequest = request.request
                    snapshot.request = request.request
                    commandWasNew = true
                    guard !bridge.failures.any else { throw BridgeError.handoffFailed }
                    switch request.action {
                    case "release-new":
                        guard let pid = request.pid else { throw BridgeError.commandRefused }
                        try bridge.releaseToNew(pid: pid, old: old, expectedPath: newPath, expectedSHA: newSHA, identity: identities)
                        snapshot.phase = "released-to-new"
                    case "abort-old-resumed":
                        try bridge.abortAfterOldResumed(old: old, identity: identities); snapshot.phase = "released-to-old"
                    case "rollback-old-restarted":
                        guard let pid = request.pid else { throw BridgeError.commandRefused }
                        try bridge.releaseToNew(pid: pid, old: old, expectedPath: old.executable, expectedSHA: old.sha256, identity: identities, action: .restartedOld)
                        snapshot.phase = "released-to-restarted-old"
                    default: throw BridgeError.commandRefused
                    }
                    snapshot.lastCommand = "accepted"
                }
            }
        } catch {
            snapshot.lastCommand = (error as? BridgeError)?.rawValue ?? "commandRefused"
            snapshot.record(bridge.failures)
            if bridge.failures.any { snapshot.phase = "failed-holding" }
            else { snapshot.phase = "holding" }
            if commandWasNew {
                do { try saveSnapshot(snapshot, to: state, event: .refused) }
                catch { try? bridge.noteFailure(.persistence); snapshot.record(bridge.failures) }
            }
        }
        if bridge.owned.isEmpty { snapshot.ownAssertionsOn = false }
        let now = ProcessInfo.processInfo.systemUptime
        // A completed transfer already wrote and flushed its final receipt.
        // Avoid a redundant post-release write that could fail after protection transfer.
        if !bridge.owned.isEmpty && now - lastSave >= 1 {
            do { try saveSnapshot(snapshot, to: state); lastSave = now }
            catch { try? bridge.noteFailure(.persistence); snapshot.record(bridge.failures) }
        }
        if !bridge.owned.isEmpty { Thread.sleep(forTimeInterval: 0.1) }
    }
    guard !bridge.failures.any else { throw BridgeError.handoffFailed }
}

func readHardware(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process(), pipe = Pipe(), finished = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in finished.signal() }; try process.run()
    guard finished.wait(timeout: .now() + 5) == .success else { process.terminate(); throw BridgeError.guestOnly }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0, data.count <= 8192 else { throw BridgeError.guestOnly }
    return String(decoding: data, as: UTF8.self)
}
func laboratoryLifecycle() throws {
    guard getuid() == 501, try readHardware("/usr/sbin/sysctl", ["-n", "hw.model"]).hasPrefix("VirtualMac"),
          try readHardware("/sbin/ifconfig", ["en0"]).contains("ether 42:35:8c:14:fd:0c") else { throw BridgeError.guestOnly }
    let noHandoffPersistence = ClosurePersistence(writeFailure: { _ in throw BridgeError.persistenceFailed },
        writePrepared: { _, _ in throw BridgeError.persistenceFailed }, writeCompleted: { _, _ in throw BridgeError.persistenceFailed })
    let power = RealPower(), bridge = AssertionBridge(power, wantedDisplay: true, persistence: noHandoffPersistence), before = try power.sleepDisabled()
    guard let identity = try RealIdentity().read(getpid()), identity.pid == getpid(),
          identity.executable == URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path else { throw BridgeError.processIdentityFailed }
    // The operator primes only the already-owned VM, then restores its exact
    // prior global state. The bridge never changes global power settings.
    try bridge.start()
    let owned = bridge.owned
    guard bridge.bothOwnedHeld, try power.assertionsHeld(AssertionKind.allCases, by: getpid()) else { bridge.releaseOwned(); throw BridgeError.assertionNotHeld }
    Thread.sleep(forTimeInterval: 0.5); bridge.releaseOwned()
    guard owned.allSatisfy({ !power.held($0) }), try power.sleepDisabled() == before else { throw BridgeError.assertionNotHeld }
    print("{\"scope\":\"owned-VM-assertion-lifecycle-only\",\"createdIdleAndDisplay\":true,\"ownerPIDAssertionsVerified\":true,\"processIdentityVerified\":true,\"releasedOnlyOwned\":true,\"globalPowerUnchanged\":true,\"closedLidProven\":false}")
}

final class FakePower: PowerAccess {
    var global = true, live = Set<UInt32>(), released: [UInt32] = [], creates = 0, failCreate: Int?
    var readError = false, externalReadError = false
    var externalAssertions: [Int32: Set<AssertionKind>] = [:]
    var beforeExternalProof: (() -> Void)?
    func sleepDisabled() throws -> Bool { if readError { throw BridgeError.powerReadFailed }; return global }
    func create(_ kind: AssertionKind) throws -> UInt32 {
        creates += 1; if failCreate == creates { throw BridgeError.assertionCreateFailed }
        let id = UInt32(creates); live.insert(id); return id
    }
    func held(_ id: UInt32) -> Bool { live.contains(id) }
    func release(_ id: UInt32) { released.append(id); live.remove(id) }
    func assertionsHeld(_ kinds: [AssertionKind], by pid: Int32) throws -> Bool {
        if externalReadError { throw BridgeError.powerReadFailed }
        beforeExternalProof?()
        return Set(kinds).isSubset(of: externalAssertions[pid] ?? [])
    }
}
final class FakeIdentity: IdentityAccess {
    var values: [Int32: ProcessIdentity] = [:]
    var reads: [Int32: Int] = [:]
    var beforeRead: ((Int32, Int) -> Void)?
    func read(_ pid: Int32) throws -> ProcessIdentity? {
        reads[pid, default: 0] += 1; beforeRead?(pid, reads[pid]!); return values[pid]
    }
}
final class FakePersistence: BridgePersistence {
    var failures: [BridgeFailures] = [], prepared: [ReleaseAction] = [], completedActions: [ReleaseAction] = []
    var failFailure = false, failPrepared = false, failCompleted = false
    var beforePrepared: (() -> Void)?
    func failure(_ flags: BridgeFailures) throws { if failFailure { throw BridgeError.persistenceFailed }; failures.append(flags) }
    func prepare(_ action: ReleaseAction, pid: Int32) throws {
        beforePrepared?(); if failPrepared { throw BridgeError.persistenceFailed }; prepared.append(action)
    }
    func completed(_ action: ReleaseAction, pid: Int32) throws {
        if failCompleted { throw BridgeError.persistenceFailed }; completedActions.append(action)
    }
}
func contractTests() throws {
    func expectFailure(_ action: () throws -> Void) { do { try action(); fatalError("Unsafe bridge admission") } catch {} }
    let old = ProcessIdentity(pid: 10001, executable: "/owned/old", sha256: String(repeating: "a", count: 64), startSeconds: 1, startMicroseconds: 2, status: 2)
    let new = ProcessIdentity(pid: 10002, executable: "/owned/new", sha256: String(repeating: "b", count: 64), startSeconds: 3, startMicroseconds: 4, status: 2)
    func fixture(_ display: Bool) throws -> (FakePower, AssertionBridge, FakeIdentity) {
        let power = FakePower(), bridge = AssertionBridge(power, wantedDisplay: display, persistence: FakePersistence()), identities = FakeIdentity()
        identities.values[old.pid] = old; identities.values[new.pid] = new
        try bridge.start(); precondition(bridge.bothOwnedHeld)
        return (power, bridge, identities)
    }
    let unprotected = FakePower(); unprotected.global = false
    expectFailure { try AssertionBridge(unprotected, wantedDisplay: false, persistence: FakePersistence()).start() }; precondition(unprotected.creates == 0 && unprotected.released.isEmpty)
    let partial = FakePower(); partial.failCreate = 2
    expectFailure { try AssertionBridge(partial, wantedDisplay: false, persistence: FakePersistence()).start() }; precondition(partial.released == [1] && partial.global)
    for wantedDisplay in [false, true] {
        let required: Set<AssertionKind> = wantedDisplay ? [.idle, .display] : [.idle]
        let (power, bridge, identities) = try fixture(wantedDisplay)
        precondition(bridge.wantedDisplay == wantedDisplay && Set(bridge.requiredAssertions) == required)
        func release() throws { try bridge.releaseToNew(pid: new.pid, old: old, expectedPath: new.executable, expectedSHA: new.sha256, identity: identities) }
        expectFailure { try release() }; precondition(power.released.isEmpty) // old alive
        identities.values[old.pid] = nil
        expectFailure { try release() }; precondition(power.released.isEmpty) // idle always required
        power.externalAssertions[new.pid] = [.display]
        expectFailure { try release() }; precondition(power.released.isEmpty)
        if wantedDisplay {
            power.externalAssertions[new.pid] = [.idle]
            expectFailure { try release() }; precondition(power.released.isEmpty)
        }
        power.externalAssertions[new.pid] = required
        expectFailure { try bridge.releaseToNew(pid: new.pid, old: old, expectedPath: old.executable, expectedSHA: new.sha256, identity: identities) }
        expectFailure { try bridge.releaseToNew(pid: new.pid, old: old, expectedPath: new.executable, expectedSHA: old.sha256, identity: identities) }
        identities.values[new.pid] = nil
        expectFailure { try release() }; precondition(power.released.isEmpty && bridge.bothOwnedHeld) // crashed target: no TTL release
        identities.values[new.pid] = ProcessIdentity(pid: new.pid, executable: new.executable, sha256: new.sha256, startSeconds: new.startSeconds, startMicroseconds: new.startMicroseconds, status: 4)
        expectFailure { try release() }; precondition(power.released.isEmpty)
        identities.values[new.pid] = new
        power.beforeExternalProof = {
            identities.values[new.pid] = ProcessIdentity(pid: new.pid, executable: new.executable, sha256: new.sha256, startSeconds: 30, startMicroseconds: 40, status: 2)
        }
        expectFailure { try release() }; precondition(power.released.isEmpty)
        power.beforeExternalProof = nil; identities.values[new.pid] = new
        try release(); precondition(power.released == [1, 2] && power.global)

        let (rollbackPower, rollback, rollbackIdentity) = try fixture(wantedDisplay)
        rollbackPower.externalAssertions[old.pid] = required
        rollbackIdentity.values[old.pid] = ProcessIdentity(pid: old.pid, executable: old.executable, sha256: old.sha256, startSeconds: old.startSeconds, startMicroseconds: 999, status: 2)
        expectFailure { try rollback.abortAfterOldResumed(old: old, identity: rollbackIdentity) }; precondition(rollbackPower.released.isEmpty)
        rollbackIdentity.values[old.pid] = ProcessIdentity(pid: old.pid, executable: old.executable, sha256: old.sha256, startSeconds: old.startSeconds, startMicroseconds: old.startMicroseconds, status: 4)
        expectFailure { try rollback.abortAfterOldResumed(old: old, identity: rollbackIdentity) }
        rollbackIdentity.values[old.pid] = old
        rollbackPower.externalAssertions[old.pid] = []
        expectFailure { try rollback.abortAfterOldResumed(old: old, identity: rollbackIdentity) }
        if wantedDisplay {
            rollbackPower.externalAssertions[old.pid] = [.idle]
            expectFailure { try rollback.abortAfterOldResumed(old: old, identity: rollbackIdentity) }
        }
        rollbackPower.externalAssertions[old.pid] = required
        try rollback.abortAfterOldResumed(old: old, identity: rollbackIdentity)
        precondition(rollbackPower.released == [1, 2] && rollbackPower.global)

        let (restartPower, restart, restartIdentity) = try fixture(wantedDisplay)
        restartIdentity.values[old.pid] = nil
        let restarted = ProcessIdentity(pid: 10003, executable: old.executable, sha256: old.sha256, startSeconds: 8, startMicroseconds: 9, status: 2)
        restartIdentity.values[restarted.pid] = restarted; restartPower.externalAssertions[restarted.pid] = required
        expectFailure { try restart.abortAfterOldResumed(old: old, identity: restartIdentity) }
        try restart.releaseToNew(pid: restarted.pid, old: old, expectedPath: old.executable, expectedSHA: old.sha256, identity: restartIdentity, action: .restartedOld)
        precondition(restartPower.released == [1, 2] && restartPower.global)
    }
    func preparedFixture(_ display: Bool, _ action: ReleaseAction) throws -> (FakePower, AssertionBridge, FakeIdentity, FakePersistence, ProcessIdentity) {
        let (power, bridge, identity) = try fixture(display)
        let persistence = bridge.persistence as! FakePersistence
        let target: ProcessIdentity
        if action == .resumedOld { target = old }
        else if action == .restartedOld {
            identity.values[old.pid] = nil
            target = ProcessIdentity(pid: 10003, executable: old.executable, sha256: old.sha256, startSeconds: 8, startMicroseconds: 9, status: 2)
            identity.values[target.pid] = target
        } else { identity.values[old.pid] = nil; target = new }
        power.externalAssertions[target.pid] = Set(bridge.requiredAssertions)
        return (power, bridge, identity, persistence, target)
    }
    func transfer(_ bridge: AssertionBridge, _ identity: FakeIdentity, _ target: ProcessIdentity, _ action: ReleaseAction) throws {
        if action == .resumedOld { try bridge.abortAfterOldResumed(old: old, identity: identity) }
        else { try bridge.releaseToNew(pid: target.pid, old: old, expectedPath: target.executable, expectedSHA: target.sha256, identity: identity, action: action) }
    }
    for display in [false, true] {
        for action in [ReleaseAction.new, .resumedOld, .restartedOld] {
            // Own protection disappears inside the slow external proof, rather than at admission.
            let (racePower, raceBridge, raceIdentity, racePersistence, raceTarget) = try preparedFixture(display, action)
            let missing = raceBridge.owned.last!
            racePower.beforeExternalProof = { racePower.live.remove(missing) }
            expectFailure { try transfer(raceBridge, raceIdentity, raceTarget, action) }
            precondition(racePower.released.isEmpty && raceBridge.failures.assertion && !racePersistence.failures.isEmpty)
            racePower.beforeExternalProof = nil; racePower.live.insert(missing)
            expectFailure { try transfer(raceBridge, raceIdentity, raceTarget, action) }
            precondition(racePower.released.isEmpty) // Restoration cannot clear the observed gap.

            let (targetPower, targetBridge, targetIdentity, _, target) = try preparedFixture(display, action)
            targetIdentity.beforeRead = { pid, count in
                if pid == target.pid && count == 4 { targetPower.externalAssertions[pid] = [] }
            }
            expectFailure { try transfer(targetBridge, targetIdentity, target, action) }
            precondition(targetPower.released.isEmpty && targetBridge.bothOwnedHeld)

            let (pidPower, pidBridge, pidIdentity, _, pidTarget) = try preparedFixture(display, action)
            pidIdentity.beforeRead = { pid, count in
                if pid == pidTarget.pid && count == 5 {
                    pidIdentity.values[pid] = ProcessIdentity(pid: pid, executable: pidTarget.executable, sha256: pidTarget.sha256, startSeconds: 99, startMicroseconds: 99, status: 2)
                }
            }
            expectFailure { try transfer(pidBridge, pidIdentity, pidTarget, action) }
            precondition(pidPower.released.isEmpty && pidBridge.bothOwnedHeld)

            for failure in [FailureKind.global, .assertion, .read, .persistence] {
                let (power, bridge, identity, persistence, target) = try preparedFixture(display, action)
                let assertion = bridge.owned.last!
                switch failure {
                case .global: power.global = false
                case .assertion: power.live.remove(assertion)
                case .read: power.readError = true
                case .persistence: persistence.failPrepared = true
                }
                if failure == .persistence { expectFailure { try transfer(bridge, identity, target, action) } }
                else { expectFailure { try bridge.observeProtection() } }
                precondition(bridge.failures.any && !persistence.failures.isEmpty && power.released.isEmpty)
                power.global = true; power.live.insert(assertion); power.readError = false; persistence.failPrepared = false
                expectFailure { try transfer(bridge, identity, target, action) }
                precondition(power.released.isEmpty && persistence.completedActions.isEmpty && bridge.bothOwnedHeld)
            }
            let (failedPower, failedBridge, failedIdentity, failedPersistence, failedTarget) = try preparedFixture(display, action)
            failedPersistence.failFailure = true; failedPower.global = false
            expectFailure { try failedBridge.observeProtection() }
            precondition(failedBridge.failures.global && failedBridge.failures.persistence && failedPower.released.isEmpty)
            failedPower.global = true; failedPersistence.failFailure = false
            expectFailure { try transfer(failedBridge, failedIdentity, failedTarget, action) }
            precondition(failedBridge.bothOwnedHeld && failedPersistence.completedActions.isEmpty)

            let (flushPower, flushBridge, flushIdentity, flushPersistence, flushTarget) = try preparedFixture(display, action)
            flushPersistence.beforePrepared = { flushPower.live.remove(flushBridge.owned.last!) }
            expectFailure { try transfer(flushBridge, flushIdentity, flushTarget, action) }
            precondition(flushPower.released.isEmpty && flushBridge.failures.assertion)

            let (commitPower, commitBridge, commitIdentity, commitPersistence, commitTarget) = try preparedFixture(display, action)
            commitPersistence.failCompleted = true
            expectFailure { try transfer(commitBridge, commitIdentity, commitTarget, action) }
            precondition(commitBridge.failures.persistence && commitBridge.bothOwnedHeld && commitPower.live == [3, 4] && commitPersistence.completedActions.isEmpty)
        }
    }
    print("PASS: final own/required-target/lifetime proofs after slow reads and durable preparation; observed failure then restoration vetoes all three release actions; failed persistence holds and cannot PASS")
    print("PASS: bridge refusal at SleepDisabled0; owned creation rollback; target PID/hash/assertion/global guards; PID reuse and stopped-old rollback guards; own-only release")
    print("PASS: pinned displayOFF/displayON minimum assertions; missing idle/display veto; old-resumed and restarted rollback preserve intent; target crash keeps holding; target lifetime and current own assertions rechecked")
}
func persistenceContractTests(_ path: String) throws {
    let directory = try privateDirectory(path), state = directory.appendingPathComponent("state.json")
    guard !FileManager.default.fileExists(atPath: state.path) else { throw BridgeError.privateDirectoryRequired }
    let old = ProcessIdentity(pid: 10001, executable: "/fake/old", sha256: String(repeating: "a", count: 64), startSeconds: 1, startMicroseconds: 2, status: 2)
    var snapshot = Snapshot(session: UUID().uuidString, pid: getpid(), old: old, newExecutable: "/fake/new",
        newSHA256: String(repeating: "b", count: 64), wantedDisplay: false)
    snapshot.phase = "failed-holding"; snapshot.globalFailureObserved = true; snapshot.ownAssertionsOn = true
    try saveSnapshot(snapshot, to: state, event: .failure)
    let persisted = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: state))
    precondition(persisted.globalFailureObserved && persisted.phase == "failed-holding")
    let events = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
    precondition(events.count == 1)
    let event = try JSONDecoder().decode(HandoffEvent.self, from: Data(events[0].utf8))
    precondition(event.kind == .failure && event.globalFailure)
    let interrupted = directory.appendingPathComponent("state.interrupted.tmp")
    try Data("incomplete replacement".utf8).write(to: interrupted); _ = chmod(interrupted.path, 0o600)
    let afterInterrupted = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: state))
    precondition(afterInterrupted.globalFailureObserved)
    // O_NOFOLLOW rejects a failed event destination before a final state write.
    let blocked = directory.appendingPathComponent("blocked", isDirectory: true)
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: blocked.appendingPathComponent("events.jsonl"), withDestinationURL: state)
    let power = FakePower(), identities = FakeIdentity()
    let store = ClosurePersistence(writeFailure: { flags in
        var failed = snapshot; failed.record(flags)
        try saveSnapshot(failed, to: blocked.appendingPathComponent("state.json"), event: .failure)
    }, writePrepared: { _, _ in throw BridgeError.persistenceFailed }, writeCompleted: { _, _ in throw BridgeError.persistenceFailed })
    let bridge = AssertionBridge(power, wantedDisplay: false, persistence: store); try bridge.start()
    power.global = false
    do { try bridge.observeProtection(); fatalError("Failed persistence admitted action") } catch {}
    precondition(bridge.failures.global && bridge.failures.persistence && bridge.bothOwnedHeld)
    power.global = true
    do { try bridge.releaseToNew(pid: 10002, old: old, expectedPath: "/fake/new", expectedSHA: String(repeating: "b", count: 64), identity: identities); fatalError("Restored current state cleared failed persistence") } catch {}
    precondition(power.released.isEmpty && !FileManager.default.fileExists(atPath: blocked.appendingPathComponent("state.json").path))
    print("{\"scope\":\"owned-filesystem-and-fake-power-only\",\"fileAndDirectoryFsyncExecuted\":true,\"failureEventAndAtomicSnapshotReadBack\":true,\"interruptedReplacementPreservedFailure\":true,\"failedPersistenceKeepsAssertions\":true,\"realPowerActions\":0}")
}
@main enum Main {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--self-test"] { try contractTests() }
            else if arguments.count == 3, arguments[0] == "--persistence-test", arguments[1] == "--state-dir" { try persistenceContractTests(arguments[2]) }
            else if arguments == ["--lab-lifecycle"] { try laboratoryLifecycle() }
            else if arguments.first == "--hold" { try hold(Array(arguments.dropFirst())) }
            else { throw BridgeError.invalidArguments }
        } catch {
            let reason = (error as? BridgeError)?.rawValue ?? "boundedBridgeError"
            print("{\"bridgeRefused\":true,\"reason\":\"\(reason)\",\"globalPowerWrites\":0}"); exit(1)
        }
    }
}
