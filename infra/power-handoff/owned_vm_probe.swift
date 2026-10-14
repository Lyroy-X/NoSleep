import AppKit
import Foundation
import IOKit.pwr_mgt
import CryptoKit
import Darwin

// Independent read-only process/global/assertion oracle, never a power setter.
enum ProbeFailure: Error { case refused }
let ownerMAC = "42:35:8c:14:fd:0c"
let appDomain = "local.robert.keepawake" as CFString
let preferenceKeys = ["PreventSystemSleep", "KeepDisplayAwake", "CiscoGUIRecoveryEnabled"]
func boundedCommand(_ path: String, _ arguments: [String]) throws -> String {
    let p = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
    p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    p.standardInput = FileHandle.nullDevice; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    p.terminationHandler = { _ in done.signal() }; try p.run()
    guard done.wait(timeout: .now() + 4) == .success else { p.terminate(); throw ProbeFailure.refused }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard p.terminationStatus == 0, data.count <= 8192 else { throw ProbeFailure.refused }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func guardGuest() throws {
    guard getuid() == 501,
          try boundedCommand("/usr/sbin/sysctl", ["-n", "hw.model"]).hasPrefix("VirtualMac"),
          try boundedCommand("/sbin/ifconfig", ["en0"]).contains("ether " + ownerMAC),
          try boundedCommand("/usr/bin/stat", ["-f", "%Su", "/dev/console"]) == "admin" else { throw ProbeFailure.refused }
}
func identity(_ pid: Int32) throws -> [String: Any]? {
    var info = proc_bsdinfo()
    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    if count == 0, errno == ESRCH { return nil }
    guard count == MemoryLayout<proc_bsdinfo>.size, info.pbi_uid == getuid() else { throw ProbeFailure.refused }
    if info.pbi_status == 5 { return nil }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw ProbeFailure.refused }
    let executable = String(cString: path), url = URL(fileURLWithPath: String(cString: path))
    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw ProbeFailure.refused }
    let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    return ["pid": pid, "executable": executable, "sha256": digest,
            "startSeconds": info.pbi_start_tvsec, "startMicroseconds": info.pbi_start_tvusec, "status": info.pbi_status]
}
func allNoSleepPIDs() throws -> [Int32] {
    var pids = [Int32](repeating: 0, count: 16384)
    let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
    guard size > 0, size < pids.count * MemoryLayout<Int32>.size else { throw ProbeFailure.refused }
    var result: [Int32] = []
    for pid in pids.prefix(Int(size) / MemoryLayout<Int32>.size) where pid > 1 {
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
           URL(fileURLWithPath: String(cString: path)).lastPathComponent == "NoSleep" {
            guard try identity(pid) != nil else { continue }; result.append(pid)
        }
    }
    guard result.count <= 8 else { throw ProbeFailure.refused }; return result.sorted()
}
func snapshot(_ pid: Int32) throws -> [String: Any] {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { throw ProbeFailure.refused }; defer { IOObjectRelease(root) }
    guard let global = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { throw ProbeFailure.refused }
    var raw: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
          let assertions = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { throw ProbeFailure.refused }
    let entries = assertions[NSNumber(value: pid)] ?? []
    guard entries.count <= 256 else { throw ProbeFailure.refused }
    let types = Set(entries.compactMap { item -> String? in
        guard (item[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn) else { return nil }
        return item[kIOPMAssertionTypeKey] as? String
    })
    let process: Any
    if pid == 0 { process = NSNull() }
    else if let value = try identity(pid) { process = value }
    else { process = NSNull() }
    let bridgePIDs = assertions.compactMap { pid, values -> Int32? in
        values.contains { ($0[kIOPMAssertionNameKey] as? String)?.hasPrefix("NoSleep power handoff ") == true
            && ($0[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn) } ? pid.int32Value : nil
    }.sorted()
    guard bridgePIDs.count <= 8 else { throw ProbeFailure.refused }
    return ["schema": 1, "sampledUptime": ProcessInfo.processInfo.systemUptime, "sleepDisabled": global.boolValue,
            "process": process, "idleOn": types.contains(kIOPMAssertionTypePreventUserIdleSystemSleep),
            "displayOn": types.contains(kIOPMAssertionTypePreventUserIdleDisplaySleep), "noSleepPIDs": try allNoSleepPIDs(), "bridgePIDs": bridgePIDs]
}
func preferences() throws -> [String: Any] {
    var values: [String: Any] = [:]
    for key in preferenceKeys {
        guard let value = CFPreferencesCopyAppValue(key as CFString, appDomain) else {
            values[key] = ["present": false]; continue
        }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? NSNumber else { throw ProbeFailure.refused }
        values[key] = ["present": true, "value": boolean.boolValue]
    }
    return ["schema": 1, "keys": values]
}
@main enum OwnedProbeMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--self-test"] {
                precondition(preferenceKeys == ["PreventSystemSleep", "KeepDisplayAwake", "CiscoGUIRecoveryEnabled"])
                print("PASS: independent probe self-test; no hardware/power/preferences calls"); return
            }
            try guardGuest()
            let value: [String: Any]
            if arguments == ["--preferences"] { value = try preferences() }
            else if arguments.count == 2, arguments[0] == "--snapshot", let pid = Int32(arguments[1]), pid == 0 || pid > 1 { value = try snapshot(pid) }
            else { throw ProbeFailure.refused }
            print(String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
        } catch { print("{\"probeRefused\":true,\"reason\":\"owned-read-proof-refused\"}"); exit(1) }
    }
}
