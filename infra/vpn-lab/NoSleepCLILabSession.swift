import AppKit
import Foundation
import CryptoKit
import Darwin

// Opt-in same-binary laboratory coordinator. Integration is a separate root
// step; this file is not part of the normal Sources glob yet. No power, GUI,
// route, interface, certificate, Cisco disconnect, or service operation exists.
private enum CLILabSessionError: String, Error { case arguments, hardware, privateFiles, identity, profile, descriptor, bootstrap, credentialOperation, checkpoint, command, cleanup, lifetime }
private enum CLILabSessionOperation: String, Codable { case none, enable, off, replaceWrong, replaceValid, delete, stop, finish }
private enum CLILabSessionPhase: String, Codable { case bootstrapping, ready, mutation, stopped, finished, failed }

private struct CLILabSessionCounters: Codable, Equatable {
    var childStarts = 0, actualUsernameWrites = 0, actualPasswordWrites = 0
    var completedAttempts = 0, usernameWrites = 0, passwordWrites = 0
    var metadataReads = 0, passwordReads = 0, saves = 0, deletes = 0, authorizations = 0
    var lastOutcome: String? = nil, lastCleanup: String? = nil
    var lastUsernameWrites = 0, lastPasswordWrites = 0
}
private struct CLILabSessionDescriptor: Codable {
    let schema: Int, session: String, account: String, suite: String
    let binaryPath: String, binarySHA256: String, infoSHA256: String
    let profileSHA256: String, cliSHA256: String
    var setupComplete = false, finished = false
    var initialRevision: String? = nil, currentRevision: String? = nil, beforeMutationRevision: String? = nil
    var processGeneration = 0, commandSequence = 0, completedCommandSequence = 0, checkpointSequence = 0
    var currentPID: Int32? = nil, previousPID: Int32? = nil
    var lastOperation: CLILabSessionOperation = .none
    var lastChallenge = String(repeating: "0", count: 64)
    var counters = CLILabSessionCounters()
}
private struct CLILabSessionCommand: Codable {
    let schema: Int, sequence: Int, operation: CLILabSessionOperation, challenge: String
}
private struct CLILabSessionCheckpoint: Codable, Equatable {
    let schema: Int
    var checkpointSequence: Int, commandSequence: Int, completedCommandSequence: Int, processGeneration: Int
    var operation: CLILabSessionOperation, challenge: String, phase: CLILabSessionPhase
    var stage: VPNRecoveryStage, issue: VPNRecoveryIssue?, failure: CLILabSessionError?
    var enabled: Bool, configured: Bool, credentialsBusy: Bool, connectionBusy: Bool, driverReady: Bool
    var nativeState: VPNLinkState, nativeFresh: Bool, guiPresent: Bool
    var revisionMatchesDescriptor: Bool, sameInitialRevision: Bool, revisionChangedByLastMutation: Bool, setupComplete: Bool, newProcessPID: Bool
    var persistedEnabled: Bool, inFlight: Bool, submitted: Bool, rejected: Bool, confirmed: Bool
    var budgetPresent: Bool, budgetAttempts: Int, budgetLogins: Int
    var counters: CLILabSessionCounters
    var schedulingInjection: Bool = false
}
extension CLILabSessionError: Codable {}
extension CLILabSessionOperation: Equatable {}
extension CLILabSessionPhase: Equatable {}

private func cliLabDescriptorCanResume(_ value: CLILabSessionDescriptor) -> Bool {
    value.setupComplete && !value.finished && (0..<16).contains(value.processGeneration) &&
        (0...64).contains(value.commandSequence) && value.completedCommandSequence == value.commandSequence &&
        (0...10000).contains(value.checkpointSequence)
}

