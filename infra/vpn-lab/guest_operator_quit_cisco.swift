import AppKit
import Foundation
import Security

// Explicit operator preparation for a disposable single-frontend test.
// Never called by NoSleep automation. No force termination or service work.
func read(_ executable: String, _ arguments: [String]) -> String? {
    let task = Process(), output = Pipe()
    task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
    task.standardInput = FileHandle.nullDevice; task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(3)
    while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    guard !task.isRunning else { task.terminate(); return nil }
    guard task.terminationStatus == 0,
          let data = try? output.fileHandleForReading.readToEnd(), data.count <= 4096 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

guard CommandLine.arguments == [CommandLine.arguments[0], "--operator-explicit-quit-owned-lab-gui"],
      read("/usr/sbin/sysctl", ["-n", "hw.model"])?.hasPrefix("VirtualMac") == true,
      getuid() == 501, read("/usr/bin/stat", ["-f", "%Su", "/dev/console"]) == "admin",
      read("/sbin/ifconfig", ["en0"])?.contains("ether 42:35:8c:14:fd:0c") == true,
      read("/usr/bin/shasum", ["-a", "256", "/opt/cisco/secureclient/vpn/profile/NoSleepLab.xml"])?
        .hasPrefix("4a27e4cd06a236054b0fc0246d32919b1978f210db6cf11dd9b025ec34930834 ") == true else { exit(64) }

let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cisco.secureclient.gui")
guard applications.count <= 1 else { exit(65) }
if applications.isEmpty { print("{\"operatorRequest\":\"already-absent\",\"mainVPNModified\":false}"); exit(0) }
let application = applications[0]
guard let url = application.bundleURL,
      url.resolvingSymlinksInPath().path == "/Applications/Cisco/Cisco Secure Client.app",
      Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String == "5.1.12.146" else { exit(66) }
var code: SecCode?, requirement: SecRequirement?
guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: application.processIdentifier] as CFDictionary, [], &code) == errSecSuccess,
      SecRequirementCreateWithString("anchor apple generic and identifier \"com.cisco.secureclient.gui\" and certificate leaf[subject.OU] = \"DE8Y96K9QP\"" as CFString, [], &requirement) == errSecSuccess,
      let code, let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { exit(67) }
guard application.terminate() else { print("{\"operatorRequest\":\"quit-refused\",\"forced\":false}"); exit(68) }
let deadline = Date().addingTimeInterval(8)
while !application.isTerminated && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
print("{\"operatorRequest\":\"ordinary-quit\",\"terminated\":\(application.isTerminated),\"forced\":false,\"serviceActions\":0,\"mainVPNModified\":false}")
exit(application.isTerminated ? 0 : 69)
