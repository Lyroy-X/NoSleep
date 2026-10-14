import AppKit
import ApplicationServices
import Foundation
import Security

// Deliberately destructive race test, ONLY in the disposable, identity-bound
// guest. This is separate from the read-only inspector and production NoSleep.
// It retains a Ready Connect element, then presses it after real Connected.
// Host-side session/data oracles decide safety; an AX reply alone proves nothing.
func processOutput(_ path: String, _ arguments: [String], timeout: Double = 8) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let lock = NSLock(); var data = Data(), oversized = false; let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var received = Data(), exceeded = false
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            if received.count + chunk.count > 65536 { exceeded = true; process.terminate(); break }
            received.append(chunk)
        }
        lock.lock(); data = received; oversized = exceeded; lock.unlock(); finished.signal()
    }
    if finished.wait(timeout: .now() + timeout) != .success {
        process.terminate(); throw NSError(domain: "OwnedGuestProbeDeadline", code: 1)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "OwnedGuestProbeCommand", code: 2) }
    lock.lock(); defer { lock.unlock() }
    guard !oversized else { throw NSError(domain: "OwnedGuestProbeOutputLimit", code: 8) }
    return String(data: data, encoding: .utf8) ?? ""
}
let arguments = CommandLine.arguments
guard arguments.count == 5, ["menu", "button"].contains(arguments[2]),
      arguments[1].range(of: "^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil,
      let duration = Double(arguments[3]), duration > 0, duration <= 300 else { exit(64) }
let expectedMAC = arguments[1], mode = arguments[2]
let destination = URL(fileURLWithPath: arguments[4]).standardizedFileURL
guard destination.path.hasPrefix("/Users/admin/NoSleepLab/"), !destination.path.contains("..") else { exit(65) }
func identityGuard() throws {
    guard try processOutput("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("VirtualMac"),
          getuid() == 501,
          try processOutput("/usr/bin/stat", ["-f", "%Su", "/dev/console"]).trimmingCharacters(in: .whitespacesAndNewlines) == "admin",
          try processOutput("/sbin/ifconfig", ["en0"]).split(separator: "\n").contains(where: {
              $0.trimmingCharacters(in: .whitespaces).hasPrefix("ether " + expectedMAC)
          }) else { throw NSError(domain: "OwnedGuestIdentity", code: 3) }
    let profile = URL(fileURLWithPath: "/opt/cisco/secureclient/vpn/profile/NoSleepLab.xml")
    let checksum = try processOutput("/usr/bin/shasum", ["-a", "256", profile.path]).split(separator: " ").first
    guard checksum == "4a27e4cd06a236054b0fc0246d32919b1978f210db6cf11dd9b025ec34930834" else {
        throw NSError(domain: "OwnedGuestProfile", code: 4)
    }
}
// Before AppKit, permission prompts, output or any AX call. Refuse quietly;
// no fatal-error crash report is created by an accidental host invocation.
do { try identityGuard() } catch { exit(66) }
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
let outputURL = destination.appendingPathComponent("events.jsonl")
FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
let output = try FileHandle(forWritingTo: outputURL)
var outputBytes = 0
func emit(_ object: [String: Any]) {
    guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
          outputBytes + bytes.count < 65536 else { return }
    try? output.write(contentsOf: bytes + Data([10])); outputBytes += bytes.count + 1
}
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func text(_ element: AXUIElement, _ key: String) -> String {
    return String(((attribute(element, key) as? String) ?? "").prefix(100))
}
func element(_ node: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attribute(node, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func signedCisco(_ url: URL) -> Bool {
    var code: SecStaticCode?, requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"DE8Y96K9QP\"" as CFString,
                                         [], &requirement) == errSecSuccess, let requirement else { return false }
    return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
}
func currentCisco() throws -> NSRunningApplication {
    guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cisco.secureclient.gui").first,
          let url = application.bundleURL,
          url.resolvingSymlinksInPath().path == "/Applications/Cisco/Cisco Secure Client.app",
          signedCisco(url) else { throw NSError(domain: "OwnedGuestSignedCisco", code: 5) }
    return application
}
func nativeState() throws -> String {
    let cli = URL(fileURLWithPath: "/opt/cisco/secureclient/bin/vpn").resolvingSymlinksInPath()
    guard signedCisco(cli) else { throw NSError(domain: "OwnedGuestSignedCLI", code: 6) }
    let text = try processOutput(cli.path, ["-s", "state"])
    let states = text.components(separatedBy: .newlines).compactMap { line -> String? in
        guard let range = line.range(of: "state: ") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let recognized = ["Disconnected", "Connected", "Connecting", "Reconnecting"]
    guard let last = states.last, recognized.contains(last) else { return "unknown" }
    return last.lowercased()
}
struct Controls { var buttons: [AXUIElement] = []; var menus: [AXUIElement] = []; var labTargetMatches = false }
func controls(_ application: NSRunningApplication) -> Controls {
    let root = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.2)
    var pending: [(AXUIElement, Int)] = [(root, 0)]
    for key in [kAXMenuBarAttribute, kAXExtrasMenuBarAttribute] {
        if let menu = element(root, key) { pending.append((menu, 0)) }
    }
    var result = Controls(), seen = 0
    let deadline = Date().addingTimeInterval(3)
    while !pending.isEmpty, seen < 220, Date() < deadline {
        let (node, depth) = pending.removeLast(); seen += 1
        let role = text(node, kAXRoleAttribute), title = text(node, kAXTitleAttribute)
        if role == kAXComboBoxRole, let window = element(node, kAXWindowAttribute),
           text(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
           ["NoSleep Lab", "vpn-lab.invalid:4443"].contains(text(node, kAXValueAttribute)) {
            result.labTargetMatches = true // Never reads an auth text field.
        }
        if role == kAXButtonRole, ["Connect", "Disconnect"].contains(title),
           text(node, kAXIdentifierAttribute) == "_NS:25" { result.buttons.append(node) }
        if role == kAXMenuItemRole, ["Connect", "Disconnect"].contains(title),
           text(node, kAXIdentifierAttribute) == "handleControlAction:" { result.menus.append(node) }
        if depth < 12 {
            let key = role == kAXApplicationRole ? kAXWindowsAttribute : kAXChildrenAttribute
            if let children = attribute(node, key) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(100).map { ($0, depth + 1) })
            }
        }
    }
    return result
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
let end = Date().addingTimeInterval(duration)
var held: AXUIElement?, heldPID: pid_t = 0, previous = "", didPress = false
let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    if Date() >= end { emit(["phase": "finished", "didPress": didPress]); try? output.close(); exit(0) }
    do {
        try identityGuard()
        guard AXIsProcessTrusted() else {
            if previous != "permission" { emit(["phase": "accessibility-required"]); previous = "permission" }
            return
        }
        let application = try currentCisco(), state = try nativeState()
        if held == nil {
            guard state == "disconnected" else {
                if previous != "wait-ready" { emit(["phase": "waiting-for-ready", "native": state]); previous = "wait-ready" }
                return
            }
            let view = controls(application)
            let candidates = mode == "menu" ? view.menus : view.buttons
            guard view.labTargetMatches, candidates.count == 1,
                  text(candidates[0], kAXTitleAttribute) == "Connect",
                  attribute(candidates[0], kAXEnabledAttribute) as? Bool == true else { return }
            var actionNames: CFArray?
            guard AXUIElementCopyActionNames(candidates[0], &actionNames) == .success,
                  (actionNames as? [String] ?? []).contains(kAXPressAction) else { return }
            held = candidates[0]; heldPID = application.processIdentifier
            emit(["phase": "ready-reference-retained", "mode": mode, "ciscoPID": heldPID,
                  "hash": CFHash(candidates[0]), "caption": "Connect", "labTargetMatches": true,
                  "signedCisco": true, "modelAndMACGuard": true]); previous = "retained"
            return
        }
        let marker = destination.appendingPathComponent("press-now.json")
        guard !didPress, FileManager.default.fileExists(atPath: marker.path), state == "connected",
              heldPID == application.processIdentifier, let held else { return }
        let bytes = try Data(contentsOf: marker)
        guard bytes.count <= 4096, let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              request["ciscoPID"] as? Int == Int(heldPID), request["serverSessionAndDataVerified"] as? Bool == true,
              request["mainVPNModified"] as? Bool == false else { throw NSError(domain: "OwnedGuestActionMarker", code: 7) }
        try identityGuard()
        let current = try currentCisco()
        guard current.processIdentifier == heldPID, try nativeState() == "connected" else { return }
        let view = controls(current), candidates = mode == "menu" ? view.menus : view.buttons
        let same = candidates.contains { CFEqual($0, held) }
        let caption = text(held, kAXTitleAttribute)
        // INTENTIONAL stale action in the disposable VM. A Connected veto here
        // would conceal the race rather than test the retained control's meaning.
        didPress = true
        let reply = AXUIElementPerformAction(held, kAXPressAction as CFString)
        emit(["phase": "stale-connected-reference-pressed", "mode": mode,
              "ciscoPID": heldPID, "captionAtPress": caption,
              "sameElementAsCurrentControl": same, "AXReply": reply.rawValue,
              "guestOnlyDestructiveRaceTest": true, "nativeBefore": "connected",
              "secretReads": 0, "mainVPNModified": false])
        try? output.close(); exit(0)
    } catch {
        emit(["phase": "guard-or-read-failed", "errorDomain": (error as NSError).domain,
              "errorCode": (error as NSError).code, "didPress": didPress])
        try? output.close(); exit(1)
    }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
