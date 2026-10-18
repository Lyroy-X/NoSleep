import AppKit
import Foundation

// This module deliberately links neither the real power nor Cisco/Keychain implementations.
// Unexpected operations stop the test rather than reaching the user's machine.
func uiForbidden(_ operation: String) -> Never { fputs("UI harness forbids: \(operation)\n", stderr); fflush(stderr); exit(1) }
enum UIHarnessEnvironment {
    static var lifecycle: Bool { CommandLine.arguments.contains("--lifecycle") }
    static var output: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    static var dataDirectory: URL { output.appendingPathComponent("application-support", isDirectory: true) }
    static var defaultsName: String { CommandLine.arguments[2] + ".preferences" }
    static var defaults: UserDefaults { UserDefaults(suiteName: defaultsName)! }
    static func revealApplication(_ application: URL) { uiForbidden("unexpected Finder reveal") }
}
struct LiveState {
    var systemWanted: Bool, systemActual: Bool, displayWanted: Bool, displayActual: Bool
    var error: String?
    var statusTitle: String { error != nil || (systemWanted && !systemActual) || (displayWanted && !displayActual) ? " !" : systemWanted && systemActual ? " ON" : displayWanted && displayActual ? " Экран" : " OFF" }
}
struct PowerError: LocalizedError { let message: String; var errorDescription: String? { message } }
final class MacPower {
    static var readinessQueries = 0
    func canControlSleep() -> Bool {
        if UIHarnessEnvironment.lifecycle {
            Self.readinessQueries += 1
            return !CommandLine.arguments.contains("--missing-permission") && Self.readinessQueries > 1
        }
        uiForbidden("power readiness query")
    }
}
final class HarnessProtection { let power: MacPower; init(_ power: MacPower) { self.power = power } }
final class GuardEngine {
    var timingChanged: ((TimedPowerSnapshot) -> Void)?
    var timedPlan: TimedPowerPlan?
    var rejectTimed = false
    let protection: HarnessProtection
    let queue = DispatchQueue(label: "NoSleep.UIHarness.unused-power")
    var changed: ((LiveState) -> Void)?
    var fixtureActionsAllowed = false, deferCompletion = false
    private(set) var fixtureCommands: [String] = []
    private(set) var fixtureShutdownCount = 0
    var fixtureRejectShutdown = false
    private var fixtureState = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)
    private var pendingCompletion: (() -> Void)?
    init(_ power: MacPower) { protection = HarnessProtection(power) }
    func restoreTimers(completed: @escaping (Bool) -> Void) { completed(false) }
    func startTimed(_ feature: TimedFeature, minutes: Int, completed: @escaping (Bool) -> Void) {
        guard fixtureActionsAllowed else { uiForbidden("timer action without fixture opt-in") }
        if rejectTimed { completed(false); return }
        var plan = timedPlan ?? TimedPowerPlan(baseline: PowerSelection(system: fixtureState.systemWanted, display: fixtureState.displayWanted))
        do { try plan.start(feature, minutes: minutes, now: 0) } catch { completed(false); return }
        timedPlan = plan
        fixtureState.systemWanted = plan.desired.system; fixtureState.systemActual = plan.desired.system
        fixtureState.displayWanted = plan.desired.display; fixtureState.displayActual = plan.desired.display
        timingChanged?(plan.snapshot(now: 0, failed: false)); changed?(fixtureState); completed(true)
    }
    func finishTimed(_ feature: TimedFeature, indefinite: Bool = false, completed: @escaping () -> Void) {
        guard fixtureActionsAllowed else { uiForbidden("timer completion without fixture opt-in") }
        if var plan = timedPlan {
            plan.leases[feature] = nil
            if indefinite { plan.manual(feature == .system ? "sleep-on" : "display-on") }
            timedPlan = plan
            fixtureState.systemWanted = plan.desired.system; fixtureState.systemActual = plan.desired.system
            fixtureState.displayWanted = plan.desired.display; fixtureState.displayActual = plan.desired.display
            timingChanged?(plan.snapshot(now: 0, failed: false)); changed?(fixtureState)
        }
        completed()
    }
    func act(_ command: String, save: Bool = true, completed: (() -> Void)? = nil) {
        guard fixtureActionsAllowed, Thread.isMainThread, pendingCompletion == nil else { uiForbidden("power action without explicit fixture opt-in") }
        switch command {
        case "all-on": fixtureState.systemWanted = true; fixtureState.displayWanted = true
        case "all-off": fixtureState.systemWanted = false; fixtureState.displayWanted = false
        case "sleep-on": fixtureState.systemWanted = true
        case "sleep-off": fixtureState.systemWanted = false; fixtureState.displayWanted = false
        case "display-on": fixtureState.systemWanted = true; fixtureState.displayWanted = true
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
    func start() { if UIHarnessEnvironment.lifecycle { return }; uiForbidden("normal app lifecycle/power watchdog") }
    func shutdownNow() throws {
        guard fixtureActionsAllowed, Thread.isMainThread else { uiForbidden("power shutdown") }
        fixtureShutdownCount += 1
        if fixtureRejectShutdown { throw PowerError(message: "Fixture cleanup denied") }
        fixtureState = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)
        changed?(fixtureState)
    }
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
    private(set) var shutdownCount = 0, flushCount = 0
    init(root: URL) { self.root = root }
    func record(_ kind: DiagnosticKind, _ facts: DiagnosticFacts = DiagnosticFacts()) {
        if fixturePowerActionsAllowed, UIHarnessEnvironment.lifecycle {
            if case .launch = kind { return }
            if case .powerState = kind { return }
        }
        if fixturePowerActionsAllowed, case .shutdown = kind { shutdownCount += 1; return }
        guard fixturePowerActionsAllowed, case .powerAction = kind, let index = facts.number, (0..<6).contains(index) else { uiForbidden("normal diagnostics recorder") }
        // Deliberately in-memory: never start log files, exports or production snapshots.
        powerActionCount += 1
    }
    func snapshot(_ state: LiveState) { if fixturePowerActionsAllowed && UIHarnessEnvironment.lifecycle { return }; uiForbidden("normal app state write") }
    func flush() {
        guard fixturePowerActionsAllowed, shutdownCount > flushCount else { uiForbidden("normal diagnostics flush") }
        flushCount += 1
    }
    func export(to: URL, permissionReady: Bool) throws { uiForbidden("support export") }
}
