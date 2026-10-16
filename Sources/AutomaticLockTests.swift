import Foundation
import Darwin

struct ScreenLockTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { "Assertion failed: \(message)" }
}
func lockRequire(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw ScreenLockTestFailure(message: message) }
}
func lockFailure(_ body: () throws -> Void) throws {
    var refused = false
    do { try body() } catch is ScreenLockFailure { refused = true }
    try lockRequire(refused, "unsafe lock operation must refuse")
}
final class TestScreenLockBackend: ScreenLockBackend {
    var value: ScreenLockPolicy
    var rejectRead = false, rejectWrite = false, ignoreWrite = false, ambiguousWrite = false
    var writes: [ScreenLockPolicy] = []
    var reads = 0
    var beforeWrite: (() -> Bool)?
    var journalsSeen: [Bool] = []
    init(_ value: ScreenLockPolicy) { self.value = value }
    func read() throws -> ScreenLockPolicy {
        reads += 1
        if rejectRead { throw ScreenLockFailure.unavailable }
        return value
    }
    func write(_ policy: ScreenLockPolicy, secret: ScreenLockSecret) throws {
        if let beforeWrite { journalsSeen.append(beforeWrite()) }
        writes.append(policy)
        if rejectWrite { throw ScreenLockFailure.refused }
        if !ignoreWrite { value = policy }
        if ambiguousWrite { throw ScreenLockFailure.timeout }
    }
}
final class TestScreenLockStore: ScreenLockRestoreStore {
    var value: ScreenLockPolicy?
    var rejectRead = false, rejectSave = false, rejectClear = false, saveThenFail = false
    func read() throws -> ScreenLockPolicy? {
        if rejectRead { throw ScreenLockFailure.journal }
        return value
    }
    func save(_ policy: ScreenLockPolicy) throws {
        if rejectSave { throw ScreenLockFailure.journal }
        value = policy
        if saveThenFail { throw ScreenLockFailure.journal }
    }
    func clear() throws {
        if rejectClear { throw ScreenLockFailure.journal }
        value = nil
    }
}
final class TestScreenLockCommand: ScreenLockCommandRunning {
    var reply = "screenLock delay is immediate"
    var calls: [[String]] = []
    var passwords: [Data?] = []
    func run(_ arguments: [String], secret: ScreenLockSecret?) throws -> String {
        calls.append(arguments); passwords.append(try secret?.line()); return reply
    }
}

