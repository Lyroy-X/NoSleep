import Foundation
func featureExpect(_ expression: @autoclosure () throws -> Bool) throws { let result = try expression(); assert(result) }
func aggregateTitle(system: Bool, display: Bool, observing: Bool = false) -> String { system || display || observing ? "Выключить всё" : "Включить всё" }
func featureTests() throws {
    for bits in 0..<8 { assert(aggregateTitle(system: bits & 1 != 0, display: bits & 2 != 0, observing: bits & 4 != 0) == (bits == 0 ? "Включить всё" : "Выключить всё")) }
    let power = FakePower(); let engine = GuardEngine(power)
    let on = DispatchSemaphore(value: 0)
    engine.act("all-on", save: false) { on.signal() }
    assert(on.wait(timeout: .now() + 3) == .success)
    let enabled = engine.queue.sync { engine.state() }
    assert(enabled.systemWanted && enabled.systemActual && enabled.displayWanted && enabled.displayActual && enabled.error == nil)
    let off = DispatchSemaphore(value: 0)
    engine.act("all-off", save: false) { off.signal() }
    assert(off.wait(timeout: .now() + 3) == .success)
    let disabled = engine.queue.sync { engine.state() }
    assert(!disabled.systemWanted && !disabled.systemActual && !disabled.displayWanted && !disabled.displayActual && disabled.error == nil)
    try observerTests()
    try diagnosticsTests()
    try diagnosticStreamingTests()
    if ProcessInfo.processInfo.environment["NOSLEEP_TEST_LARGE_LOGS"] == "1" { try diagnosticLargeBudgetTests() }
    print("PASS: all combined-control states")
}
func diagnosticsTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoSleep-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let segmentLimit = 8192
    let store = DiagnosticStore(root: root, segmentLimit: segmentLimit)
    for _ in 0..<10000 { store.record(.powerState, DiagnosticFacts(sleepWanted: true)) }
    store.flush()
    let logRoot = root.appendingPathComponent("diagnostics")
    let first = logRoot.appendingPathComponent("events-0.jsonl")
    let initial = try Data(contentsOf: first)
    assert(initial.split(separator: 10).count == 1, "Repeated observations spammed logs")
    // Seed VALID records to prove rotation, rather than passing by deleting malformed test data.
    for index in 0..<DiagnosticStore.fileCount {
        var record = try JSONEncoder().encode(DiagnosticRecord(at: Date().timeIntervalSince1970, kind: .powerAction, facts: DiagnosticFacts(number: index)))
        record.append(10)
        var seed = Data()
        while seed.count + record.count <= segmentLimit { seed.append(record) }
        let padding = segmentLimit - seed.count
        seed.removeLast(); seed.append(Data(repeating: 32, count: padding)); seed.append(10)
        try seed.write(to: logRoot.appendingPathComponent("events-\(index).jsonl"))
    }
    store.record(.powerState, DiagnosticFacts(sleepWanted: false)); store.flush()
    var total = 0
    for file in try FileManager.default.contentsOfDirectory(at: logRoot, includingPropertiesForKeys: nil) {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).intValue
        assert(size <= segmentLimit); total += size
    }
    assert(total <= DiagnosticStore.fileCount * segmentLimit)
    for index in 1..<DiagnosticStore.fileCount {
        let rotated = try Data(contentsOf: logRoot.appendingPathComponent("events-\(index).jsonl"))
        let entry = try JSONDecoder().decode(DiagnosticRecord.self, from: Data(rotated.split(separator: 10)[0]))
        assert(entry.facts.number == index - 1, "Valid records failed to rotate in order")
    }
    // Unknown text is never copied into the shareable output, even if a file is edited.
    let injected = #"{"at":TIME,"kind":"powerState","facts":{"sleepWanted":true,"password":"SENTINEL-SECRET","username":"SENTINEL-USER","server":"vpn.private.invalid"}}"#
        .replacingOccurrences(of: "TIME", with: String(Date().timeIntervalSince1970)) + "\nRAW SENTINEL-SECRET\n"
    try Data(injected.utf8).write(to: first)
    let zip = root.appendingPathComponent("check.zip")
    try store.export(to: zip, permissionReady: true)
    store.flush()
    let process = Process(); let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", zip.path]; process.standardOutput = output
    try process.run(); let body = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    let text = String(decoding: body, as: UTF8.self)
    assert(!text.contains("SENTINEL") && !text.contains("vpn.private.invalid"))
    assert(text.contains("sleepWanted") && text.contains("appVersion"))
    assert(!FileManager.default.fileExists(atPath: root.appendingPathComponent("support-export").path))
    let old = DiagnosticRecord(at: Date().timeIntervalSince1970 - 8 * 24 * 3600, kind: .launch, facts: DiagnosticFacts())
    let recent = DiagnosticRecord(at: Date().timeIntervalSince1970, kind: .powerState, facts: DiagnosticFacts(sleepWanted: false))
    var mixed = try JSONEncoder().encode(old); mixed.append(10)
    mixed.append(try JSONEncoder().encode(recent)); mixed.append(10)
    try mixed.write(to: first)
    store.flush()
    let kept = try Data(contentsOf: first).split(separator: 10)
    try featureExpect(kept.count == 1 && (try JSONDecoder().decode(DiagnosticRecord.self, from: Data(kept[0]))).kind == .powerState)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 24 * 3600)], ofItemAtPath: first.path)
    store.flush(); assert(!FileManager.default.fileExists(atPath: first.path))
    for i in 0..<10000 {
        store.record(.powerAction, DiagnosticFacts(number: i))
        assert(store.queuedCount <= DiagnosticStore.queueLimit)
    }
    store.flush()
    let flood = try Data(contentsOf: first).split(separator: 10)
    assert(flood.count < 200, "Unique event flood bypassed the rate limit")
    let actionRoot = root.appendingPathComponent("actions")
    let actions = DiagnosticStore(root: actionRoot)
    actions.record(.powerAction, DiagnosticFacts(number: 1)); actions.record(.powerAction, DiagnosticFacts(number: 1)); actions.flush()
    let actionData = try Data(contentsOf: actionRoot.appendingPathComponent("diagnostics/events-0.jsonl"))
    assert(actionData.split(separator: 10).count == 2, "Distinct repeated actions lost in diagnostic history")
    let blockedRoot = root.appendingPathComponent("not-a-directory")
    try Data().write(to: blockedRoot)
    let broken = DiagnosticStore(root: blockedRoot)
    broken.record(.launch); broken.flush()
    assert(broken.storageFailed, "Storage failure hidden")
    print("PASS: duplicate/unique floods, bounded queue/rate, rotation, record-level retention, archive filtering and cleanup")
}
