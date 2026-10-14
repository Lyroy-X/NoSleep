import Foundation
import CryptoKit
import Darwin

// This portable controller only launches its hash-verified UI fixture. It has no
// dependency on Python, swiftc, the production app, Cisco, Keychain or AX writes.
enum HarnessRunnerError: Error, CustomStringConvertible {
    case failure(String)
    var description: String { switch self { case .failure(let message): return message } }
}

@main enum StandaloneUIRunner {
    static let fm = FileManager.default
    static let limitations = ["real power/watchdog", "real Cisco reconnect/authentication/client opening", "real Keychain", "real macOS permission grant", "actual keyboard Cmd-V using general clipboard"]

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw HarnessRunnerError.failure(message) }
    }
    static func hash(_ path: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
    }
    static func json(_ path: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: path)
        try require(data.count <= 2 * 1024 * 1024, "Fixture JSON exceeds the bounded size")
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessRunnerError.failure("Invalid fixture JSON: \(path.lastPathComponent)")
        }
        return value
    }
    static func write(_ value: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
    }
    @discardableResult static func command(_ executable: String, _ args: [String], timeout: TimeInterval = 10, stdout: URL? = nil, stderr: URL? = nil, allowFailure: Bool = false) throws -> Int32 {
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = args
        var handles: [FileHandle] = []
        for (path, errorStream) in [(stdout, false), (stderr, true)] {
            if let path = path {
                fm.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let handle = try FileHandle(forWritingTo: path); handles.append(handle)
                if errorStream { child.standardError = handle } else { child.standardOutput = handle }
            } else if allowFailure {
                if errorStream { child.standardError = FileHandle.nullDevice } else { child.standardOutput = FileHandle.nullDevice }
            }
        }
        defer { for handle in handles { try? handle.close() } }
        try child.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.03) }
        if child.isRunning { child.terminate(); throw HarnessRunnerError.failure("Timed out: \(URL(fileURLWithPath: executable).lastPathComponent)") }
        child.waitUntilExit()
        try require(allowFailure || child.terminationStatus == 0, "Command failed (\(child.terminationStatus)): \(URL(fileURLWithPath: executable).lastPathComponent)")
        return child.terminationStatus
    }
    static func ownPID(_ run: URL, bundle: String) throws -> Int32? {
        let path = run.appendingPathComponent("process.json")
        guard fm.fileExists(atPath: path.path) else { return nil }
        let marker = try json(path)
        try require(marker["bundle"] as? String == bundle, "Unexpected fixture process identity")
        guard let pid = marker["pid"] as? Int32, pid > 1 else { throw HarnessRunnerError.failure("Invalid fixture PID") }
        return pid
    }
    static func waitFor(_ name: String, run: URL, bundle: String, timeout: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !fm.fileExists(atPath: run.appendingPathComponent(name).path) {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out waiting for \(name); inspect runtime.log/runtime.err")
            if let pid = try ownPID(run, bundle: bundle) {
                try require(kill(pid, 0) == 0 || errno == EPERM, "Fixture exited before completing checks; inspect runtime.log/runtime.err")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    static func cleanup(_ run: URL, bundle: String, binary: URL, defaults: String) {
        if let pid = try? ownPID(run, bundle: bundle) {
            let report = run.appendingPathComponent("process-cleanup.txt")
            if (try? command("/bin/ps", ["-p", String(pid), "-o", "comm="], timeout: 3, stdout: report, allowFailure: true)) == 0,
               let actual = try? String(contentsOf: report, encoding: .utf8), actual.trimmingCharacters(in: .whitespacesAndNewlines) == binary.path {
                // Never signal a recycled PID or search for another application.
                _ = kill(pid, SIGTERM)
            }
        }
        _ = try? command("/usr/bin/defaults", ["delete", defaults], timeout: 3, allowFailure: true)
    }
    static func requireOwnedGuestBeforeLaunch(mac: String, run: URL) throws {
        let expected = mac.lowercased()
        try require(expected.range(of: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", options: .regularExpression) != nil, "Invalid owned guest MAC")
        let model = run.appendingPathComponent("guest-model.txt")
        try command("/usr/sbin/sysctl", ["-n", "hw.model"], timeout: 2, stdout: model)
        try require(try String(contentsOf: model, encoding: .utf8).hasPrefix("VirtualMac") && getuid() == 501, "Guest clipboard mode cannot launch on a physical host")
        let console = run.appendingPathComponent("guest-console.txt")
        try command("/usr/bin/stat", ["-f", "%Su", "/dev/console"], timeout: 2, stdout: console)
        try require(try String(contentsOf: console, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "admin", "Owned guest console is not active")
        let interface = run.appendingPathComponent("guest-interface.txt")
        try command("/sbin/ifconfig", ["en0"], timeout: 2, stdout: interface)
        let rows = try String(contentsOf: interface, encoding: .utf8).split(separator: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }) }
        let actual = rows.first { $0.first == "ether" }
        try require(actual?.count == 2 && actual?[1].lowercased() == expected, "MAC does not identify the owned guest")
    }
    static func main() {
        do { exit(try run()) }
        catch { fputs("FAIL: \(error)\n", stderr); fflush(stderr); exit(1) }
    }
    static func run() throws -> Int32 {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        var fixture = executable.deletingLastPathComponent().appendingPathComponent("NoSleepUIPreview.app")
        var base = executable.deletingLastPathComponent().appendingPathComponent("results")
        var screenshots = true, presentationOnly = false, renderOnly = false, renderCLIOnly = false, guestPaste = false
        var guestMAC: String?
        var index = 1
        while index < CommandLine.arguments.count {
            switch CommandLine.arguments[index] {
            case "--fixture", "--output":
                try require(index + 1 < CommandLine.arguments.count, "Missing path argument")
                let path = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
                if CommandLine.arguments[index] == "--fixture" { fixture = path } else { base = path }
                index += 1
            case "--no-screenshots": screenshots = false
            case "--presentation-only": presentationOnly = true
            case "--render-only": renderOnly = true
            case "--render-cli-only": renderCLIOnly = true
            case "--guest-cmd-v": guestPaste = true
            case "--guest-mac":
                try require(index + 1 < CommandLine.arguments.count, "Missing owned guest MAC")
                guestMAC = CommandLine.arguments[index + 1]; index += 1
            case "--help":
                print("ui-acceptance-runner [--fixture NoSleepUIPreview.app] [--output results] [--no-screenshots] [--presentation-only | --render-only | --render-cli-only | --guest-cmd-v --guest-mac OWNED_MAC]"); return 0
            default: throw HarnessRunnerError.failure("Unknown argument")
            }
            index += 1
        }
        try require([presentationOnly, renderOnly, renderCLIOnly, guestPaste].filter { $0 }.count <= 1, "Choose only one standalone mode")
        try require(!guestPaste || guestMAC != nil, "Guest clipboard mode requires an exact owned VM MAC and disabled clipboard sync")
        try require(!base.pathComponents.contains(where: { $0.hasSuffix(".app") }), "Output cannot be inside an app bundle")
        let package = fixture.deletingLastPathComponent()
        let manifest = try json(package.appendingPathComponent("fixture-manifest.json"))
        guard let bundle = manifest["bundle"] as? String else { throw HarnessRunnerError.failure("Fixture bundle identity missing") }
        try require(manifest["schema"] as? Int == 1 && manifest["fixtureRole"] as? String == "isolated-current-appkit-ui" && manifest["normalAppEntrypointExcluded"] as? Bool == true,
                    "Only an isolated UI fixture can be launched")
        try require(manifest["forbiddenRuntimeImportsAbsent"] as? Bool == true && bundle.hasPrefix("local.nosleep.ui-harness."), "Fixture side-effect audit or unique identity missing")
        let binary = fixture.appendingPathComponent("Contents/MacOS/ui-harness")
        try require(try hash(binary) == manifest["fixtureExecutableHash"] as? String, "Fixture executable differs from its manifest")
        try require(try hash(executable) == manifest["runnerExecutableHash"] as? String, "Portable runner differs from its manifest")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        try require(info?["CFBundleIdentifier"] as? String == bundle && info?["CFBundleExecutable"] as? String == "ui-harness", "Fixture bundle metadata differs from its manifest")
        try require(try hash(fixture.appendingPathComponent("Contents/Info.plist")) == manifest["fixtureInfoHash"] as? String, "Fixture Info.plist differs from its manifest")
        let run = base.appendingPathComponent("run-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
        try fm.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaults = bundle + ".preferences." + UUID().uuidString.lowercased()
        var receipt: [String: Any] = ["result": "failed", "scope": renderCLIOnly ? "current native CLI layouts/group action only; own fixture windows and synthetic backend stubs" : renderOnly ? "native own NSView rendering only; no windows shown or focus/paste/flow acceptance" : presentationOnly ? "pure UI presentation only; no windows or AppKit lifecycle" : "isolated current AppKit UI; test backend stubs only",
            "bundle": bundle, "defaultsDomain": defaults, "sourceHashes": manifest["sourceHashes"] ?? [:], "fixtureHashes": manifest["fixtureHashes"] ?? [:],
            "fixtureExecutableHash": manifest["fixtureExecutableHash"] ?? "", "runnerExecutableHash": manifest["runnerExecutableHash"] ?? "", "fixtureManifestVerified": true,
            "normalAppEntrypointExcluded": true, "notTested": limitations, "hostOS": ProcessInfo.processInfo.operatingSystemVersionString]
        var activated = false
        defer {
            if activated { cleanup(run, bundle: bundle, binary: binary, defaults: defaults); receipt["temporaryDefaultsCleanupAttempted"] = true }
            try? write(receipt, to: run.appendingPathComponent("receipt.json"))
            print("Evidence: \(run.path)")
        }
        do {
            if guestPaste {
                try requireOwnedGuestBeforeLaunch(mac: guestMAC!, run: run)
                activated = true
                try command("/usr/bin/open", ["-n", "--stdout", run.appendingPathComponent("runtime.log").path, "--stderr", run.appendingPathComponent("runtime.err").path, fixture.path,
                                              "--args", run.path, defaults, "--guest-cmd-v", "--guest-mac", guestMAC!])
                try waitFor("guest-paste-receipt.json", run: run, bundle: bundle, timeout: 12)
                let paste = try json(run.appendingPathComponent("guest-paste-receipt.json"))
                try require(paste["result"] as? String == "passed" && paste["guestOwnershipVerified"] as? Bool == true && paste["osGlobalKeyboardEventInjected"] as? Bool == false, "Guest key-equivalent evidence missing")
                receipt.merge(paste) { _, new in new }; receipt["nativeUIExecuted"] = true
                receipt["notTested"] = limitations.filter { $0 != "actual keyboard Cmd-V using general clipboard" } + ["physical/OS-global keyboard Cmd-V injection", "host general clipboard"]
                print("PASS: owned guest Cmd-V key equivalent/general dummy clipboard; no OS-global key injection")
                return 0
            }
            if renderOnly || renderCLIOnly {
                try command(binary.path, [run.path, defaults, renderCLIOnly ? "--render-cli-only" : "--render-only"], timeout: 10, stdout: run.appendingPathComponent("render.log"), stderr: run.appendingPathComponent("render.err"))
                let render = try json(run.appendingPathComponent("render-receipt.json"))
                try require(render["result"] as? String == "rendered" && render["nativeFlowsExecuted"] as? Bool == false, "Render-only evidence is missing or claims native flow acceptance")
                receipt["result"] = "rendered"; receipt["nativeUIExecuted"] = false; receipt["nativeFlowsExecuted"] = false
                if renderCLIOnly {
                    try require(render["usesOfficialConnection"] as? Bool == true && render["accessibilityReady"] as? Bool == false && render["cliLayoutExecuted"] as? Bool == true,
                                "CLI layout evidence missing or uses the legacy permission mode")
                    guard let checks = render["checks"] as? [String], !checks.isEmpty else { throw HarnessRunnerError.failure("CLI native layout check evidence missing") }
                    receipt["checks"] = checks; receipt["cliLayoutExecuted"] = true
                    receipt["usesOfficialConnection"] = true; receipt["accessibilityReady"] = false
                    receipt["ownFixtureWindowsShown"] = render["ownFixtureWindowsShown"] ?? false
                }
                receipt["images"] = render["images"] ?? []; receipt["background"] = render["background"] ?? ""
                print(renderCLIOnly ? "RENDERED: five current CLI native layouts/group action; no production acceptance" : "RENDERED: three native content views; native UI flows not executed")
                return 0
            }
            if presentationOnly {
                try command(binary.path, [run.path, defaults, "--presentation-only"], timeout: 8, stdout: run.appendingPathComponent("presentation.log"), stderr: run.appendingPathComponent("presentation.err"))
                receipt["result"] = "passed"; receipt["nativeUIExecuted"] = false
                print("PASS: pure UI presentation; native UI not executed")
                return 0
            }
            activated = true
            try command("/usr/bin/open", ["-n", "--stdout", run.appendingPathComponent("runtime.log").path, "--stderr", run.appendingPathComponent("runtime.err").path, fixture.path, "--args", run.path, defaults])
            try waitFor("window-ids.json", run: run, bundle: bundle, timeout: 16)
            let windows = try json(run.appendingPathComponent("window-ids.json"))
            try require(windows["pid"] as? Int32 == ownPID(run, bundle: bundle), "Screenshot owner differs from fixture process")
            var captured: [String: String] = [:]
            do {
                if screenshots {
                    for name in ["main", "settings"] {
                        guard let window = windows[name] as? Int, window > 0 else { throw HarnessRunnerError.failure("Invalid owned window ID") }
                        let target = run.appendingPathComponent(name + "-window.png")
                        try command("/usr/sbin/screencapture", ["-x", "-l", String(window), target.path], timeout: 8, stdout: run.appendingPathComponent(name + "-capture.log"), stderr: run.appendingPathComponent(name + "-capture.err"))
                        try require((try Data(contentsOf: target)).count > 0, "Owned window screenshot missing")
                        captured[name] = target.lastPathComponent
                    }
                }
            } catch {
                fm.createFile(atPath: run.appendingPathComponent("capture-complete").path, contents: nil)
                throw error
            }
            fm.createFile(atPath: run.appendingPathComponent("capture-complete").path, contents: nil)
            try waitFor("harness-receipt.json", run: run, bundle: bundle, timeout: 8)
            let harness = try json(run.appendingPathComponent("harness-receipt.json"))
            guard let checks = harness["checks"] as? [String] else { throw HarnessRunnerError.failure("Native check evidence missing") }
            try require(harness["result"] as? String == "passed" && !checks.isEmpty, "Native UI checks failed")
            receipt["result"] = "passed"; receipt["nativeUIExecuted"] = true; receipt["checks"] = checks
            receipt["credentialFlowCounters"] = harness["credentialFlowCounters"] ?? [:]
            receipt["screenshots"] = captured; receipt["screenshotStatus"] = screenshots ? "captured" : "skipped"
            print("PASS: \(checks.count) isolated native UI checks")
            return 0
        } catch {
            receipt["error"] = String(describing: error)
            throw error
        }
    }
}
