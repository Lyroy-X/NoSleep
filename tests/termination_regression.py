"""Hermetic old/new proof: dispatch quit inside this fixture only, never to the OS."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]

STUBS = 'import AppKit\nimport Foundation\n\n// This module deliberately links neither the real power nor Cisco/Keychain implementations.\n// Unexpected operations stop the test rather than reaching the user\'s machine.\nfunc uiForbidden(_ operation: String) -> Never { fputs("UI harness forbids: \\(operation)\\n", stderr); fflush(stderr); exit(1) }\nenum UIHarnessEnvironment {\n    static var output: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }\n    static var dataDirectory: URL { output.appendingPathComponent("application-support", isDirectory: true) }\n    static var defaultsName: String { CommandLine.arguments[2] }\n    static var defaults: UserDefaults { UserDefaults(suiteName: defaultsName)! }\n    static func revealApplication(_ application: URL) { uiForbidden("unexpected Finder reveal") }\n}\nstruct LiveState {\n    var systemWanted: Bool, systemActual: Bool, displayWanted: Bool, displayActual: Bool\n    var error: String?\n    var statusTitle: String { error != nil ? " !" : systemWanted && systemActual ? " ON" : displayWanted && displayActual ? " Экран" : " OFF" }\n}\nstruct PowerError: LocalizedError { let message: String; var errorDescription: String? { message } }\nfinal class MacPower {\n    func canControlSleep() -> Bool { uiForbidden("power readiness query") }\n}\nfinal class HarnessProtection { let power: MacPower; init(_ power: MacPower) { self.power = power } }\nfinal class GuardEngine {\n    let protection: HarnessProtection\n    let queue = DispatchQueue(label: "NoSleep.UIHarness.unused-power")\n    var changed: ((LiveState) -> Void)?\n    var fixtureActionsAllowed = false, deferCompletion = false\n    private(set) var fixtureCommands: [String] = []\n    private(set) var fixtureShutdownCount = 0\n    var fixtureRejectShutdown = false\n    private var fixtureState = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)\n    private var pendingCompletion: (() -> Void)?\n    init(_ power: MacPower) { protection = HarnessProtection(power) }\n    func act(_ command: String, save: Bool = true, completed: (() -> Void)? = nil) {\n        guard fixtureActionsAllowed, Thread.isMainThread, pendingCompletion == nil else { uiForbidden("power action without explicit fixture opt-in") }\n        switch command {\n        case "all-on": fixtureState.systemWanted = true; fixtureState.displayWanted = true\n        case "all-off": fixtureState.systemWanted = false; fixtureState.displayWanted = false\n        case "sleep-on": fixtureState.systemWanted = true\n        case "sleep-off": fixtureState.systemWanted = false\n        case "display-on": fixtureState.displayWanted = true\n        case "display-off": fixtureState.displayWanted = false\n        default: uiForbidden("unsupported in-memory fixture power action")\n        }\n        fixtureState.systemActual = fixtureState.systemWanted; fixtureState.displayActual = fixtureState.displayWanted\n        fixtureCommands.append(command); changed?(fixtureState)\n        if deferCompletion { pendingCompletion = completed } else { completed?() }\n    }\n    func completeForTesting() {\n        guard Thread.isMainThread, let callback = pendingCompletion else { uiForbidden("unexpected fixture power completion") }\n        pendingCompletion = nil; callback()\n    }\n    func state() -> LiveState { guard fixtureActionsAllowed else { uiForbidden("power state") }; return fixtureState }\n    func start() { uiForbidden("normal app lifecycle/power watchdog") }\n    func shutdownNow() throws {\n        guard fixtureActionsAllowed, Thread.isMainThread else { uiForbidden("power shutdown") }\n        fixtureShutdownCount += 1\n        if fixtureRejectShutdown { throw PowerError(message: "Fixture cleanup denied") }\n        fixtureState = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)\n        changed?(fixtureState)\n    }\n}\nstruct PowerSetupPlan {\n    init(account: String, uid: UInt32) {}\n    func execute(_ action: (String) throws -> Void) throws { uiForbidden("administrator setup") }\n}\nenum IssueCode: String { case commandFailed, commandTimeout, unsupportedState }\nenum DiagnosticKind { case launch, powerAction, powerState, shutdown }\nstruct DiagnosticFacts {\n    var sleepWanted: Bool?, sleepActual: Bool?, displayWanted: Bool?, displayActual: Bool?\n    var issue: IssueCode?\n    var number: Int?\n}\nfinal class DiagnosticStore {\n    let root: URL\n    let storageFailed = false\n    var fixturePowerActionsAllowed = false\n    private(set) var powerActionCount = 0\n    private(set) var shutdownCount = 0, flushCount = 0\n    init(root: URL) { self.root = root }\n    func record(_ kind: DiagnosticKind, _ facts: DiagnosticFacts = DiagnosticFacts()) {\n        if fixturePowerActionsAllowed, case .shutdown = kind { shutdownCount += 1; return }\n        guard fixturePowerActionsAllowed, case .powerAction = kind, let index = facts.number, (0..<6).contains(index) else { uiForbidden("normal diagnostics recorder") }\n        // Deliberately in-memory: never start log files, exports or production snapshots.\n        powerActionCount += 1\n    }\n    func snapshot(_ state: LiveState) { uiForbidden("normal app state write") }\n    func flush() {\n        guard fixturePowerActionsAllowed, shutdownCount > flushCount else { uiForbidden("normal diagnostics flush") }\n        flushCount += 1\n    }\n    func export(to: URL, permissionReady: Bool) throws { uiForbidden("support export") }\n}\n'
DRIVER = 'import AppKit\nimport CoreServices\n@objc final class QuitHandler: NSObject {\n    let owner: MenuApp\n    var answer: NSApplication.TerminateReply = .terminateNow\n    var sawCurrentEvent = false\n    init(_ owner: MenuApp) { self.owner = owner }\n    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {\n        sawCurrentEvent = NSAppleEventManager.shared().currentAppleEvent?.eventID == AEEventID(kAEQuitApplication)\n        answer = owner.applicationShouldTerminate(NSApplication.shared)\n    }\n}\n@main enum TerminationRegression {\n    static func main() throws {\n        let app = NSApplication.shared; app.setActivationPolicy(.accessory)\n        let owner = MenuApp(); owner.buildWindow()\n        owner.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)\n        owner.item.menu = NSMenu(); owner.permissionReady = true\n        owner.engine.fixtureActionsAllowed = true; owner.diagnostics.fixturePowerActionsAllowed = true\n        owner.engine.changed = { owner.current = $0 }\n        try FileManager.default.createDirectory(at: UIHarnessEnvironment.dataDirectory, withIntermediateDirectories: true)\n        let handler = QuitHandler(owner), manager = NSAppleEventManager.shared()\n        manager.setEventHandler(handler, andSelector: #selector(QuitHandler.handle(_:reply:)), forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))\n        defer { manager.removeEventHandler(forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication)) }\n        for reason in [kAEShutDown, kAERestart] {\n            owner.engine.act("all-on", save: false); owner.render()\n            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))\n            event.setAttribute(NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(kAEQuitReason))\n            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {\n                if let window = app.modalWindow {\n                    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,\n                        windowNumber: window.windowNumber, context: nil, characters: "\\u{1b}", charactersIgnoringModifiers: "\\u{1b}", isARepeat: false, keyCode: 53)!\n                    app.sendEvent(escape)\n                }\n            }\n            var reply = AppleEvent()\n            let result = manager.dispatchRawAppleEvent(event.aeDesc!, withRawReply: &reply, handlerRefCon: UnsafeMutableRawPointer(bitPattern: 1)!)\n            AEDisposeDesc(&reply)\n            guard result == noErr, handler.sawCurrentEvent else {\n                fputs("ERROR: local Apple Event dispatch failed\\n", stderr); exit(2)\n            }\n            let state = owner.engine.state()\n            print("RESULT cancel=\\(handler.answer == .terminateCancel) protected=\\(state.systemWanted && state.displayWanted) shutdowns=\\(owner.engine.fixtureShutdownCount)")\n        }\n        NSStatusBar.system.removeStatusItem(owner.item); owner.window.close()\n        UIHarnessEnvironment.defaults.removePersistentDomain(forName: UIHarnessEnvironment.defaultsName)\n    }\n}\n'

class TerminationRegressionTests(unittest.TestCase):
    def fixture(self, mutate=False):
        with tempfile.TemporaryDirectory(prefix="NoSleep-termination-regression-") as temporary:
            case = Path(temporary)
            source = (ROOT / "Sources/NoSleep.swift").read_text()
            if mutate:
                anchor = "if let request = SystemTerminationRequest(event: event), !confirm(request) { return .terminateCancel }"
                if anchor not in source:
                    self.skipTest("base revision predates the confirmation guard")
                source = source.replace(anchor, "if false { return .terminateCancel }", 1)
            ui = source[source.index("final class MenuApp:"):source.index("@main enum NoSleepMain")]
            old = 'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoSleep")'
            if ui.count(old) != 1:
                raise RuntimeError("fixture application-support boundary changed")
            ui = ui.replace(old, "UIHarnessEnvironment.dataDirectory").replace("UserDefaults.standard", "UIHarnessEnvironment.defaults")
            (case / "UI.swift").write_text("import AppKit\n" + ui)
            (case / "Stubs.swift").write_text(STUBS)
            (case / "Driver.swift").write_text(DRIVER)
            (case / "Aggregate.swift").write_text('func aggregateTitle(system: Bool, display: Bool) -> String { system || display ? "Выключить всё" : "Включить всё" }\n')
            inputs = [case / "UI.swift", case / "Stubs.swift", case / "Driver.swift", case / "Aggregate.swift", ROOT / "Sources/ApplicationMenu.swift", ROOT / "Sources/NoSleepBrand.swift"]
            # No new API is referenced by the driver. The old revision compiles without this module.
            if (ROOT / "Sources/Termination.swift").exists():
                inputs.append(ROOT / "Sources/Termination.swift")
            if (ROOT / "Sources/PowerPresentation.swift").exists():
                inputs.append(ROOT / "Sources/PowerPresentation.swift")
            executable = case / "Fixture"
            compile_result = subprocess.run(["swiftc", "-module-cache-path", str(ROOT / "build/module-cache/termination-regression"), *map(str, inputs), "-o", str(executable)], capture_output=True, text=True, timeout=90)
            if compile_result.returncode:
                raise RuntimeError("fixture compile failure: " + compile_result.stderr)
            symbols = subprocess.check_output(["nm", "-u", str(executable)], text=True)
            for forbidden in ["_IOPMAssertion", "_SecItem", "_AXUIElement", "_SCNetwork"]:
                if forbidden in symbols:
                    raise RuntimeError("fixture unexpectedly links " + forbidden)
            result = subprocess.run([str(executable), str(case), "local.NoSleep.TerminationRegression." + uuid.uuid4().hex], capture_output=True, text=True, timeout=20)
            if result.returncode:
                raise RuntimeError("fixture runtime failure: " + result.stdout + result.stderr)
            return result.stdout

    def test_system_quit_cancel_keeps_protection_and_never_cleans_up(self):
        output = self.fixture()
        self.assertEqual(output.count("RESULT cancel=true protected=true shutdowns=0"), 2, output)
        evidence = ROOT / "build/termination-regression"
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "receipt.json").write_text(json.dumps({"result": "passed", "localDispatchOnly": True, "realPowerActions": 0, "output": output}, indent=2))

    def test_critical_confirmation_bypass_is_detected(self):
        # The original passes, the owned faulty source must fail the same behavior assertion.
        baseline = self.fixture()
        self.assertEqual(baseline.count("RESULT cancel=true protected=true shutdowns=0"), 2, baseline)
        mutant = self.fixture(mutate=True)
        with self.assertRaises(AssertionError):
            self.assertEqual(mutant.count("RESULT cancel=true protected=true shutdowns=0"), 2, mutant)
        self.assertEqual(mutant.count("RESULT cancel=false protected=false"), 2, mutant)

if __name__ == "__main__":
    unittest.main(verbosity=2)
