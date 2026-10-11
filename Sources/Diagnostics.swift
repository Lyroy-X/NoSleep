import Foundation

enum IssueCode: String, Codable, Error {
    case permissionRequired, commandTimeout, commandFailed, storageError, outputLimit, exportBusy
    case missingClient, untrustedClient, unsupportedState, cancelled
}
enum DiagnosticKind: String, Codable {
    case launch, powerAction, powerState, exported, shutdown, migration, queueOverflow
    case observerState, observerAction
}
struct DiagnosticFacts: Codable, Equatable {
    var sleepWanted: Bool?
    var sleepActual: Bool?
    var displayWanted: Bool?
    var displayActual: Bool?
    var observerEnabled: Bool?
    var vpnState: VPNLinkState?
    var nativeRecovery: NativeRecovery?
    var online: Bool?
    var issue: IssueCode?
    var number: Int?
}
struct DiagnosticRecord: Codable {
    let at: Double
    let kind: DiagnosticKind
    let facts: DiagnosticFacts
}
final class DiagnosticStore {
    static let fileLimit = 256 * 1024
    static let fileCount = 4
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
    init(root: URL, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.root = root; self.now = now
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
        queue.async { self.prune() }
    }
    private var logDirectory: URL { root.appendingPathComponent("diagnostics", isDirectory: true) }
    private func file(_ index: Int) -> URL { logDirectory.appendingPathComponent("events-\(index).jsonl") }
    func record(_ kind: DiagnosticKind, _ facts: DiagnosticFacts = DiagnosticFacts()) {
        lock.lock(); defer { lock.unlock() }
        if kind == .powerState {
            lastPower = facts
        }
        if (kind == .powerState || kind == .observerState) && last[kind] == facts { return }
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
        var data = try JSONEncoder().encode(record); data.append(10)
        guard data.count <= 2048 else { throw IssueCode.outputLimit }
        let size = (try? FileManager.default.attributesOfItem(atPath: file(0).path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > Self.fileLimit {
            try? FileManager.default.removeItem(at: file(Self.fileCount - 1))
            for index in stride(from: Self.fileCount - 2, through: 0, by: -1) {
                if FileManager.default.fileExists(atPath: file(index).path) {
                    try FileManager.default.moveItem(at: file(index), to: file(index + 1))
                }
            }
        }
        if !FileManager.default.fileExists(atPath: file(0).path) {
            FileManager.default.createFile(atPath: file(0).path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file(0)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func prune() {
        lastPrune = now()
        for index in 0..<Self.fileCount {
            let url = file(index)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attrs[.modificationDate] as? Date,
               now() - modified.timeIntervalSince1970 > Self.retention {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: Self.fileLimit)) ?? Data()
            try? handle.close()
            var retained = Data()
            for line in data.split(separator: 10) {
                guard let record = try? JSONDecoder().decode(DiagnosticRecord.self, from: Data(line)),
                      record.at >= now() - Self.retention, record.at <= now() + 60 else { continue }
                if let clean = try? JSONEncoder().encode(record) { retained.append(clean); retained.append(10) }
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if retained.isEmpty { try? FileManager.default.removeItem(at: url) }
            else if retained != data || size > Self.fileLimit {
                try? retained.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }
    func flush() { queue.sync { drain(); prune() } }
    var queuedCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    func export(to destination: URL, permissionReady: Bool, observer: CiscoObservation = CiscoObservation()) throws {
        guard exportLock.try() else { throw IssueCode.exportBusy }
        defer { exportLock.unlock() }
        flush()
        let stage = root.appendingPathComponent("support-export", isDirectory: true)
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        var log = Data()
        try queue.sync {
            for index in stride(from: Self.fileCount - 1, through: 0, by: -1) {
                guard FileManager.default.fileExists(atPath: file(index).path) else { continue }
                let handle = try FileHandle(forReadingFrom: file(index)); defer { try? handle.close() }
                let data = try handle.read(upToCount: Self.fileLimit) ?? Data()
                for line in data.split(separator: 10) {
                    if let record = try? JSONDecoder().decode(DiagnosticRecord.self, from: Data(line)),
                       now() - record.at <= Self.retention, record.at <= now() + 60 {
                        let clean = try JSONEncoder().encode(record)
                        if log.count + clean.count + 1 <= Self.fileLimit * Self.fileCount { log.append(clean); log.append(10) }
                    }
                }
            }
        }
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
            let observer: CiscoObservation
            let storageFailed: Bool
        }
        lock.lock(); let power = lastPower; lock.unlock()
        let summary = Summary(format: 2, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "test",
                              macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture,
                              at: now(), powerPermissionReady: permissionReady, power: power, observer: observer, storageFailed: storageFailed)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(summary).write(to: stage.appendingPathComponent("summary.json"))
        try log.write(to: stage.appendingPathComponent("events.jsonl"))
        let help = """
        NoSleep: информация для диагностики
        Напишите: что нажали, что ожидали, что получилось и примерное время ошибки.
        Архив: версии, состояния функций, коды ошибок и события NoSleep.
        Нет паролей, логина, адреса VPN, IP, снимков экрана, профилей Cisco или системных журналов.
        Вы отправляете файл вручную. Логи: до 1 МБ, до 7 дней; повторные опросы не записываются.
        """
        try Data(help.utf8).write(to: stage.appendingPathComponent("README.txt"))
        let temporary = root.appendingPathComponent("support-report.zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", stage.path, temporary.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0); p.terminationHandler = { _ in done.signal() }
        try p.run()
        guard done.wait(timeout: .now() + 15) == .success else { p.terminate(); throw IssueCode.commandTimeout }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard p.terminationStatus == 0, size <= 1_100_000 else { throw IssueCode.storageError }
        try Data(contentsOf: temporary, options: .mappedIfSafe).write(to: destination, options: .atomic)
        record(.exported)
    }
}
