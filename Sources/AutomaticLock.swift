import AppKit
import Security
import Darwin

enum ScreenLockFailure: LocalizedError {
    case unavailable, invalidPolicy, refused, timeout, outputLimit, changed, journal, busy
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Не удалось прочитать настройку автоблокировки macOS."
        case .invalidPolicy: return "macOS вернула неизвестную настройку автоблокировки."
        case .refused: return "macOS не подтвердила изменение автоблокировки. Проверьте пароль и повторите."
        case .timeout: return "Изменение автоблокировки не завершилось вовремя. Повторите проверку."
        case .outputLimit: return "Не удалось безопасно прочитать ответ macOS."
        case .changed: return "Настройка изменилась во время подтверждения. Повторите действие."
        case .journal: return "Не удалось прочитать или сохранить исходную настройку. Изменение не подтверждено."
        case .busy: return "Предыдущее изменение автоблокировки ещё не завершено."
        }
    }
    static func safe(_ error: Error) -> ScreenLockFailure { error as? ScreenLockFailure ?? .refused }
}

struct ScreenLockPolicy: Equatable {
    let delay: Int
    init(_ delay: Int) throws {
        guard (-1..<Int(Int32.max)).contains(delay) else { throw ScreenLockFailure.invalidPolicy }
        self.delay = delay
    }
    static let off = try! ScreenLockPolicy(-1)
    var argument: String { delay == -1 ? "off" : delay == 0 ? "immediate" : String(delay) }
    var description: String { delay == -1 ? "не блокировать" : delay == 0 ? "сразу" : "через \(delay) с" }
    static func parse(_ text: String) throws -> ScreenLockPolicy {
        let expression = try NSRegularExpression(pattern: #"(?m)(?:^|\]\s+)screenLock (?:delay is|is) (off|immediate|[0-9]+)(?: seconds?)?\s*$"#)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: text) else {
            throw ScreenLockFailure.invalidPolicy
        }
        let word = String(text[range])
        if word == "off" { return .off }
        if word == "immediate" { return try ScreenLockPolicy(0) }
        guard let value = Int(word) else { throw ScreenLockFailure.invalidPolicy }
        return value == Int(Int32.max) ? .off : try ScreenLockPolicy(value)
    }
}

final class ScreenLockSecret {
    private var bytes: Data
    init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4096, !value.contains("\n"), !value.contains("\r") else {
            throw ScreenLockFailure.refused
        }
        bytes = Data(value.utf8)
    }
    var erased: Bool { bytes.isEmpty }
    func line() throws -> Data {
        guard !bytes.isEmpty else { throw ScreenLockFailure.refused }
        var result = bytes; result.append(10); return result
    }
    func erase() { bytes.resetBytes(in: 0..<bytes.count); bytes.removeAll(keepingCapacity: false) }
    deinit { erase() }
}

// Runs on the policy queue. Nonblocking reads bound both output and execution,
// including a child that fills stderr before reading its password pipe.
enum BoundedLockProcess {
    static func run(_ executable: URL, _ arguments: [String], input: Data = Data(),
                    seconds: Double = 8, limit: Int = 16384) throws -> String {
        guard input.count <= 4097, seconds > 0, seconds <= 30, limit > 0, limit <= 1_048_576 else {
            throw ScreenLockFailure.refused
        }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        let output = Pipe(), password = Pipe()
        process.standardOutput = output; process.standardError = output; process.standardInput = password
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            if ended.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 1)
            }
        }
        defer {
            try? password.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        do { try process.run() } catch { throw ScreenLockFailure.unavailable }
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { stop(); throw ScreenLockFailure.unavailable }
        let passwordFD = password.fileHandleForWriting.fileDescriptor
        guard fcntl(passwordFD, F_SETNOSIGPIPE, 1) != -1 else { stop(); throw ScreenLockFailure.unavailable }
        let written = input.withUnsafeBytes { bytes in Darwin.write(passwordFD, bytes.baseAddress, bytes.count) }
        guard written == input.count else { stop(); throw ScreenLockFailure.refused }
        try? password.fileHandleForWriting.close()
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var exited = false
        while true {
            var drained = false
            repeat {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard result.count + count <= limit else { stop(); throw ScreenLockFailure.outputLimit }
                    result.append(contentsOf: buffer.prefix(count))
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                    drained = true
                } else if errno != EINTR {
                    stop(); throw ScreenLockFailure.unavailable
                }
            } while !drained
            if exited { break }
            if !process.isRunning { process.waitUntilExit(); exited = true; continue }
            if ProcessInfo.processInfo.systemUptime >= deadline { stop(); throw ScreenLockFailure.timeout }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.terminationStatus == 0 else { throw ScreenLockFailure.refused }
        return String(decoding: result, as: UTF8.self)
    }
}

