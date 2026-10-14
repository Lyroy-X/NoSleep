import AppKit
import Foundation

// This module deliberately links neither the real power nor Cisco/Keychain implementations.
// Unexpected operations stop the test rather than reaching the user's machine.
func uiForbidden(_ operation: String) -> Never { fputs("UI harness forbids: \(operation)\n", stderr); fflush(stderr); exit(1) }
enum UIHarnessEnvironment {
    static var output: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    static var dataDirectory: URL { output.appendingPathComponent("application-support", isDirectory: true) }
    static var defaultsName: String { CommandLine.arguments[2] }
    static var defaults: UserDefaults { UserDefaults(suiteName: defaultsName)! }
    static func revealApplication(_ application: URL) { uiForbidden("unexpected Finder reveal") }
}
struct LiveState {
    var systemWanted: Bool, systemActual: Bool, displayWanted: Bool, displayActual: Bool
    var error: String?
    var statusTitle: String { error != nil ? " !" : systemWanted && systemActual ? " ON" : displayWanted && displayActual ? " Экран" : " OFF" }
}
struct PowerError: LocalizedError { let message: String; var errorDescription: String? { message } }
final class MacPower {
    func canControlSleep() -> Bool { uiForbidden("power readiness query") }
}
final class HarnessProtection { let power: MacPower; init(_ power: MacPower) { self.power = power } }
final class GuardEngine {
    let protection: HarnessProtection
    let queue = DispatchQueue(label: "NoSleep.UIHarness.unused-power")
    var changed: ((LiveState) -> Void)?
    var fixtureActionsAllowed = false, deferCompletion = false
    private(set) var fixtureCommands: [String] = []
    private var fixtureState = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)
    private var pendingCompletion: (() -> Void)?
    init(_ power: MacPower) { protection = HarnessProtection(power) }
    func act(_ command: String, save: Bool = true, completed: (() -> Void)? = nil) {
        guard fixtureActionsAllowed, Thread.isMainThread, pendingCompletion == nil else { uiForbidden("power action without explicit fixture opt-in") }
        switch command {
        case "all-on": fixtureState.systemWanted = true; fixtureState.displayWanted = true
        case "all-off": fixtureState.systemWanted = false; fixtureState.displayWanted = false
        case "sleep-on": fixtureState.systemWanted = true
        case "sleep-off": fixtureState.systemWanted = false
        case "display-on": fixtureState.displayWanted = true
        case "display-off": fixtureState.displayWanted = false
        default: uiForbidden("unsupported in-memory fixture power action")
        }
        fixtureState.systemActual = fixtureState.systemWanted; fixtureState.displayActual = fixtureState.displayWanted
        fixtureCommands.append(command); changed?(fixtureState)
        if deferCompletion { pendingCompletion = completed } else { completed?() }
    }
    func completeForTesting() {
        guard Thread.isMainThread, let callback = pendingCompletion else { uiForbidden("unexpected fixture power completion") }
        pendingCompletion = nil; callback()
    }
    func state() -> LiveState { guard fixtureActionsAllowed else { uiForbidden("power state") }; return fixtureState }
    func start() { uiForbidden("normal app lifecycle/power watchdog") }
    func shutdownNow() throws { uiForbidden("power shutdown") }
}
struct PowerSetupPlan {
    init(account: String, uid: UInt32) {}
    func execute(_ action: (String) throws -> Void) throws { uiForbidden("administrator setup") }
}
enum IssueCode: String { case commandFailed, commandTimeout, unsupportedState }
enum DiagnosticKind { case launch, powerAction, powerState, shutdown }
struct DiagnosticFacts {
    var sleepWanted: Bool?, sleepActual: Bool?, displayWanted: Bool?, displayActual: Bool?
    var issue: IssueCode?
    var number: Int?
}
final class DiagnosticStore {
    let root: URL
    let storageFailed = false
    var fixturePowerActionsAllowed = false
    private(set) var powerActionCount = 0
    init(root: URL) { self.root = root }
    func record(_ kind: DiagnosticKind, _ facts: DiagnosticFacts = DiagnosticFacts()) {
        guard fixturePowerActionsAllowed, case .powerAction = kind, let index = facts.number, (0..<6).contains(index) else { uiForbidden("normal diagnostics recorder") }
        // Deliberately in-memory: never start log files, exports or production snapshots.
        powerActionCount += 1
    }
    func snapshot(_ state: LiveState) { uiForbidden("normal app state write") }
    func flush() { uiForbidden("normal diagnostics flush") }
    func export(to: URL, permissionReady: Bool) throws { uiForbidden("support export") }
}
