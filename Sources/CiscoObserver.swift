import Foundation
import Security
import Network
import Darwin

enum VPNLinkState: String, Codable {
    case unknown, disconnected, connecting, reconnecting, connected
    static func parse(_ text: String) -> VPNLinkState {
        var result = VPNLinkState.unknown
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces).lowercased()
            if [">> error:", ">> ошибка:", "error:", "ошибка:"].contains(where: value.hasPrefix) { return .unknown }
            guard value.hasPrefix(">> state:") else { continue }
            switch value.dropFirst(9).trimmingCharacters(in: .whitespacesAndNewlines) {
            case "connected", "подключено", "подключен": result = .connected
            case "disconnected", "отключено", "отключен": result = .disconnected
            case "connecting", "подключение", "соединение": result = .connecting
            case "reconnecting", "переподключение", "повторное подключение", "восстановление соединения": result = .reconnecting
            default: result = .unknown
            }
        }
        return result
    }
}

enum NativeRecovery: String, Codable { case enabled, disabled, unknown }
private final class RecoveryParser: NSObject, XMLParserDelegate {
    private var depth = 0
    private var initializationDepth: Int?
    private var reading = false
    private var readingDepth: Int?
    private var value = ""
    private var values: [String] = []
    static func parse(_ data: Data) -> NativeRecovery {
        guard data.count <= 1_048_576 else { return .unknown }
        let delegate = RecoveryParser(); let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.values.isEmpty, Set(delegate.values).count == 1 else { return .unknown }
        return delegate.values[0] == "true" ? .enabled : delegate.values[0] == "false" ? .disabled : .unknown
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth > 64 { parser.abortParsing(); return }
        if name == "ClientInitialization" { initializationDepth = depth }
        if name == "AutoReconnect", initializationDepth != nil { reading = true; readingDepth = depth; value = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if reading && depth == readingDepth {
            value += string
            if value.utf8.count > 64 { parser.abortParsing() }
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "AutoReconnect", reading { values.append(value.trimmingCharacters(in: .whitespacesAndNewlines)); reading = false; readingDepth = nil }
        if depth == initializationDepth { initializationDepth = nil }
        depth -= 1
    }
}

func parseNativeRecovery(_ data: Data) -> NativeRecovery { RecoveryParser.parse(data) }
func installedNativeRecovery() -> NativeRecovery {
    var policies: [NativeRecovery] = []
    for directory in ["/opt/cisco/secureclient/vpn/profile", "/opt/cisco/anyconnect/profile"] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in files.filter({ $0.hasSuffix(".xml") }).sorted().prefix(16) {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 1_048_576) { policies.append(parseNativeRecovery(data)) }
        }
    }
    guard let first = policies.first, policies.allSatisfy({ $0 == first }) else { return .unknown }
    return first
}

func verifiedCiscoApplication() -> URL? {
    for path in ["/Applications/Cisco/Cisco Secure Client.app", "/Applications/Cisco/Cisco AnyConnect Secure Mobility Client.app"] {
        let url = URL(fileURLWithPath: path)
        var code: SecStaticCode?; var requirement: SecRequirement?
        if SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
           SecRequirementCreateWithString("anchor apple generic and (identifier \"com.cisco.secureclient.gui\" or identifier \"com.cisco.anyconnect.gui\") and certificate leaf[subject.OU] = \"DE8Y96K9QP\"" as CFString, [], &requirement) == errSecSuccess,
           let code = code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess { return url }
    }
    return nil
}

final class ObservationCancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

protocol CiscoStateReading {
    var available: Bool { get }
    func readState(cancellation: ObservationCancellation) throws -> VPNLinkState
}