func automaticLockTests() throws {
    let immediate = try ScreenLockPolicy(0), delayed = try ScreenLockPolicy(120)
    for (text, expected) in [
        ("screenLock is off", ScreenLockPolicy.off),
        ("2026-10-16 sysadminctl[12:13] screenLock delay is immediate\n", immediate),
        ("screenLock delay is 120 seconds", delayed),
        ("screenLock delay is 2147483647", .off)
    ] { try lockRequire(ScreenLockPolicy.parse(text) == expected, "bounded screen-lock status parser") }
    for text in ["", "unrelated", "screenLock delay is unknown", "screenLock delay is -2",
                 "screenLock is off\nscreenLock delay is immediate", "screenLock delay is 2147483648"] {
        try lockFailure { _ = try ScreenLockPolicy.parse(text) }
    }
    for value in [-2, Int(Int32.max)] { try lockFailure { _ = try ScreenLockPolicy(value) } }
    for value in ["", "one\ntwo", "one\rtwo", String(repeating: "a", count: 4097)] {
        try lockFailure { _ = try ScreenLockSecret(value) }
    }
    let bounded = try ScreenLockSecret(String(repeating: "a", count: 4096))
    try lockRequire(bounded.line().count == 4097, "password boundary includes only transport newline")
    bounded.erase(); try lockFailure { _ = try bounded.line() }

    let command = TestScreenLockCommand()
    let denied = SystemScreenLockBackend(command: command, consoleSession: { false })
    try lockFailure { _ = try denied.read() }
    try lockFailure { try denied.write(.off, secret: ScreenLockSecret("fixture")) }
    try lockRequire(command.calls.isEmpty, "foreign security session never reaches system command")
    let permitted = SystemScreenLockBackend(command: command, consoleSession: { true })
    try lockRequire(permitted.read() == immediate, "system adapter reads exact status command")
    let transport = try ScreenLockSecret("fixture '$() secret")
    command.reply = ""
    try permitted.write(.off, secret: transport)
    try lockRequire(command.calls.last == ["-screenLock", "off", "-password", "-"], "password absent from argv")
    try lockRequire(command.passwords.last! == Data("fixture '$() secret\n".utf8), "password goes only through stdin")
    command.reply = "### MKBDeviceSetGracePeriod error -3"
    try lockFailure { try permitted.write(immediate, secret: transport) }
    transport.erase()

    func fixture(_ policy: ScreenLockPolicy = immediate) -> (AutomaticLockModel, TestScreenLockBackend, TestScreenLockStore) {
        let backend = TestScreenLockBackend(policy), store = TestScreenLockStore()
        backend.beforeWrite = { store.value == policy }
        return (AutomaticLockModel(backend: backend, store: store), backend, store)
    }
    do {
        let (model, backend, store) = fixture(delayed); try model.load()
        let plan = try model.prepare(enabled: true), secret = try ScreenLockSecret("fixture")
        try model.apply(plan, secret: secret)
        try lockRequire(backend.journalsSeen == [true], "restoration journal must precede policy mutation")
        try lockRequire(model.state.enabled && backend.value == .off && store.value == delayed && secret.erased,
                        "enable captures original delay and erases password")
        let restored = AutomaticLockModel(backend: backend, store: store); try restored.load()
        try lockRequire(restored.state.recovery && restored.state.enabled && backend.writes.count == 1,
                        "restart offers recovery without applying a saved desire")
        try restored.apply(restored.prepare(enabled: false), secret: ScreenLockSecret("fixture"))
        try lockRequire(!restored.state.enabled && backend.value == delayed && store.value == nil,
                        "recovery restores exact original delay")
    }
    do {
        let (model, backend, store) = fixture(); try model.load()
        let canceled = try model.prepare(enabled: true)
        try lockFailure { _ = try model.prepare(enabled: false) }
        model.cancel(canceled)
        let secret = try ScreenLockSecret("fixture")
        try lockFailure { try model.apply(canceled, secret: secret) }
        try lockRequire(!model.state.enabled && store.value == nil && backend.writes.isEmpty && secret.erased,
                        "cancel/stale/duplicate operations leave original state unchanged")
        backend.rejectWrite = true
        let refused = try model.prepare(enabled: true), bad = try ScreenLockSecret("fixture")
        try lockFailure { try model.apply(refused, secret: bad) }
        try lockRequire(!model.state.enabled && backend.value == immediate && store.value == nil && bad.erased,
                        "wrong password retains checkbox and confirmed policy")
        backend.rejectWrite = false
        try model.apply(model.prepare(enabled: true), secret: ScreenLockSecret("fixture"))
        backend.rejectWrite = true
        try lockFailure { try model.apply(model.prepare(enabled: false), secret: ScreenLockSecret("fixture")) }
        try lockRequire(model.state.enabled && store.value == immediate, "failed restore retains ownership and journal")
        backend.rejectWrite = false
        try model.apply(model.prepare(enabled: false), secret: ScreenLockSecret("fixture"))
        try lockRequire(!model.state.enabled && store.value == nil, "restore retry retains original capture")
    }
    do {
        let (model, backend, store) = fixture(); try model.load()
        backend.ambiguousWrite = true
        try lockFailure { try model.apply(model.prepare(enabled: true), secret: ScreenLockSecret("fixture")) }
        try lockRequire(!model.state.enabled && model.state.recovery && store.value == immediate,
                        "ambiguous mutation keeps journal and previous checkbox")
        backend.ambiguousWrite = false
        let retry = try model.prepare(enabled: true)
        try lockRequire(!retry.needsPassword, "already-applied retry does not request another password")
        try model.apply(retry, secret: nil)
        store.rejectClear = true
        try lockFailure { try model.apply(model.prepare(enabled: false), secret: ScreenLockSecret("fixture")) }
        try lockRequire(model.state.enabled && backend.value == immediate && store.value == immediate,
                        "journal cleanup failure remains recoverable")
        store.rejectClear = false
        let clean = try model.prepare(enabled: false)
        try lockRequire(!clean.needsPassword, "confirmed restoration retry only clears journal")
        try model.apply(clean, secret: nil)
    }
    do {
        let (model, backend, store) = fixture(); try model.load()
        let plan = try model.prepare(enabled: true); backend.value = delayed
        try lockFailure { try model.apply(plan, secret: ScreenLockSecret("fixture")) }
        try lockRequire(backend.value == delayed && backend.writes.isEmpty && store.value == nil,
                        "external setting changes are never overwritten")
        backend.value = immediate
        try model.apply(model.prepare(enabled: true), secret: ScreenLockSecret("fixture"))
        store.value = delayed
        try lockFailure { try model.load() }
        try lockFailure { _ = try model.prepare(enabled: false) }
        try lockRequire(model.state.enabled && backend.value == .off, "foreign journal cannot replace saved original")
    }
    for afterSave in [false, true] {
        let (model, backend, store) = fixture(); try model.load()
        store.rejectSave = !afterSave; store.saveThenFail = afterSave
        try lockFailure { try model.apply(model.prepare(enabled: true), secret: ScreenLockSecret("fixture")) }
        try lockRequire(backend.writes.isEmpty && !model.state.enabled, "journal persistence failure forbids policy mutation")
    }
    do {
        let (model, backend, store) = fixture(.off); try model.load()
        let on = try model.prepare(enabled: true); try lockRequire(!on.needsPassword, "existing off policy needs no password")
        try model.apply(on, secret: nil)
        try model.apply(model.prepare(enabled: false), secret: nil)
        try lockRequire(backend.writes.isEmpty && store.value == nil, "original off is preserved without artificial authentication")
        backend.rejectRead = true
        let unused = AutomaticLockModel(backend: backend, store: store)
        let reads = backend.reads
        try unused.apply(unused.prepare(enabled: false), secret: nil)
        try lockRequire(backend.reads == reads, "unowned all-off does not depend on lock backend availability")
    }
    do {
        let (model, backend, store) = fixture(); try model.load(); backend.ignoreWrite = true
        try lockFailure { try model.apply(model.prepare(enabled: true), secret: ScreenLockSecret("fixture")) }
        try lockRequire(!model.state.enabled && store.value == nil, "unconfirmed status never enables checkbox")
        store.rejectRead = true
        try lockFailure { _ = try model.prepare(enabled: true) }
        try lockRequire(backend.value == immediate, "unreadable restoration state fails closed")
    }
    try screenLockStoreTests()
    try screenLockProcessTests()
    print("PASS: automatic lock parser, password transport, journal ownership, refusal, retry and recovery; no real policy actions")
}

func screenLockStoreTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoSleep-lock-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileScreenLockRestoreStore(directory: root.appendingPathComponent("private"))
    let immediate = try ScreenLockPolicy(0)
    try lockRequire(store.read() == nil, "missing journal is not an error")
    try store.save(immediate); try lockRequire(store.read() == immediate, "atomic journal roundtrip")
    var info = stat(); _ = stat(store.file.path, &info)
    try lockRequire(info.st_mode & 0o777 == 0o600, "journal is private")
    try lockFailure { try store.save(ScreenLockPolicy(120)) }
    try lockRequire(store.read() == immediate, "saved original is never replaced")
    try store.clear()
    for malformed in ["{}", #"{"schema":2,"delay":0}"#, #"{"schema":true,"delay":0}"#,
                      #"{"schema":1,"delay":-2}"#, #"{"schema":1,"delay":0,"extra":1}"#, String(repeating: "x", count: 2048)] {
        try Data(malformed.utf8).write(to: store.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.file.path)
        try lockFailure { _ = try store.read() }
        try FileManager.default.removeItem(at: store.file)
    }
    let outside = root.appendingPathComponent("outside.json")
    try Data(#"{"schema":1,"delay":0}"#.utf8).write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
    try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: outside)
    try lockFailure { _ = try store.read() }
    try lockFailure { try store.save(immediate) }
    try lockFailure { try store.clear() }
    try lockRequire(FileManager.default.fileExists(atPath: outside.path), "journal symlink cannot touch another file")
    try FileManager.default.removeItem(at: store.file)
    let linked = FileScreenLockRestoreStore(directory: root.appendingPathComponent("linked"))
    try FileManager.default.createSymbolicLink(at: linked.directory, withDestinationURL: store.directory)
    try lockFailure { _ = try linked.read() }
    try lockFailure { try linked.save(immediate) }
    try store.save(immediate)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
    try lockFailure { _ = try store.read() }
}

func screenLockProcessTests() throws {
    let shell = URL(fileURLWithPath: "/bin/sh")
    let text = try BoundedLockProcess.run(shell, ["-c", #"IFS= read -r value; printf "%s" "$value""#],
                                         input: Data("fixture '$() text\n".utf8))
    try lockRequire(text == "fixture '$() text", "owned process transports stdin without shell expansion")
    try lockFailure { _ = try BoundedLockProcess.run(URL(fileURLWithPath: "/not/a/command"), []) }
    try lockFailure { _ = try BoundedLockProcess.run(URL(fileURLWithPath: "/usr/bin/false"), []) }
    try lockFailure { _ = try BoundedLockProcess.run(URL(fileURLWithPath: "/usr/bin/yes"), ["fixture"], limit: 512) }
    let started = ProcessInfo.processInfo.systemUptime
    try lockFailure { _ = try BoundedLockProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], seconds: 0.05) }
    try lockRequire(ProcessInfo.processInfo.systemUptime - started < 3, "timed-out owned command is stopped")
    try lockFailure { _ = try BoundedLockProcess.run(shell, [], input: Data(repeating: 0, count: 4098)) }
}
