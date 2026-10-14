import AppKit
import CryptoKit
import Foundation
import Darwin

struct ProbeConfig: Decodable { let expectedHash: String; let expectedLength: Int; let mac: String }
enum ProbeError: Error { case guardFailed, invalidArguments, commandFailed }
func commandText(_ executable: String, _ args: [String]) throws -> String {
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; try p.run()
    let end = ProcessInfo.processInfo.systemUptime + 2
    while p.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
    if p.isRunning { p.terminate(); throw ProbeError.commandFailed }
    p.waitUntilExit(); guard p.terminationStatus == 0 else { throw ProbeError.commandFailed }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); guard data.count < 16384 else { throw ProbeError.commandFailed }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func ownedGuest(_ config: ProbeConfig) throws -> String {
    let model = try commandText("/usr/sbin/sysctl", ["-n", "hw.model"])
    guard model.hasPrefix("VirtualMac"), getuid() == 501,
          try commandText("/usr/bin/stat", ["-f", "%Su", "/dev/console"]) == "admin",
          config.expectedLength == 42,
          config.expectedHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ProbeError.guardFailed }
    let rows = try commandText("/sbin/ifconfig", ["en0"]).split(separator: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }) }
    let address = rows.first { $0.first == "ether" }
    guard address?.count == 2, address?[1].lowercased() == config.mac.lowercased() else { throw ProbeError.guardFailed }
    return model
}
final class InputReceiver: NSObject, NSApplicationDelegate {
    let config: ProbeConfig, root: URL
    let nonce = UUID().uuidString
    var model = "", timer: Timer?, window: NSWindow!, field = NSSecureTextField()
    var start: TimeInterval = 0, readyAt: TimeInterval?, focusWasReady = false, finished = false
    init(config: ProbeConfig, root: URL) { self.config = config; self.root = root }
    func write(_ value: [String: Any], _ name: String) {
        do { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent(name), options: .atomic) }
        catch { fputs("Probe receipt write failed\n", stderr); exit(1) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { model = try ownedGuest(config) } catch { fputs("Guest ownership refused\n", stderr); exit(1) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NoSleep — VNC input probe"; window.isReleasedWhenClosed = false; window.center()
        let title = NSTextField(labelWithString: "Тестовый ввод VNC: только вымышленные символы")
        title.frame = NSRect(x: 24, y: 120, width: 552, height: 24); title.font = .systemFont(ofSize: 15)
        field.frame = NSRect(x: 24, y: 60, width: 552, height: 36); field.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        field.placeholderString = "42 тестовых символа"; field.setAccessibilityLabel("Synthetic VNC input")
        window.contentView!.addSubview(title); window.contentView!.addSubview(field)
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); window.makeFirstResponder(field)
        start = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
    }
    func poll() {
        guard !finished else { return }
        let app = NSApplication.shared, now = ProcessInfo.processInfo.systemUptime
        let focused = app.isActive && app.keyWindow === window && window.isKeyWindow && field.currentEditor() != nil
        if readyAt == nil {
            if focused {
                do { model = try ownedGuest(config) } catch { finish(reason: "ownershipChanged", input: ""); return }
                readyAt = now; focusWasReady = true
                write(["nonce": nonce, "receiverPID": getpid(), "model": model, "mac": config.mac, "appActive": app.isActive,
                       "keyWindow": window.isKeyWindow, "fieldFocused": true, "expectedSHA256": config.expectedHash, "expectedLength": config.expectedLength,
                       "bundle": Bundle.main.bundleIdentifier ?? "", "binary": Bundle.main.executableURL?.path ?? "", "windowID": window.windowNumber], "ready.json")
            } else if now - start >= 5 { finish(reason: "focusUnavailable", input: "") }
            return
        }
        guard focused else { finish(reason: "focusLost", input: field.stringValue); return }
        let input = field.currentEditor()?.string ?? field.stringValue
        guard input.utf8.count <= 512 else { finish(reason: "inputTooLong", input: ""); return }
        let hash = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        if input.utf8.count == config.expectedLength && hash == config.expectedHash { finish(reason: "matched", input: input); return }
        let done = root.appendingPathComponent("input-finished")
        if let date = (try? FileManager.default.attributesOfItem(atPath: done.path))?[.modificationDate] as? Date, Date().timeIntervalSince(date) >= 0.8 {
            finish(reason: "completedMismatch", input: input)
        } else if now - readyAt! >= 30 { finish(reason: "inputTimeout", input: input) }
    }
    func finish(reason: String, input: String) {
        finished = true; timer?.invalidate()
        let hash = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        let matches = input.utf8.count == config.expectedLength && hash == config.expectedHash
        field.stringValue = ""; field.currentEditor()?.string = ""; window?.close()
        write(["result": matches ? "passed" : "failed", "reason": reason, "nonce": nonce, "receiverPID": getpid(), "guestGuarded": true,
               "focusWasReady": focusWasReady, "expectedSHA256": config.expectedHash, "expectedLength": config.expectedLength,
               "observedSHA256": hash, "observedLength": input.utf8.count, "matches": matches,
               "inputPrinted": false, "clipboardUsed": false, "ownFieldCleared": true, "scope": "own synthetic VNC input field only; no Cisco/host input or credential operations"], "receipt.json")
        fflush(stdout); exit(matches ? 0 : 1)
    }
}
@main enum ProbeMain {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { throw ProbeError.invalidArguments }
            let root = URL(fileURLWithPath: CommandLine.arguments[1]), configURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let config = try JSONDecoder().decode(ProbeConfig.self, from: Data(contentsOf: configURL))
            _ = try ownedGuest(config) // Before creating an AppKit instance/window.
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let app = NSApplication.shared; app.setActivationPolicy(.regular)
            let receiver = InputReceiver(config: config, root: root); app.delegate = receiver; app.run()
        } catch { fputs("VNC input probe refused: \(error)\n", stderr); fflush(stderr); exit(1) }
    }
}