// This backend has one capability: a local status query. It accepts no host, command or credentials.
final class CiscoStateClient: CiscoStateReading {
    static let arguments = ["-s", "state"]
    private let path = ["/opt/cisco/secureclient/bin/vpn", "/opt/cisco/anyconnect/bin/vpn"]
        .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    var available: Bool { path != nil }
    private func verifiedURL() throws -> URL {
        guard let path = path else { throw IssueCode.missingClient }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else { throw IssueCode.untrustedClient }
        var code: SecStaticCode?; var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple generic and identifier \"vpn\" and certificate leaf[subject.OU] = \"DE8Y96K9QP\"" as CFString, [], &requirement) == errSecSuccess,
              let code = code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw IssueCode.untrustedClient }
        return url
    }
    func readState(cancellation: ObservationCancellation) throws -> VPNLinkState {
        guard !cancellation.cancelled else { throw IssueCode.cancelled }
        let url = try verifiedURL()
        guard !cancellation.cancelled else { throw IssueCode.cancelled }
        let process = Process(); let output = Pipe()
        process.executableURL = url; process.arguments = Self.arguments
        process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility
        try process.run()
        defer {
            try? output.fileHandleForReading.close()
            // Only this short-lived, owned status process can be terminated. Never touch vpnagentd or the GUI.
            if process.isRunning {
                process.terminate()
                let until = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw IssueCode.commandFailed }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 2048)
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while true {
            if cancellation.cancelled { throw IssueCode.cancelled }
            if ProcessInfo.processInfo.systemUptime > deadline { throw IssueCode.commandTimeout }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                guard data.count + count <= 16_384 else { throw IssueCode.outputLimit }
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 { break }
            else if errno != EAGAIN && errno != EWOULDBLOCK { throw IssueCode.commandFailed }
            else { Thread.sleep(forTimeInterval: 0.02) }
        }
        while process.isRunning {
            if cancellation.cancelled { throw IssueCode.cancelled }
            if ProcessInfo.processInfo.systemUptime > deadline { throw IssueCode.commandTimeout }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { throw IssueCode.commandFailed }
        let state = VPNLinkState.parse(String(decoding: data, as: UTF8.self))
        guard state != .unknown else { throw IssueCode.unsupportedState }
        return state
    }
}

struct CiscoObservation: Codable, Equatable {
    var enabled = false
    var available = false
    var link = VPNLinkState.unknown
    var nativeRecovery = NativeRecovery.unknown
    var online: Bool?
    var issue: IssueCode?
    var text: String {
        if !available { return "Cisco Secure Client не найден" }
        if !enabled { return "Наблюдение выключено. Cisco работает самостоятельно." }
        if issue != nil { return "Статус недоступен. Наблюдение остановлено; проверьте Cisco." }
        if online == false { return "Нет сети. Ожидаем восстановления сети и Cisco." }
        switch link {
        case .connected: return "Подключено. Соединением управляет Cisco."
        case .connecting, .reconnecting: return "Cisco восстанавливает соединение — ожидаем."
        case .disconnected: return "VPN отключён. Если нужен новый вход, откройте Cisco."
        case .unknown: return "Проверяем состояние Cisco…"
        }
    }
    var recoveryText: String {
        switch nativeRecovery {
        case .enabled: return "Автовосстановление включено в профиле Cisco."
        case .disabled: return "Автовосстановление выключено в профиле Cisco. Настройку меняет администратор VPN."
        case .unknown: return "Автовосстановление зависит от выбранного профиля Cisco."
        }
    }
}

struct ObservationPolicy {
    static let interval = 60.0
    var enabled = false
    var paused = false
    var nextRead = 0.0
    func allowsRead(available: Bool, online: Bool?, at now: Double) -> Bool {
        enabled && !paused && available && online == true && now >= nextRead
    }
    mutating func begin(at now: Double) { nextRead = now + Self.interval }
    mutating func finish(_ issue: IssueCode?) { if issue != nil { paused = true } }
}

