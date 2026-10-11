import Foundation

func diagnosticStreamingTests() throws {
    assert(DiagnosticStore.fileLimit == 50_000_000 && DiagnosticStore.logLimit == 200_000_000)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoSleep-stream-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    var time = Date().timeIntervalSince1970
    let record = DiagnosticRecord(at: time, kind: .launch, facts: DiagnosticFacts(number: 7))
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let clean = try encoder.encode(record)
    // Valid JSON across a 64-KiB boundary, oversized line, and a final line without newline.
    var input = Data(repeating: 10, count: DiagnosticStreaming.chunkLimit - 40)
    input.append(clean); input.append(Data(repeating: 32, count: 1800)); input.append(10)
    input.append(Data(repeating: 120, count: 2 * DiagnosticStreaming.chunkLimit)); input.append(10)
    input.append(clean); input.append(10); input.append(clean)
    let source = root.appendingPathComponent("input.jsonl"); try input.write(to: source)
    let target = root.appendingPathComponent("output.jsonl")
    let writer = try DiagnosticStreaming.Writer(url: target, limit: 4096)
    let scan = try DiagnosticStreaming.records(from: source, byteLimit: input.count, at: time) { bytes, _ in
        try writer.append(bytes)
    }
    try writer.close()
    let lines = try Data(contentsOf: target).split(separator: 10)
    assert(scan.changed && lines.count == 3 && writer.count < 4096)
    try featureExpect(!(try writer.append(Data(repeating: 1, count: 4096))))

    let store = DiagnosticStore(root: root.appendingPathComponent("store"), now: { time }, segmentLimit: 4096)
    store.record(.launch); store.flush()
    store.record(.powerAction); store.flush() // Known valid append must preserve expiry metadata.
    time += DiagnosticStore.retention + 61
    store.flush()
    assert(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("diagnostics/events-0.jsonl").path),
           "Cached validated files outlived seven-day retention")
    store.record(.launch); store.flush()
    time -= 3600; store.flush()
    assert(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("diagnostics/events-0.jsonl").path),
           "Clock rollback bypassed future-date filtering")
    time = Date().timeIntervalSince1970; store.record(.powerAction); store.flush()
    let archive = root.appendingPathComponent("support.zip")
    try Data("previous archive".utf8).write(to: archive)
    try store.export(to: archive, permissionReady: true)
    let signature = try Data(contentsOf: archive).prefix(2)
    assert(signature == Data("PK".utf8))
    let blocked = root.appendingPathComponent("existing-directory")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    let marker = blocked.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: marker)
    do { try store.export(to: blocked, permissionReady: false); assertionFailure("Export replaced a directory") }
    catch { }
    assert(FileManager.default.fileExists(atPath: marker.path))
    assert(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("support-export").path))
    assert(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("support-report.zip").path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".NoSleep-") }
    assert(leftovers.isEmpty)
    print("PASS: 200-MB contract, chunk/record bounds, cached retention and clock rollback, atomic export and failure cleanup")
}

// Opt-in real disk-budget exercise. Fixtures are streamed too; no 50/200-MB Data allocation.
func diagnosticLargeBudgetTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoSleep-200MB-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DiagnosticStore(root: root); store.flush()
    let directory = root.appendingPathComponent("diagnostics")
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let now = Date().timeIntervalSince1970
    var logicalSize = 0
    for index in 0..<DiagnosticStore.fileCount {
        let url = directory.appendingPathComponent("events-\(index).jsonl")
        let output = try DiagnosticStreaming.Writer(url: url, limit: DiagnosticStore.fileLimit)
        var n = 0
        while output.count < DiagnosticStore.fileLimit {
            try autoreleasepool {
                let bytes = min(2048, DiagnosticStore.fileLimit - output.count)
                let item = DiagnosticRecord(at: now - Double(n % 3600), kind: .powerAction,
                                            facts: DiagnosticFacts(number: index * 100_000 + n))
                var line = try encoder.encode(item)
                assert(line.count + 1 <= bytes)
                line.append(Data(repeating: 32, count: bytes - line.count - 1)); line.append(10)
                try featureExpect(try output.append(line)); n += 1
            }
        }
        try output.close(); logicalSize += output.count
    }
    assert(logicalSize == 200_000_000)
    store.record(.powerAction, DiagnosticFacts(number: -1)); store.flush()
    for index in 1..<DiagnosticStore.fileCount {
        let url = directory.appendingPathComponent("events-\(index).jsonl")
        let handle = try FileHandle(forReadingFrom: url)
        let chunk = try handle.read(upToCount: 2048)!; try handle.close()
        let first = try JSONDecoder().decode(DiagnosticRecord.self, from: Data(chunk.split(separator: 10)[0]))
        assert(first.facts.number == (index - 1) * 100_000, "Real 50-MB boundary failed to rotate oldest file")
    }
    let archive = root.appendingPathComponent("support.zip")
    try store.export(to: archive, permissionReady: true)
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", archive.path, "events.jsonl"]; process.standardOutput = pipe
    try process.run()
    var exportedBytes = 0
    while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty { exportedBytes += chunk.count }
    process.waitUntilExit()
    assert(process.terminationStatus == 0 && exportedBytes > 1_000_000 && exportedBytes <= DiagnosticStore.logLimit)
    var total = 0
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    assert(files.count <= DiagnosticStore.fileCount)
    for file in files {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).intValue
        assert(size <= DiagnosticStore.fileLimit); total += size
    }
    assert(total <= DiagnosticStore.logLimit)
    print("PASS: seeded exact 200,000,000 bytes; real 50-MB rotation; streamed cleanup/export of \(exportedBytes) bytes; temporary files removed")
}
