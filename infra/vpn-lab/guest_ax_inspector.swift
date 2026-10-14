import AppKit
import ApplicationServices
import Foundation
import Security

// Read-only, lab-guest-only inspector. No AXPress, input AXValue reads, password,
// Keychain, VPN command or host UI action exists in this tool.
func localRead(_ path: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "LabIdentity", code: 1) }
    return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
}
let args = CommandLine.arguments
guard args.count == 4, args[1].range(of: "^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil,
      let seconds = Double(args[2]), seconds > 0, seconds <= 300 else { exit(64) }
let model = try localRead("/usr/sbin/sysctl", ["-n", "hw.model"])
guard model.hasPrefix("VirtualMac") else { exit(65) }
let interface = try localRead("/sbin/ifconfig", ["en0"])
guard interface.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ether " + args[1]) }) else { exit(66) }
let outputURL = URL(fileURLWithPath: args[3]).standardizedFileURL
guard outputURL.path.hasPrefix("/Users/admin/NoSleepLab/"), !outputURL.path.contains("..") else { exit(67) }
FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
let output = try FileHandle(forWritingTo: outputURL)
var outputBytes = 0
func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), outputBytes + data.count < 524288 else { return }
    try? output.write(contentsOf: data + Data([10]))
    outputBytes += data.count + 1
}
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func text(_ element: AXUIElement, _ key: String) -> String {
    (attribute(element, key) as? String).map { String($0.prefix(100)) } ?? ""
}
func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func labelInfo(_ element: AXUIElement) -> [String: Any] {
    let role = text(element, kAXRoleAttribute)
    var result: [String: Any] = ["role": role, "title": text(element, kAXTitleAttribute),
                                 "description": text(element, kAXDescriptionAttribute),
                                 "identifier": text(element, kAXIdentifierAttribute)]
    // Static prompt/label text only. Text-field/secure-field values never enter
    // the probe; this is not a way to inspect what was typed in a password.
    if role == kAXStaticTextRole, text(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole {
        result["staticLabel"] = text(element, kAXValueAttribute)
    }
    return result
}
func windowInfo(_ element: AXUIElement) -> [String: Any] {
    guard let window = elementAttribute(element, kAXWindowAttribute) else { return [:] }
    return ["role": text(window, kAXRoleAttribute), "subrole": text(window, kAXSubroleAttribute),
            "title": text(window, kAXTitleAttribute), "identifier": text(window, kAXIdentifierAttribute),
            "hash": CFHash(window)]
}
func signatureOK(_ url: URL) -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"DE8Y96K9QP\"" as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }
    return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(prompt)