final class CiscoObserver {
    private let queue = DispatchQueue(label: "NoSleep.cisco-observer", qos: .utility)
    private let monitor = NWPathMonitor()
    private let reader: CiscoStateReading
    private let defaults: UserDefaults
    private let diagnostics: DiagnosticStore
    private var timer: DispatchSourceTimer?
    private var policy = ObservationPolicy()
    private var view = CiscoObservation()
    private let cancellationLock = NSLock()
    private var cancellation: ObservationCancellation?
    private var stopped = false
    var changed: ((CiscoObservation) -> Void)?
    init(diagnostics: DiagnosticStore, reader: CiscoStateReading = CiscoStateClient(), defaults: UserDefaults = .standard) {
        self.diagnostics = diagnostics; self.reader = reader; self.defaults = defaults
        view.available = reader.available
        policy.enabled = reader.available && (defaults.object(forKey: "CiscoObservationEnabled") == nil || defaults.bool(forKey: "CiscoObservationEnabled"))
        view.issue = defaults.string(forKey: "CiscoObservationPause").flatMap(IssueCode.init(rawValue:))
        policy.paused = view.issue != nil
        view.enabled = policy.enabled
    }
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.view.online = path.status == .satisfied
            if path.status != .satisfied { self.view.link = .unknown }
            self.publish(); self.poll()
        }
        monitor.start(queue: queue)
        queue.async { [self] in
            self.view.nativeRecovery = installedNativeRecovery()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .distantFuture)
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume(); self.publish(); self.poll()
        }
    }
    private func publish() {
        cancellationLock.lock(); let inactive = stopped; cancellationLock.unlock()
        guard !inactive else { return }
        view.enabled = policy.enabled
        diagnostics.record(.observerState, DiagnosticFacts(observerEnabled: view.enabled, vpnState: view.link,
                            nativeRecovery: view.nativeRecovery, online: view.online, issue: view.issue))
        changed?(view)
    }
    private func poll() {
        defer { scheduleNextRead() }
        cancellationLock.lock(); let inactive = stopped; cancellationLock.unlock()
        guard !inactive, policy.allowsRead(available: reader.available, online: view.online, at: ProcessInfo.processInfo.systemUptime) else { return }
        policy.begin(at: ProcessInfo.processInfo.systemUptime)
        let token = ObservationCancellation()
        cancellationLock.lock(); cancellation = token; if stopped { token.cancel() }; cancellationLock.unlock()
        do {
            let link = try reader.readState(cancellation: token)
            guard !token.cancelled else { return }
            guard link != .unknown else { throw IssueCode.unsupportedState }
            view.link = link; view.issue = nil
            view.nativeRecovery = installedNativeRecovery()
        } catch {
            guard !token.cancelled else { return }
            view.link = .unknown
            view.issue = (error as? IssueCode) ?? .commandFailed
            policy.finish(view.issue)
            defaults.set(view.issue?.rawValue, forKey: "CiscoObservationPause")
        }
        publish()
    }
    private func scheduleNextRead() {
        cancellationLock.lock(); let inactive = stopped; cancellationLock.unlock()
        guard !inactive, policy.enabled, !policy.paused, reader.available, view.online == true else {
            timer?.schedule(deadline: .distantFuture); return
        }
        timer?.schedule(deadline: .now() + max(0.05, policy.nextRead - ProcessInfo.processInfo.systemUptime))
    }
    func setEnabled(_ value: Bool) {
        if !value { cancellationLock.lock(); cancellation?.cancel(); cancellationLock.unlock() }
        queue.async {
            self.policy.enabled = value && self.reader.available
            if value { self.policy.paused = false; self.view.issue = nil; self.defaults.removeObject(forKey: "CiscoObservationPause") }
            else { self.view.link = .unknown }
            self.defaults.set(self.policy.enabled, forKey: "CiscoObservationEnabled")
            self.diagnostics.record(.observerAction, DiagnosticFacts(observerEnabled: self.policy.enabled))
            self.publish(); self.poll()
        }
    }
    func stop() {
        cancellationLock.lock(); stopped = true; cancellation?.cancel(); cancellationLock.unlock()
        monitor.cancel()
        let done = DispatchSemaphore(value: 0)
        queue.async { self.timer?.cancel(); self.timer = nil; done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }
    // Deterministic self-test seam: uses the injected state reader, never a connection API.
    func checkOnceForTesting(online: Bool) { queue.sync { view.online = online; poll() } }
}