protocol ScreenLockCommandRunning {
    func run(_ arguments: [String], secret: ScreenLockSecret?) throws -> String
}
struct SystemScreenLockCommand: ScreenLockCommandRunning {
    func run(_ arguments: [String], secret: ScreenLockSecret?) throws -> String {
        var input = try secret?.line() ?? Data()
        defer { input.resetBytes(in: 0..<input.count) }
        return try BoundedLockProcess.run(URL(fileURLWithPath: "/usr/sbin/sysadminctl"), arguments, input: input)
    }
}
protocol ScreenLockBackend {
    func read() throws -> ScreenLockPolicy
    func write(_ policy: ScreenLockPolicy, secret: ScreenLockSecret) throws
}
final class SystemScreenLockBackend: ScreenLockBackend {
    let command: ScreenLockCommandRunning
    let consoleSession: () -> Bool
    init(command: ScreenLockCommandRunning = SystemScreenLockCommand(),
         consoleSession: @escaping () -> Bool = SystemScreenLockBackend.isConsoleSession) {
        self.command = command; self.consoleSession = consoleSession
    }
    static func isConsoleSession() -> Bool {
        var info = stat()
        guard getuid() != 0, stat("/dev/console", &info) == 0, info.st_uid == getuid(),
              let raw = CGSessionCopyCurrentDictionary() as NSDictionary?,
              (raw["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == getuid(),
              let audit = raw["kCGSSessionAuditIDKey"] as? NSNumber else { return false }
        var session: SecuritySessionId = 0; var attributes: SessionAttributeBits = []
        return SessionGetInfo(callerSecuritySession, &session, &attributes) == errSecSuccess &&
            session == audit.uint32Value && attributes.contains(.sessionHasGraphicAccess)
    }
    func read() throws -> ScreenLockPolicy {
        guard consoleSession() else { throw ScreenLockFailure.unavailable }
        return try ScreenLockPolicy.parse(command.run(["-screenLock", "status"], secret: nil))
    }
    func write(_ policy: ScreenLockPolicy, secret: ScreenLockSecret) throws {
        guard consoleSession() else { throw ScreenLockFailure.unavailable }
        let response = try command.run(["-screenLock", policy.argument, "-password", "-"], secret: secret)
        // sysadminctl can report a keybag refusal while returning exit status 0.
        guard !response.contains("###") else { throw ScreenLockFailure.refused }
    }
}

protocol ScreenLockRestoreStore {
    func read() throws -> ScreenLockPolicy?
    func save(_ policy: ScreenLockPolicy) throws
    func clear() throws
}
final class FileScreenLockRestoreStore: ScreenLockRestoreStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("restore.json") }
    private struct Record: Codable { let schema: Int; let delay: Int }
    init(directory: URL) { self.directory = directory }
    private func checkDirectory(create: Bool) throws -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw ScreenLockFailure.journal }
            if !create { return false }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw ScreenLockFailure.journal }
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ScreenLockFailure.journal }
        return true
    }
    private func checkedFD() throws -> Int32? {
        guard try checkDirectory(create: false) else { return nil }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ScreenLockFailure.journal
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o077 == 0, info.st_size <= 1024 else {
            close(fd); throw ScreenLockFailure.journal
        }
        return fd
    }
    func read() throws -> ScreenLockPolicy? {
        do {
            guard let fd = try checkedFD() else { return nil }
            defer { close(fd) }
            var bytes = [UInt8](repeating: 0, count: 1025)
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0, count <= 1024 else { throw ScreenLockFailure.journal }
            let data = Data(bytes.prefix(count))
            let keys = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys
            guard let keys, Set(keys) == Set(["schema", "delay"]) else { throw ScreenLockFailure.journal }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.schema == 1 else { throw ScreenLockFailure.journal }
            return try ScreenLockPolicy(record.delay)
        } catch { throw ScreenLockFailure.journal }
    }
    func save(_ policy: ScreenLockPolicy) throws {
        do {
            _ = try checkDirectory(create: true)
            if let previous = try read(), previous != policy { throw ScreenLockFailure.journal }
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ScreenLockFailure.journal }
            defer { close(fd); unlink(temporary.path) }
            let data = try JSONEncoder().encode(Record(schema: 1, delay: policy.delay))
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == data.count, fsync(fd) == 0, rename(temporary.path, file.path) == 0 else {
                throw ScreenLockFailure.journal
            }
            let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parent >= 0 else { throw ScreenLockFailure.journal }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw ScreenLockFailure.journal }
        } catch { throw ScreenLockFailure.journal }
    }
    func clear() throws {
        guard let fd = try checkedFD() else { return }
        close(fd)
        guard unlink(file.path) == 0 else { throw ScreenLockFailure.journal }
    }
}