private enum CLILabSessionFiles {
    static func require(_ value: Bool, _ error: CLILabSessionError) throws { if !value { throw error } }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func owned(_ url: URL, directory: Bool, maximum: Int = 65536) throws {
        var info = stat()
        try require(lstat(url.path, &info) == 0 && safe(info, directory: directory, maximum: maximum), .privateFiles)
    }
    static func safe(_ info: stat, directory: Bool, maximum: Int = 65536) -> Bool {
        info.st_uid == getuid() && info.st_mode & 0o777 == (directory ? 0o700 : 0o600) &&
            info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) &&
            (directory || info.st_nlink == 1 && info.st_size >= 0 && info.st_size <= maximum)
    }
    static func directory(_ url: URL, create: Bool = false) throws {
        if create && !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try owned(url, directory: true)
    }
    static func read(_ url: URL, maximum: Int = 65536) throws -> Data {
        try owned(url, directory: false, maximum: maximum)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        try require(fd >= 0, .privateFiles); defer { close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && safe(info, directory: false, maximum: maximum), .privateFiles)
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }; result.resetBytes(in: 0..<result.count) }
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            try require(count >= 0 && result.count + max(0, count) <= maximum, .privateFiles)
            if count == 0 { return result }; result.append(contentsOf: bytes.prefix(count))
        }
    }
    static func write(_ data: Data, to destination: URL) throws {
        try require(data.count <= 65536, .checkpoint)
        try directory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) { try owned(destination, directory: false) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(fd >= 0, .checkpoint)
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                try require(count > 0, .checkpoint); offset += count
            }
        }
        try require(fsync(fd) == 0 && rename(temporary.path, destination.path) == 0, .checkpoint)
        let directoryFD = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try require(directoryFD >= 0, .checkpoint); defer { close(directoryFD) }
        try require(fsync(directoryFD) == 0, .checkpoint)
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func checkpoint(_ value: CLILabSessionCheckpoint) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: encode(value)) as! [String: Any]
        if value.issue == nil { object["issue"] = NSNull() }
        if value.failure == nil { object["failure"] = NSNull() }
        var counters = object["counters"] as! [String: Any]
        if value.counters.lastOutcome == nil { counters["lastOutcome"] = NSNull() }
        if value.counters.lastCleanup == nil { counters["lastCleanup"] = NSNull() }
        object["counters"] = counters
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    static func capture(_ url: String, _ arguments: [String]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: url); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096), eof = false
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        defer { pipe.fileHandleForReading.closeFile() }
        while !eof && ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { eof = true }
            else if count > 0 {
                if data.count + count > 16384 { break }
                data.append(contentsOf: bytes.prefix(count))
            } else if errno != EAGAIN && errno != EINTR { break }
            else { usleep(10000) }
        }
        while eof && process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
        if !eof || process.isRunning {
            if process.isRunning { process.terminate(); usleep(100000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            process.waitUntilExit(); throw CLILabSessionError.hardware
        }
        process.waitUntilExit()
        try require(process.terminationStatus == 0, .hardware)
        return data
    }
}