let end = Date().addingTimeInterval(seconds)
var baselineConnect: AXUIElement?
var baselinePID: pid_t = 0
var previous = ""
let timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
    if Date() >= end {
        emit(["phase": "finished", "bytes": outputBytes])
        try? output.close()
        exit(0)
    }
    guard AXIsProcessTrusted() else {
        if previous != "permission" { emit(["phase": "accessibility-required"]); previous = "permission" }
        return
    }
    guard let cisco = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cisco.secureclient.gui").first,
          let url = cisco.bundleURL, url.resolvingSymlinksInPath().path == "/Applications/Cisco/Cisco Secure Client.app",
          signatureOK(url) else {
        if previous != "missing" { emit(["phase": "signed-cisco-not-running"]); previous = "missing" }
        return
    }
    let root = AXUIElementCreateApplication(cisco.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.25)
    var pending: [(AXUIElement, Int)] = [(root, 0)]
    if let menu = attribute(root, kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() {
        pending.append((unsafeBitCast(menu, to: AXUIElement.self), 0))
    }
    if let menu = elementAttribute(root, kAXExtrasMenuBarAttribute) { pending.append((menu, 0)) }
    var buttons: [[String: Any]] = []
    var fields: [[String: Any]] = []
    var labels: [[String: Any]] = []
    var seen = 0
    let deadline = Date().addingTimeInterval(4)
    while !pending.isEmpty, seen < 240, Date() < deadline {
        let (element, depth) = pending.removeLast()
        seen += 1
        let role = text(element, kAXRoleAttribute)
        if role == kAXButtonRole || role == kAXMenuItemRole || role == kAXMenuBarItemRole {
            let title = text(element, kAXTitleAttribute)
            let description = text(element, kAXDescriptionAttribute)
            let caption = (title.isEmpty ? description : title).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            var actions: CFArray?
            _ = AXUIElementCopyActionNames(element, &actions)
            var record: [String: Any] = ["title": title, "description": description,
                                         "identifier": text(element, kAXIdentifierAttribute),
                                         "role": role, "hash": CFHash(element),
                                         "enabled": attribute(element, kAXEnabledAttribute) as? Bool ?? false,
                                         "actions": (actions as? [String] ?? []).prefix(8).map { String($0.prefix(40)) }]
            record["window"] = windowInfo(element)
            if ["connect", "подключение", "подключить"].contains(caption), role == kAXButtonRole {
                if baselineConnect == nil || baselinePID != cisco.processIdentifier {
                    baselineConnect = element
                    baselinePID = cisco.processIdentifier
                }
                record["nativeAction"] = "connect"
            } else if ["disconnect", "отключить", "отключение"].contains(caption), role == kAXButtonRole {
                record["nativeAction"] = "disconnect"
                if let original = baselineConnect, baselinePID == cisco.processIdentifier {
                    record["sameElementAsReadyConnect"] = CFEqual(original, element)
                }
            } else if ["connect", "подключение", "подключить"].contains(caption) {
                record["nativeAction"] = "connect_menu"
            } else if ["disconnect", "отключить", "отключение"].contains(caption) {
                record["nativeAction"] = "disconnect_menu"
            }
            buttons.append(record)
        }
        if role == kAXTextFieldRole || role == kAXComboBoxRole || role == kAXPopUpButtonRole {
            var field: [String: Any] = ["role": role, "subrole": text(element, kAXSubroleAttribute),
                                       "title": text(element, kAXTitleAttribute),
                                       "description": text(element, kAXDescriptionAttribute),
                                       "identifier": text(element, kAXIdentifierAttribute),
                                       "window": windowInfo(element),
                                       "enabled": attribute(element, kAXEnabledAttribute) as? Bool ?? false]
            var supported: CFArray?
            _ = AXUIElementCopyAttributeNames(element, &supported)
            field["supportedAttributeNames"] = (supported as? [String] ?? []).prefix(48).map { String($0.prefix(60)) }
            var settable = DarwinBoolean(false)
            let settableReply = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            field["valueSettable"] = settableReply == .success && settable.boolValue
            field["valueSettableReply"] = settableReply.rawValue
            if text(element,kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
                var parameterized: CFArray?
                let namesReply = AXUIElementCopyParameterizedAttributeNames(element, &parameterized)
                field["parameterizedNamesReply"] = namesReply.rawValue
                field["supportedParameterizedAttributeNames"] = (parameterized as? [String] ?? []).prefix(32).map { String($0.prefix(60)) }
                // Public range metadata only, scoped to the synthetic guest
                // dialog. Never AXValue/StringForRange/SelectedText or length.
                if (windowInfo(element)["title"] as? String) == "Cisco Secure Client | NoSleep Lab" {
                    var fullLine: CFTypeRef?
                    let reply = AXUIElementCopyParameterizedAttributeValue(element,
                        kAXRangeForLineParameterizedAttribute as CFString, NSNumber(value: 0), &fullLine)
                    field["fullLineRangeReply"] = reply.rawValue
                    if reply == .success, let fullLine, CFGetTypeID(fullLine) == AXValueGetTypeID() {
                        let value = unsafeBitCast(fullLine, to: AXValue.self)
                        var range = CFRange(location: 0, length: 0)
                        if AXValueGetType(value) == .cfRange && AXValueGetValue(value, .cfRange, &range), range.location == 0, range.length >= 0 {
                            field["syntheticLabSecureFieldEmptyByFullLineRange"] = range.length == 0
                        }
                    }
                }
            }
            if text(element,kAXSubroleAttribute) == kAXSecureTextFieldSubrole,
               (windowInfo(element)["title"] as? String) == "Cisco Secure Client | NoSleep Lab",
               let count = attribute(element,"AXNumberOfCharacters") as? NSNumber {
                field["syntheticLabSecureFieldEmpty"] = count.intValue == 0
            }
            if let label = elementAttribute(element, kAXTitleUIElementAttribute) { field["titleUIElement"] = labelInfo(label) }
            if role == kAXPopUpButtonRole {
                let selected = text(element, kAXValueAttribute)
                field["selectedMatchesDummyLabGroup"] = ["lab", "NoSleep Lab"].contains(selected)
            }
            fields.append(field)
        }
        if role == kAXStaticTextRole { labels.append(labelInfo(element).merging(["window": windowInfo(element)]) { old, _ in old }) }
        // Secure/ordinary text values are never queried. Children are enough
        // to discover the native action schema without exposing credentials.
        if depth < 12 {
            let key = role == kAXApplicationRole ? kAXWindowsAttribute : kAXChildrenAttribute
            if let children = attribute(element, key) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(120).map { ($0, depth + 1) })
            }
        }
    }
    // App/system menu items can otherwise consume the bounded output before
    // the main native Connect/Disconnect controls are reached.
    let orderedButtons = buttons.filter { ($0["role"] as? String) == kAXButtonRole }
        + buttons.filter { ($0["role"] as? String) != kAXButtonRole && $0["nativeAction"] != nil }
        + buttons.filter { ($0["role"] as? String) != kAXButtonRole && $0["nativeAction"] == nil }
    let value: [String: Any] = ["phase": "snapshot", "pid": cisco.processIdentifier,
                                "nodeCount": seen, "buttons": orderedButtons.prefix(40).map { $0 },
                                "fields": fields.prefix(12).map { $0 }, "staticLabels": labels.prefix(24).map { $0 }]
    let serialized = String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    if serialized != previous { emit(value); previous = serialized }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