struct AutomaticLockState {
    var ready = false, enabled = false, recovery = false
    var policy: ScreenLockPolicy?
    var issue: ScreenLockFailure?
}
struct ScreenLockPlan {
    let id = UUID()
    let enabled: Bool
    let expected: ScreenLockPolicy?
    let target: ScreenLockPolicy?
    let priorRestore: ScreenLockPolicy?
    let original: ScreenLockPolicy?
    var needsPassword: Bool { target != nil && target != expected }
}
final class AutomaticLockModel {
    let backend: ScreenLockBackend, store: ScreenLockRestoreStore
    private(set) var state = AutomaticLockState()
    private var restore: ScreenLockPolicy?
    private var pending: UUID?
    init(backend: ScreenLockBackend, store: ScreenLockRestoreStore) { self.backend = backend; self.store = store }
    func load() throws {
        do {
            let captured = try store.read()
            if (state.ready || restore != nil) && captured != restore { throw ScreenLockFailure.journal }
            restore = captured
            state.policy = try backend.read()
            if !state.ready { state.enabled = restore != nil; state.recovery = restore != nil }
            state.ready = true; state.issue = nil
        } catch { state.issue = .safe(error); throw ScreenLockFailure.safe(error) }
    }
    func prepare(enabled: Bool) throws -> ScreenLockPlan {
        guard pending == nil else { throw ScreenLockFailure.busy }
        do {
            let original = try store.read()
            if (state.ready || restore != nil) && original != restore { throw ScreenLockFailure.journal }
            if !enabled && original == nil && !state.enabled {
                let plan = ScreenLockPlan(enabled: false, expected: nil, target: nil, priorRestore: nil, original: nil)
                pending = plan.id; return plan
            }
            if !state.ready { try load() }
            let actual = try backend.read()
            let plan = ScreenLockPlan(enabled: enabled, expected: actual, target: enabled ? .off : original,
                                      priorRestore: original, original: original ?? actual)
            pending = plan.id; state.policy = actual; state.issue = nil; return plan
        } catch { state.issue = .safe(error); throw ScreenLockFailure.safe(error) }
    }
    func cancel(_ plan: ScreenLockPlan) {
        if pending == plan.id { pending = nil }
    }
    func apply(_ plan: ScreenLockPlan, secret: ScreenLockSecret?) throws {
        defer { secret?.erase() }
        guard pending == plan.id else { throw ScreenLockFailure.changed }
        defer { pending = nil }
        let wasEnabled = state.enabled
        do {
            guard try store.read() == plan.priorRestore else { throw ScreenLockFailure.changed }
            guard let target = plan.target else { state.enabled = false; state.issue = nil; return }
            guard try backend.read() == plan.expected else { throw ScreenLockFailure.changed }
            if plan.needsPassword && (secret == nil || secret!.erased) { throw ScreenLockFailure.refused }
            if plan.enabled && plan.priorRestore == nil {
                guard let original = plan.original else { throw ScreenLockFailure.journal }
                try store.save(original); restore = original
            }
            if plan.needsPassword { try backend.write(target, secret: secret!) }
            guard try backend.read() == target else { throw ScreenLockFailure.refused }
            if !plan.enabled { try store.clear(); restore = nil }
            state.enabled = plan.enabled; state.policy = target; state.recovery = false; state.issue = nil
        } catch {
            state.enabled = wasEnabled; state.issue = .safe(error)
            state.policy = try? backend.read()
            if restore == nil, plan.enabled, let captured = try? store.read(), captured == plan.original {
                restore = captured
            }
            if !wasEnabled, let restore, state.policy == restore {
                if (try? store.clear()) != nil { self.restore = nil }
            }
            state.recovery = restore != nil && !wasEnabled
            throw ScreenLockFailure.safe(error)
        }
    }
    var requiresRestoration: Bool { restore != nil || state.enabled }
}

final class AutomaticLockController {
    let model: AutomaticLockModel
    let queue = DispatchQueue(label: "NoSleep.AutomaticLock")
    private(set) var state = AutomaticLockState()
    private(set) var requiresRestoration = false
    var changed: ((AutomaticLockState) -> Void)?
    init(backend: ScreenLockBackend, store: ScreenLockRestoreStore) {
        model = AutomaticLockModel(backend: backend, store: store)
    }
    private func deliver(_ completion: @escaping () -> Void) {
        let snapshot = model.state, restoration = model.requiresRestoration
        DispatchQueue.main.async {
            self.state = snapshot; self.requiresRestoration = restoration
            self.changed?(snapshot); completion()
        }
    }
    func load() { queue.async { try? self.model.load(); self.deliver({}) } }
    func prepare(enabled: Bool, completion: @escaping (Result<ScreenLockPlan, ScreenLockFailure>) -> Void) {
        queue.async {
            let result: Result<ScreenLockPlan, ScreenLockFailure>
            do { result = .success(try self.model.prepare(enabled: enabled)) }
            catch { result = .failure(.safe(error)) }
            self.deliver { completion(result) }
        }
    }
    func apply(_ plan: ScreenLockPlan, secret: ScreenLockSecret?, completion: @escaping (Bool) -> Void) {
        queue.async {
            let success: Bool
            do { try self.model.apply(plan, secret: secret); success = true } catch { success = false }
            self.deliver { completion(success) }
        }
    }
    func cancel(_ plan: ScreenLockPlan, completion: @escaping () -> Void) {
        queue.async { self.model.cancel(plan); self.deliver(completion) }
    }
}