private final class CLILabSessionLedger {
    private let lock = NSLock()
    private(set) var descriptor: CLILabSessionDescriptor
    let root: URL
    private var storageFailed = false
    init(_ descriptor: CLILabSessionDescriptor, root: URL) { self.descriptor = descriptor; self.root = root }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return storageFailed }
    func snapshot() -> CLILabSessionDescriptor { lock.lock(); defer { lock.unlock() }; return descriptor }
    func change(_ body: (inout CLILabSessionDescriptor) -> Void) throws {
        lock.lock(); defer { lock.unlock() }; body(&descriptor)
        do { try CLILabSessionFiles.write(CLILabSessionFiles.encode(descriptor), to: root.appendingPathComponent("descriptor.json")) }
        catch { storageFailed = true; throw CLILabSessionError.checkpoint }
    }
    func note(_ body: (inout CLILabSessionCounters) -> Void) {
        // A post-launch bookkeeping failure must never masquerade as a launch
        // refusal. The main loop detects it and revokes the real owned child.
        try? change { body(&$0.counters) }
    }
    func childStarted(_ process: Process) {
        note { $0.childStarts += 1 }
        let role: [String: Any] = ["schema": 1, "role": "owned-cisco-child", "pid": process.processIdentifier,
                                  "cliSHA256": snapshot().cliSHA256,
                                  "birth": (try? String(decoding: CLILabSessionFiles.capture("/bin/ps", ["-p", String(process.processIdentifier), "-o", "lstart="]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""]
        do { try CLILabSessionFiles.write(JSONSerialization.data(withJSONObject: role, options: [.sortedKeys]), to: root.appendingPathComponent("child.json")) }
        catch { lock.lock(); storageFailed = true; lock.unlock() }
    }
}

private final class CLILabSessionCredentials: VPNCredentialProviding {
    let store: VPNCredentialStore, ledger: CLILabSessionLedger
    init(account: String, ledger: CLILabSessionLedger) { store = VPNCredentialStore(account: account); self.ledger = ledger }
    func metadata() throws -> VPNCredentialMetadata? { try ledger.change { $0.counters.metadataReads += 1 }; return try store.metadata() }
    func password(for metadata: VPNCredentialMetadata) throws -> String { try ledger.change { $0.counters.passwordReads += 1 }; return try store.password(for: metadata) }
    func save(_ metadata: VPNCredentialMetadata, password: String) throws { try store.save(metadata, password: password); ledger.note { $0.saves += 1 } }
    func delete() throws { try store.delete(); ledger.note { $0.deletes += 1 } }
    func authorizeSavedLogin(accepting: (VPNCredentialMetadata) -> Bool) throws -> VPNCredentialMetadata {
        // This first coordinator never authorizes an existing item implicitly.
        ledger.note { $0.authorizations += 1 }
        throw CLILabSessionError.command
    }
}
private final class CLILabSessionProcess: CiscoConnectionProcess {
    let process: CiscoConnectionProcess, ledger: CLILabSessionLedger
    private var ordinal = 0
    init(_ process: CiscoConnectionProcess, ledger: CLILabSessionLedger) { self.process = process; self.ledger = ledger }
    var running: Bool { process.running }
    var exitStatus: Int32? { process.exitStatus }
    func read(maxBytes: Int, timeout: TimeInterval) throws -> CiscoConnectionRead { try process.read(maxBytes: maxBytes, timeout: timeout) }
    func write(_ data: Data) throws {
        try process.write(data); ordinal += 1
        ledger.note { if ordinal == 1 { $0.actualUsernameWrites += 1 } else if ordinal == 2 { $0.actualPasswordWrites += 1 } }
    }
    func closeInput() { process.closeInput() }
    func reap(timeout: TimeInterval) -> Bool { process.reap(timeout: timeout) }
    func terminateOwned() { process.terminateOwned() }
    func killOwned() { process.killOwned() }
}
private final class CLILabSessionConnection: CiscoConnectionConnecting {
    let client: CiscoConnectionClient, ledger: CLILabSessionLedger
    init(_ client: CiscoConnectionClient, ledger: CLILabSessionLedger) { self.client = client; self.ledger = ledger }
    var ready: Bool { client.ready }
    func cancel() { client.cancel() }
    func connect(_ metadata: VPNCredentialMetadata, password: @escaping () throws -> String,
                 beforeSubmission: @escaping () throws -> Void, allowed: @escaping () -> Bool,
                 nativeState: @escaping () -> CiscoConnectionNativeSample?, phase: @escaping (CiscoConnectionPhase) -> Void) -> CiscoConnectionResult {
        let result = client.connect(metadata, password: password, beforeSubmission: beforeSubmission, allowed: allowed,
                                    nativeState: nativeState, phase: phase)
        ledger.note {
            $0.completedAttempts += 1; $0.usernameWrites += result.usernameWrites; $0.passwordWrites += result.passwordWrites
            $0.lastOutcome = result.outcome.rawValue; $0.lastCleanup = result.cleanup.rawValue
            $0.lastUsernameWrites = result.usernameWrites; $0.lastPasswordWrites = result.passwordWrites
        }
        return result
    }
}

// CLI arguments contain only public synthetic session/candidate bindings.
// Setup saves once; resume uses the same existing account and preferences and
// never calls Save, Authorize or Enable. Production restoration of prior ON
// remains production behavior, rather than a harness-created new ON intent.
func officialConnectionPersistentLabSession() throws {
    func argument(_ name: String) throws -> String {
        guard CommandLine.arguments.filter({ $0 == name }).count == 1,
              let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { throw CLILabSessionError.arguments }
        return CommandLine.arguments[index + 1]
    }
    let session = try argument("--lab-session"), startup = try argument("--lab-session-start")
    let binarySHA = try argument("--lab-session-binary-sha256"), infoSHA = try argument("--lab-session-info-sha256")
    try CLILabSessionFiles.require(session.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil && ["setup", "resume"].contains(startup) &&
        [binarySHA, infoSHA].allSatisfy { $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }, .arguments)
    let model = String(decoding: try CLILabSessionFiles.capture("/usr/sbin/sysctl", ["-n", "hw.model"]), as: UTF8.self)
    try CLILabSessionFiles.require(model.hasPrefix("VirtualMac") && getuid() == 501, .hardware)
    let interface = String(decoding: try CLILabSessionFiles.capture("/sbin/ifconfig", ["en0"]), as: UTF8.self)
    try CLILabSessionFiles.require(interface.contains("ether 42:35:8c:14:fd:0c"), .hardware)
    let profileHash = "4a27e4cd06a236054b0fc0246d32919b1978f210db6cf11dd9b025ec34930834"
    let cliHash = "5f25ac7357462e9039744062f695aa67c989359407dd5ad6932a958ae82ce0a9"
    try CLILabSessionFiles.require(CLILabSessionFiles.hash(try Data(contentsOf: URL(fileURLWithPath: "/opt/cisco/secureclient/vpn/profile/NoSleepLab.xml"))) == profileHash, .profile)
    let cli = try CiscoConnectionSystem.verifiedCLI()
    try CLILabSessionFiles.require(CLILabSessionFiles.hash(try Data(contentsOf: cli)) == cliHash, .identity)
    guard let executable = Bundle.main.executableURL else { throw CLILabSessionError.identity }
    let canonical = executable.resolvingSymlinksInPath(), app = canonical.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try CLILabSessionFiles.require(executable.path == canonical.path && canonical.path.hasPrefix("/Users/admin/NoSleepLab/production-acceptance/") &&
        canonical.lastPathComponent == "NoSleep" && app.lastPathComponent == "NoSleep.app" &&
        CLILabSessionFiles.hash(try Data(contentsOf: canonical)) == binarySHA &&
        CLILabSessionFiles.hash(try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))) == infoSHA, .identity)
    _ = try CLILabSessionFiles.capture("/usr/bin/codesign", ["--verify", "--strict", app.path])
    guard let profile = CiscoConnectionSystem.profiles()?.first(where: { $0.displayName == "NoSleep Lab" && $0.host == "vpn-lab.invalid:4443" }) else { throw CLILabSessionError.profile }
    let labRoot = URL(fileURLWithPath: "/Users/admin/NoSleepLab", isDirectory: true)
    try CLILabSessionFiles.directory(labRoot)
    try CLILabSessionFiles.directory(app.deletingLastPathComponent().deletingLastPathComponent())
    try CLILabSessionFiles.directory(app.deletingLastPathComponent())
    let fixtures = labRoot.appendingPathComponent("cli-native-probe-v1", isDirectory: true)
    try CLILabSessionFiles.directory(fixtures)
    let secretFile = fixtures.appendingPathComponent("synthetic-secret.txt")
    try CLILabSessionFiles.owned(secretFile, directory: false, maximum: 513)
    let sessions = labRoot.appendingPathComponent("production-sessions", isDirectory: true)
    try CLILabSessionFiles.directory(sessions, create: true)
    let root = sessions.appendingPathComponent(session, isDirectory: true)
    if startup == "setup" {
        try CLILabSessionFiles.require(!FileManager.default.fileExists(atPath: root.path), .descriptor)
        try CLILabSessionFiles.directory(root, create: true)
        let descriptor = CLILabSessionDescriptor(schema: 1, session: session, account: "lab-session-" + session,
            suite: "NoSleep.RealCLISession." + session, binaryPath: canonical.path, binarySHA256: binarySHA, infoSHA256: infoSHA,
            profileSHA256: profileHash, cliSHA256: cliHash)
        try CLILabSessionFiles.write(CLILabSessionFiles.encode(descriptor), to: root.appendingPathComponent("descriptor.json"))
    } else { try CLILabSessionFiles.directory(root) }
    let descriptorURL = root.appendingPathComponent("descriptor.json")
    let saved = try JSONDecoder().decode(CLILabSessionDescriptor.self, from: CLILabSessionFiles.read(descriptorURL))
    try CLILabSessionFiles.require(saved.schema == 1 && saved.session == session && saved.account == "lab-session-" + session &&
        saved.suite == "NoSleep.RealCLISession." + session && saved.binaryPath == canonical.path && saved.binarySHA256 == binarySHA &&
        saved.infoSHA256 == infoSHA && saved.profileSHA256 == profileHash && saved.cliSHA256 == cliHash && !saved.finished &&
        (startup == "setup" || cliLabDescriptorCanResume(saved)), .descriptor)
    let lease = root.appendingPathComponent("session.lock")
    let leaseFD = open(lease.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    try CLILabSessionFiles.require(leaseFD >= 0 && flock(leaseFD, LOCK_EX | LOCK_NB) == 0, .descriptor)
    defer { flock(leaseFD, LOCK_UN); close(leaseFD) }
    var leaseInfo = stat()
    try CLILabSessionFiles.require(fstat(leaseFD, &leaseInfo) == 0 && CLILabSessionFiles.safe(leaseInfo, directory: false), .privateFiles)
    let ledger = CLILabSessionLedger(saved, root: root)
    try ledger.change { $0.processGeneration += 1; $0.previousPID = $0.currentPID; $0.currentPID = getpid() }
    let role: [String: Any] = ["schema": 1, "role": "owned-nosleep-session", "pid": getpid(), "binaryPath": canonical.path,
                              "binarySHA256": binarySHA, "infoSHA256": infoSHA, "generation": ledger.snapshot().processGeneration,
                              "birth": String(decoding: try CLILabSessionFiles.capture("/bin/ps", ["-p", String(getpid()), "-o", "lstart="]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)]
    try CLILabSessionFiles.write(JSONSerialization.data(withJSONObject: role, options: [.sortedKeys]), to: root.appendingPathComponent("process.json"))
    guard let defaults = UserDefaults(suiteName: saved.suite) else { throw CLILabSessionError.descriptor }
    if startup == "setup" {
        try CLILabSessionFiles.require(defaults.persistentDomain(forName: saved.suite) == nil, .descriptor)
        defaults.set(true, forKey: "CiscoMonitoringEnabled"); try CLILabSessionFiles.require(defaults.synchronize(), .checkpoint)
    }
    _ = NSApplication.shared
    let diagnostics = DiagnosticStore(root: root.appendingPathComponent("diagnostics", isDirectory: true))
    let observer = CiscoObserver(diagnostics: diagnostics, defaults: defaults)
    let credentials = CLILabSessionCredentials(account: saved.account, ledger: ledger)
    var dependencies = CiscoConnectionDependencies(); dependencies.requestNativeRefresh = { observer.requestRefresh() }
    dependencies.launch = { url, arguments in
        let process = try CiscoNativeConnectionProcess(url, arguments: arguments, startProcess: { process in
            try process.run(); ledger.childStarted(process)
        })
        return CLILabSessionProcess(process, ledger: ledger)
    }
    let driver = CLILabSessionConnection(CiscoConnectionClient(dependencies: dependencies), ledger: ledger)
    let controller = CiscoGUIRecovery(diagnostics: diagnostics, credentials: credentials, defaults: defaults,
        profiles: { CiscoConnectionSystem.profiles() ?? [] }, automaticPolling: true,
        nativeState: { observer.freshStateSnapshot() }, refreshNativeState: { observer.requestRefresh() }, connection: driver,
        nativeSample: { let sample = observer.snapshot(); guard sample.isFresh, let started = sample.readStartedAt else { return nil }
            return CiscoConnectionNativeSample(state: sample.link, readStartedAt: started) })
    defer { controller.stop(wait: false); observer.stop(); diagnostics.flush() }
    func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
    func secret(wrong: Bool) throws -> String {
        if wrong { return "synthetic-intentionally-wrong" }
        var data = try CLILabSessionFiles.read(secretFile, maximum: 513)
        defer { data.resetBytes(in: 0..<data.count); data.removeAll() }
        if data.last == 10 { data.removeLast() }
        guard !data.isEmpty, data.count <= 512, let value = String(data: data, encoding: .utf8) else { throw CLILabSessionError.privateFiles }
        return value
    }
    var phase: CLILabSessionPhase = .bootstrapping, failure: CLILabSessionError? = nil
    var mutation = false, previousCheckpoint: Data? = nil
    func checkpoint(force: Bool = false) throws {
        let descriptor = ledger.snapshot(), state = controller.snapshot(), observation = observer.snapshot(), metadata = controller.metadata()
        var budgetAttempts = 0, budgetLogins = 0
        let budget = defaults.data(forKey: "CiscoGUIRecoveryBudget")
        if let budget {
            struct Budget: Decodable { let attempts: Int, loginAttempts: Int }
            let values = try JSONDecoder().decode(Budget.self, from: budget)
            try CLILabSessionFiles.require((0...3).contains(values.attempts) && (0...3).contains(values.loginAttempts), .checkpoint)
            budgetAttempts = values.attempts; budgetLogins = values.loginAttempts
        }
        let revision = metadata?.revision
        let confirmed = defaults.dictionary(forKey: "CiscoGUIRecoveryConfirmedCredential")
        var value = CLILabSessionCheckpoint(schema: 1, checkpointSequence: 0, commandSequence: descriptor.commandSequence,
            completedCommandSequence: descriptor.completedCommandSequence,
            processGeneration: descriptor.processGeneration, operation: descriptor.lastOperation, challenge: descriptor.lastChallenge,
            phase: phase, stage: state.stage, issue: state.issue, failure: failure,
            enabled: state.enabled, configured: state.configured, credentialsBusy: state.credentialsBusy || mutation,
            connectionBusy: state.connectionBusy, driverReady: driver.ready, nativeState: observation.link, nativeFresh: observation.isFresh,
            guiPresent: CiscoConnectionSystem.guiState() == .present,
            revisionMatchesDescriptor: revision == descriptor.currentRevision,
            sameInitialRevision: revision != nil && revision == descriptor.initialRevision,
            revisionChangedByLastMutation: revision != nil && revision == descriptor.currentRevision && revision != descriptor.beforeMutationRevision,
            setupComplete: descriptor.setupComplete,
            newProcessPID: descriptor.previousPID != nil && descriptor.currentPID != descriptor.previousPID,
            persistedEnabled: defaults.bool(forKey: "CiscoGUIRecoveryEnabled"), inFlight: defaults.bool(forKey: "CiscoGUIRecoveryInFlight"),
            submitted: revision != nil && defaults.string(forKey: "CiscoGUIRecoverySubmittedCredential") == revision,
            rejected: revision != nil && defaults.string(forKey: "CiscoGUIRecoveryRejectedCredential") == revision,
            confirmed: revision != nil && (confirmed?["revision"] as? String) == revision &&
                (confirmed?["attemptID"] as? String) != nil && (confirmed?["attemptID"] as? String) == defaults.string(forKey: "CiscoGUIRecoverySubmittedAttemptID"),
            budgetPresent: budget != nil, budgetAttempts: budgetAttempts, budgetLogins: budgetLogins, counters: descriptor.counters)
        let comparison = try CLILabSessionFiles.checkpoint(value)
        guard force || comparison != previousCheckpoint else { return }
        try ledger.change { $0.checkpointSequence += 1 }; value.checkpointSequence = ledger.snapshot().checkpointSequence
        try CLILabSessionFiles.write(CLILabSessionFiles.checkpoint(value), to: root.appendingPathComponent("checkpoint.json"))
        previousCheckpoint = comparison
    }
    func changedRevision() throws {
        let revision = controller.metadata()?.revision
        try ledger.change { $0.currentRevision = revision }
    }
    func completeCommand() throws { try ledger.change { $0.completedCommandSequence = $0.commandSequence } }
    func save(wrong: Bool, initial: Bool = false) throws {
        try CLILabSessionFiles.require(!mutation && driver.ready && !controller.snapshot().connectionBusy, .command)
        try ledger.change { $0.beforeMutationRevision = $0.currentRevision }
        mutation = true; phase = .mutation
        var value = try secret(wrong: wrong); defer { value.removeAll(keepingCapacity: false) }
        controller.saveAsync(profile: profile, username: "lab-user", password: value, group: "lab", groupDisplay: "NoSleep Lab") { result in
            mutation = false
            if case .failure = result { failure = .credentialOperation; phase = .failed; controller.enable(false); return }
            do {
                try changedRevision()
                if initial { try ledger.change { $0.initialRevision = $0.currentRevision; $0.setupComplete = true } }
                else { try completeCommand() }
                phase = .ready
            } catch { failure = .checkpoint; phase = .failed; controller.enable(false) }
        }
    }
    observer.start()
    do {
        try CLILabSessionFiles.require(wait(12) { !controller.snapshot().credentialsBusy && observer.snapshot().isFresh }, .bootstrap)
        if startup == "setup" {
            try CLILabSessionFiles.require(controller.metadata() == nil && observer.freshStateSnapshot() == .disconnected, .bootstrap)
            try save(wrong: false, initial: true)
            try CLILabSessionFiles.require(wait(15) { !mutation } && failure == nil && ledger.snapshot().setupComplete, .credentialOperation)
        } else {
            try CLILabSessionFiles.require(controller.metadata()?.revision == saved.currentRevision, .descriptor)
            phase = .ready
        }
        try checkpoint(force: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 45 * 60
        var terminal = false
        while !terminal {
            try CLILabSessionFiles.require(ProcessInfo.processInfo.systemUptime < deadline, .lifetime)
            try CLILabSessionFiles.require(!ledger.failed && failure == nil, .checkpoint)
            let commandURL = root.appendingPathComponent("command.json")
            if FileManager.default.fileExists(atPath: commandURL.path) {
                let bytes = try CLILabSessionFiles.read(commandURL, maximum: 2048)
                // The guardian writes one sorted flat command grammar. This
                // exact grammar also rejects duplicate/escaped keys before
                // Foundation can collapse them into a dictionary.
                let grammar = #"^\s*\{\s*"challenge"\s*:\s*"[0-9a-f]{64}"\s*,\s*"operation"\s*:\s*"(enable|off|replaceWrong|replaceValid|delete|stop|finish)"\s*,\s*"schema"\s*:\s*1\s*,\s*"sequence"\s*:\s*[1-9][0-9]?\s*\}\s*$"#
                guard let text = String(data: bytes, encoding: .utf8), text.range(of: grammar, options: .regularExpression) != nil else { throw CLILabSessionError.command }
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      Set(object.keys) == ["schema", "sequence", "operation", "challenge"] else { throw CLILabSessionError.command }
                let command = try JSONDecoder().decode(CLILabSessionCommand.self, from: bytes), current = ledger.snapshot()
                try CLILabSessionFiles.require(command.schema == 1 && command.operation != .none && command.sequence <= 64 &&
                    command.challenge.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, .command)
                if command.sequence == current.commandSequence {
                    try CLILabSessionFiles.require(command.operation == current.lastOperation && command.challenge == current.lastChallenge, .command)
                } else {
                    try CLILabSessionFiles.require(command.sequence == current.commandSequence + 1 && !mutation &&
                        current.completedCommandSequence == current.commandSequence, .command)
                    // Durable at-most-once intent before the action. A crash
                    // after this point never automatically repeats a mutation.
                    try ledger.change { $0.commandSequence = command.sequence; $0.lastOperation = command.operation; $0.lastChallenge = command.challenge }
                    switch command.operation {
                    case .enable: controller.enable(true); try completeCommand()
                    case .off: controller.enable(false); try completeCommand()
                    case .replaceWrong: try save(wrong: true)
                    case .replaceValid: try save(wrong: false)
                    case .delete:
                        try CLILabSessionFiles.require(driver.ready && !controller.snapshot().connectionBusy, .command)
                        mutation = true; phase = .mutation
                        controller.deleteCredentialsAsync { result in
                            mutation = false
                            if case .failure = result { failure = .credentialOperation; phase = .failed; return }
                            do { try changedRevision(); try completeCommand(); phase = .ready }
                            catch { failure = .checkpoint; phase = .failed }
                        }
                    case .stop, .finish:
                        controller.stop(wait: false)
                        try CLILabSessionFiles.require(wait(8) {
                            let state = controller.snapshot()
                            return driver.ready && !state.enabled && !state.connectionBusy && !state.credentialsBusy
                        }, .cleanup)
                        if command.operation == .finish {
                            mutation = true
                            controller.deleteCredentialsAsync { result in
                                mutation = false
                                if case .failure = result { failure = .credentialOperation }
                            }
                            try CLILabSessionFiles.require(wait(15) { !mutation } && failure == nil, .credentialOperation)
                            defaults.removePersistentDomain(forName: saved.suite)
                            try CLILabSessionFiles.require(defaults.synchronize(), .checkpoint)
                            try ledger.change { $0.finished = true; $0.currentRevision = nil }; phase = .finished
                        } else { phase = .stopped }
                        try completeCommand()
                        terminal = true
                    case .none: throw CLILabSessionError.command
                    }
                }
            }
            try checkpoint()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    } catch {
        failure = (error as? CLILabSessionError) ?? .checkpoint; phase = .failed
        controller.enable(false); controller.stop(wait: false)
        _ = wait(8) { driver.ready && !controller.snapshot().enabled && !controller.snapshot().connectionBusy }
        try? checkpoint(force: true)
        throw failure!
    }
}
