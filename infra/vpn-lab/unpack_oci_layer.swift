import Compression
import CryptoKit
import Foundation

// A single Tart disk.v2 layer is an independently compressed Apple LZ4
// stream. This tool uses public Compression APIs and bounded buffers. It
// writes only the caller's owned temporary disk and checks size and SHA-256.
guard CommandLine.arguments.count == 6 else { exit(64) }
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
let ownedDirectory = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("oci").resolvingSymlinksInPath()
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
let diskURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
guard inputURL.path.hasPrefix(ownedDirectory.path + "/"),
      diskURL.path.hasPrefix(ownedDirectory.path + "/"), diskURL.lastPathComponent == "disk.img",
      let offset = UInt64(CommandLine.arguments[3]),
      let expected = UInt64(CommandLine.arguments[4]), expected > 0,
      expected <= 536870912, offset <= 68719476736,
      expected <= 68719476736 - offset else { exit(65) }
let expectedHash = CommandLine.arguments[5]
do {
    let input = try FileHandle(forReadingFrom: inputURL)
    let disk = try FileHandle(forWritingTo: diskURL)
    defer { try? input.close(); try? disk.close() }
    var written: UInt64 = 0
    var digest = SHA256()
    try disk.seek(toOffset: offset)
    let filter = try OutputFilter(.decompress, using: .lz4, bufferCapacity: 4 * 1024 * 1024) { bytes in
        guard let bytes else { return }
        guard written + UInt64(bytes.count) <= expected else {
            throw NSError(domain: "NoSleepLab", code: 1)
        }
        digest.update(data: bytes)
        try disk.write(contentsOf: bytes)
        written += UInt64(bytes.count)
    }
    while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty {
        try filter.write(bytes)
    }
    try filter.finalize()
    let actualHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    guard written == expected, actualHash == expectedHash else {
        throw NSError(domain: "NoSleepLab", code: 2)
    }
    try disk.synchronize()
    print("verified")
} catch {
    // Do not print content, redirect URLs or unknown error userInfo.
    let error = error as NSError
    fputs("Layer verification failed: \(error.domain) \(error.code)\n", stderr)
    exit(1)
}
