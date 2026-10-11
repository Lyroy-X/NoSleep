import Foundation
import Darwin

// Never load an entire segment or exported archive into the app's memory.
enum DiagnosticStreaming {
    static let chunkLimit = 64 * 1024
    static let recordLimit = 2048

    struct Scan {
        var changed = false
        var oldest = Double.infinity
        var newest = -Double.infinity
    }

    static func records(from url: URL, byteLimit: Int, at now: Double,
                        consume: (Data, DiagnosticRecord) throws -> Bool) throws -> Scan {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var scan = Scan(), line = Data(), oversized = false, read = 0, stopped = false
        func finishLine(terminated: Bool) throws {
            defer { line.removeAll(keepingCapacity: true); oversized = false }
            guard !oversized, !line.isEmpty,
                  let record = try? decoder.decode(DiagnosticRecord.self, from: line),
                  record.at >= now - DiagnosticStore.retention, record.at <= now + 60 else {
                scan.changed = true; return
            }
            var clean = try encoder.encode(record)
            guard clean.count + 1 <= recordLimit else { scan.changed = true; return }
            if clean != line || !terminated { scan.changed = true }
            clean.append(10)
            guard try consume(clean, record) else { scan.changed = true; stopped = true; return }
            scan.oldest = min(scan.oldest, record.at); scan.newest = max(scan.newest, record.at)
        }
        while read < byteLimit && !stopped {
            let hasChunk = try autoreleasepool { () throws -> Bool in
                guard let chunk = try input.read(upToCount: min(chunkLimit, byteLimit - read)), !chunk.isEmpty else { return false }
                read += chunk.count
                var start = chunk.startIndex
                while start < chunk.endIndex && !stopped {
                    let newline = chunk[start...].firstIndex(of: 10)
                    let end = newline ?? chunk.endIndex
                    if !oversized {
                        if line.count + end - start < recordLimit { line.append(contentsOf: chunk[start..<end]) }
                        else { line.removeAll(keepingCapacity: true); oversized = true }
                    }
                    if let newline = newline {
                        // Foundation JSON temporaries must not accumulate until the queue block returns.
                        try autoreleasepool { try finishLine(terminated: true) }
                        start = newline + 1
                    } else { start = chunk.endIndex }
                }
                return true
            }
            if !hasChunk { break }
        }
        if !stopped && (!line.isEmpty || oversized) { try autoreleasepool { try finishLine(terminated: false) } }
        return scan
    }

    final class Writer {
        private let handle: FileHandle
        private let limit: Int
        private var buffer = Data()
        private(set) var count = 0
        init(url: URL, limit: Int) throws {
            self.limit = limit
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw IssueCode.storageError
            }
            handle = try FileHandle(forWritingTo: url)
        }
        deinit { try? handle.close() }
        func append(_ data: Data) throws -> Bool {
            guard data.count <= chunkLimit else { throw IssueCode.outputLimit }
            guard count + data.count <= limit else { return false }
            if buffer.count + data.count > chunkLimit { try flush() }
            buffer.append(data); count += data.count
            return true
        }
        func flush() throws {
            if !buffer.isEmpty { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        func close() throws { try flush(); try handle.close() }
    }

    // Both paths must be on the same filesystem. rename preserves the old file on failure.
    static func replace(_ destination: URL, with source: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                rename(from!, to!)
            }
        }
        guard result == 0 else { throw IssueCode.storageError }
    }
}
