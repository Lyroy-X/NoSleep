import Foundation
import Darwin

enum IssueCode: String, Codable, Error {
    case permissionRequired, commandTimeout, commandFailed, storageError, outputLimit, exportBusy
    case missingClient, untrustedClient, unsupportedState, cancelled
}
enum DiagnosticKind: String, Codable {
    case launch, powerAction, powerState, exported, shutdown, migration, queueOverflow
}
struct DiagnosticFacts: Codable, Equatable {
    var sleepWanted: Bool?
    var sleepActual: Bool?
    var displayWanted: Bool?
    var displayActual: Bool?
    var issue: IssueCode?
    var number: Int?
}
struct DiagnosticRecord: Codable {
    let at: Double
    let kind: DiagnosticKind
    let facts: DiagnosticFacts
}
final class DiagnosticStore {
    static let fileLimit = 50_000_000
    static let fileCount = 4
    static let logLimit = fileLimit * fileCount // 200 MB, decimal bytes, on disk.
    static let archiveLimit = logLimit + 256 * 1024 // ZIP headers and the small summary/README.
    static let retention: TimeInterval = 7 * 24 * 3600
    static let queueLimit = 32
    let root: URL
    private let queue = DispatchQueue(label: "NoSleep.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending: [DiagnosticRecord] = []
    private var scheduled = false
    private var dropped = 0
    private var last: [DiagnosticKind: DiagnosticFacts] = [:]
    private var windowStart: Double = 0
    private var windowCount = 0
    private var latest: LiveState?
    private var lastSnapshot = Data()
    private var snapshotAt: Double = 0
    private var lastPrune: Double = 0
    private var failed = false
    var storageFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    private let exportLock = NSLock()
    private var lastPower = DiagnosticFacts()
    private let now: () -> Double
    private let segmentLimit: Int
    private struct Stamp: Equatable { let size: Int; let modified: Date }
    private struct Validated { let stamp: Stamp; let oldest: Double; let newest: Double }
    private var validated: [Int: Validated] = [:] // Four entries, independent of the log size.
    init(root: URL, now: @escaping () -> Double = { Date().timeIntervalSince1970 },
         segmentLimit: Int = DiagnosticStore.fileLimit) {
        precondition(segmentLimit >= DiagnosticStreaming.recordLimit && segmentLimit <= Self.fileLimit)
        self.root = root; self.now = now; self.segmentLimit = segmentLimit
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Obsolete free-form logs are excluded from sharing and removed on upgrade.
        let legacy = root.appendingPathComponent("events.log")
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
            record(.migration)
        }
        for name in ["support-export", "support-report.zip"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        for index in 0..<Self.fileCount {
            try? FileManager.default.removeItem(at: logDirectory.appendingPathComponent(".prune-\(index).tmp"))
        }
        queue.async { self.prune() }
    }
    private var logDirectory: URL { root.appendingPathComponent("diagnostics", isDirectory: true) }
    private func file(_ index: Int) -> URL { logDirectory.appendingPathComponent("events-\(index).jsonl") }
    private func stamp(_ url: URL) -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, let modified = attrs[.modificationDate] as? Date else { return nil }
        return Stamp(size: size.intValue, modified: modified)
    }
    func record(_ kind: DiagnosticKind, _ facts: DiagnosticFacts = DiagnosticFacts()) {
        lock.lock(); defer { lock.unlock() }
        if kind == .powerState {
            lastPower = facts
        }
        if kind == .powerState && last[kind] == facts { return }
        last[kind] = facts
        let time = now()
        if time - windowStart >= 60 || time < windowStart { windowStart = time; windowCount = 0 }
        guard windowCount < 120 else { dropped = min(dropped + 1, 1_000_000); return }
        windowCount += 1
        if pending.count == Self.queueLimit {
            pending.removeFirst(); dropped = min(dropped + 1, 1_000_000)
        }
        pending.append(DiagnosticRecord(at: time, kind: kind, facts: facts))
        scheduleLocked()
    }
    func snapshot(_ state: LiveState) { lock.lock(); latest = state; scheduleLocked(); lock.unlock() }
    private func scheduleLocked() {
        guard !scheduled else { return }
        scheduled = true; queue.async { self.drain() }
    }
    private func drain() {
        lock.lock()
        let records = pending; pending.removeAll(keepingCapacity: true)
        let lost = dropped; dropped = 0
        let state = latest; latest = nil; scheduled = false
        lock.unlock()
        do {
            if now() - lastPrune > 60 { prune() }
            for record in records { try append(record) }
            if lost > 0 { try append(DiagnosticRecord(at: now(), kind: .queueOverflow, facts: DiagnosticFacts(number: lost))) }
            if let state = state {
                var stable = state; stable.updatedAt = 0
                let stableEncoder = JSONEncoder(); stableEncoder.outputFormatting = .sortedKeys
                let identity = try stableEncoder.encode(stable)
                if identity != lastSnapshot || now() - snapshotAt >= 5 {
                    let url = root.appendingPathComponent("state.json")
                    try JSONEncoder().encode(state).write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    lastSnapshot = identity; snapshotAt = now()
                }
            }
        } catch { lock.lock(); failed = true; lock.unlock() }
    }
    private func append(_ record: DiagnosticRecord) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(record); data.append(10)
        guard data.count <= DiagnosticStreaming.recordLimit else { throw IssueCode.outputLimit }
        let before = stamp(file(0)), size = before?.size ?? 0
        var known = validated[0]
        if known?.stamp != before { known = nil }
        if size + data.count > segmentLimit {
            try? FileManager.default.removeItem(at: file(Self.fileCount - 1))
            validated.removeValue(forKey: Self.fileCount - 1)
            for index in stride(from: Self.fileCount - 2, through: 0, by: -1) {
                if FileManager.default.fileExists(atPath: file(index).path) {
                    try FileManager.default.moveItem(at: file(index), to: file(index + 1))
                }
                validated[index + 1] = validated.removeValue(forKey: index)
            }
            known = nil
        }
        if !FileManager.default.fileExists(atPath: file(0).path) {
            FileManager.default.createFile(atPath: file(0).path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file(0)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
        if (size == 0 || known != nil || size + data.count > segmentLimit), let after = stamp(file(0)) {
            validated[0] = Validated(stamp: after, oldest: min(known?.oldest ?? record.at, record.at),
                                     newest: max(known?.newest ?? record.at, record.at))
        } else { validated.removeValue(forKey: 0) }
    }
    private func prune() {
        lastPrune = now()
        for index in 0..<Self.fileCount {
            let url = file(index)
            guard let before = stamp(url) else { validated.removeValue(forKey: index); continue }
            if now() - before.modified.timeIntervalSince1970 > Self.retention {
                try? FileManager.default.removeItem(at: url)
                validated.removeValue(forKey: index)
                continue
            }
            if let known = validated[index], known.stamp == before, before.size <= segmentLimit,
               known.oldest >= now() - Self.retention, known.newest <= now() + 60 { continue }
            // Unchanged validated files are skipped. Scan edited/expired files in bounded chunks.
            let temporary = logDirectory.appendingPathComponent(".prune-\(index).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let output = try DiagnosticStreaming.Writer(url: temporary, limit: segmentLimit)
                let scan = try DiagnosticStreaming.records(from: url, byteLimit: segmentLimit, at: now()) { clean, _ in
                    try output.append(clean)
                }
                try output.close()
                if output.count == 0 { try FileManager.default.removeItem(at: url); validated.removeValue(forKey: index) }
                else {
                    if scan.changed || before.size > segmentLimit { try DiagnosticStreaming.replace(url, with: temporary) }
                    if let after = stamp(url) { validated[index] = Validated(stamp: after, oldest: scan.oldest, newest: scan.newest) }
                }
            } catch {
                lock.lock(); failed = true; lock.unlock()
            }
        }
    }
    func flush() { queue.sync { drain(); prune() } }
    var queuedCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    func export(to destination: URL, permissionReady: Bool) throws {
        guard exportLock.try() else { throw IssueCode.exportBusy }
        defer { exportLock.unlock() }
        flush()
        let stage = root.appendingPathComponent("support-export", isDirectory: true)
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let log = try DiagnosticStreaming.Writer(url: stage.appendingPathComponent("events.jsonl"), limit: Self.logLimit)
        try queue.sync {
            for index in stride(from: Self.fileCount - 1, through: 0, by: -1) {
                guard FileManager.default.fileExists(atPath: file(index).path) else { continue }
                _ = try DiagnosticStreaming.records(from: file(index), byteLimit: segmentLimit, at: now()) { clean, _ in
                    try log.append(clean)
                }
            }
        }
        try log.close()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        struct Summary: Codable {
            let format: Int
            let appVersion: String
            let macOS: String
            let architecture: String
            let at: Double
            let powerPermissionReady: Bool
            let power: DiagnosticFacts
            let storageFailed: Bool
        }
        lock.lock(); let power = lastPower; lock.unlock()
        let summary = Summary(format: 3, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "test",
                              macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture,
                              at: now(), powerPermissionReady: permissionReady, power: power, storageFailed: storageFailed)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(summary).write(to: stage.appendingPathComponent("summary.json"))
        let help = """
        NoSleep: информация для диагностики
        Напишите: что нажали, что ожидали, что получилось и примерное время ошибки.
        Архив: версии, состояния функций, коды ошибок и события NoSleep.
        Нет секретов, IP, снимков экрана или системных журналов.
        Вы отправляете файл вручную. Логи: до 200 МБ (200 000 000 байт), до 7 дней; повторные опросы не записываются.
        """
        try Data(help.utf8).write(to: stage.appendingPathComponent("README.txt"))
        let temporary = root.appendingPathComponent("support-report.zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", stage.path, temporary.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0); p.terminationHandler = { _ in done.signal() }
        try p.run()
        guard done.wait(timeout: .now() + 120) == .success else {
            p.terminate()
            if done.wait(timeout: .now() + 1) != .success {
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            throw IssueCode.commandTimeout
        }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard p.terminationStatus == 0, size <= Self.archiveLimit else { throw IssueCode.storageError }
        let copy = destination.deletingLastPathComponent().appendingPathComponent(".NoSleep-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: temporary, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        try DiagnosticStreaming.replace(destination, with: copy)
        record(.exported)
    }
}
