import AppKit
import IOKit.pwr_mgt

protocol PowerControl {
    func setBlocked(_ value: Bool) throws
    func blocked() throws -> Bool
    func holdIdle() throws
    func releaseIdle()
    func holdDisplay() throws
    func releaseDisplay()
    func displayHeld() -> Bool
}

struct PowerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func waitForPowerState(_ desired: Bool, timeout: TimeInterval = 3, read: () throws -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
        if try read() == desired { return }
        Thread.sleep(forTimeInterval: 0.02)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw PowerError(message: "macOS не успела применить изменение сна. Повторите переключение.")
}

func allowsPasswordlessPower(_ listing: String) -> Bool {
    var records: [String] = []
    for raw in listing.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("(") { records.append(line) }
        else if !records.isEmpty { records[records.count - 1] += " " + line }
    }
    var commands = Set<String>()
    for record in records {
        guard let close = record.firstIndex(of: ")") else { continue }
        let runAs = String(record[record.index(after: record.startIndex)..<close]).components(separatedBy: ":")[0]
        let users = runAs.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard users.contains("root") || users.contains("ALL"),
              let tag = record.range(of: "NOPASSWD:") else { continue }
        let body = String(record[tag.upperBound...])
        // Fail closed on complex overrides or explicit deny rules.
        guard !body.contains("!") && !body.contains("PASSWD:") else { continue }
        for command in body.components(separatedBy: ",") {
            commands.insert(command.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        }
    }
    return commands.contains("ALL") || (commands.contains("/usr/bin/pmset -a disablesleep 1") && commands.contains("/usr/bin/pmset -a disablesleep 0"))
}

func shellQuote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleScriptQuote(_ string: String) -> String {
    "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
}
struct PowerSetupPlan {
    let account: String
    let uid: UInt32
    var destination: String { "/private/etc/sudoers.d/nosleep_\(uid)" }
    var rule: String { "\(account) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n" }
    init(account: String, uid: UInt32) throws {
        guard uid > 0, account.range(of: "^[\\p{L}\\p{M}\\p{N}_.-]+$", options: .regularExpression) == account.startIndex..<account.endIndex else {
            throw PowerError(message: "Не удалось подготовить настройку для этой учётной записи.")
        }
        self.account = account; self.uid = uid
    }
    func execute(runner: (String) throws -> Void) throws {
        // Construct the rule inside the privileged process. Never trust a user-writable
        // staging file while installing a permanent administrator rule.
        let command = """
        set -eu
        umask 077
        stage_dir=$(/usr/bin/mktemp -d /private/tmp/NoSleep-root.XXXXXX)
        trap '/bin/rm -f "$stage_dir/power-rule"; /bin/rmdir "$stage_dir"' EXIT
        /usr/bin/printf '%s' \(shellQuote(rule)) > "$stage_dir/power-rule"
        /usr/sbin/visudo -cf "$stage_dir/power-rule"
        test ! -e \(shellQuote(destination))
        /usr/bin/install -o root -g wheel -m 0440 "$stage_dir/power-rule" \(shellQuote(destination))
        /usr/sbin/visudo -cf \(shellQuote(destination))
        """
        try runner("do shell script " + appleScriptQuote(command) + " with administrator privileges")
    }
}
func setupTests() throws {
    let legacy = "(ALL) ALL\n(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1,\n    /usr/bin/pmset -a disablesleep 0"
    assert(allowsPasswordlessPower(legacy))
    assert(!allowsPasswordlessPower("(ALL) ALL"), "Cached admin access is not permanent setup")
    assert(!allowsPasswordlessPower("(guest) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"))
    assert(!allowsPasswordlessPower("(root) NOPASSWD: /usr/bin/pmset -a disablesleep 10, /usr/bin/pmset -a disablesleep 0"))
    assert(!allowsPasswordlessPower("(root) NOPASSWD: ALL, ! /usr/bin/pmset -a disablesleep 0"))
    assert(!allowsPasswordlessPower("(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, PASSWD: /usr/bin/pmset -a disablesleep 0"))
    let plan = try PowerSetupPlan(account: "friend.test", uid: 502)
    assert(plan.rule == "friend.test ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n")
    assert(plan.destination == "/private/etc/sudoers.d/nosleep_502")
    let unicodePlan = try PowerSetupPlan(account: "пётр", uid: 503)
    assert(unicodePlan.rule.hasPrefix("пётр ALL="))
    do { _ = try PowerSetupPlan(account: "a'; touch /tmp/b", uid: 502); fatalError("Unsafe account accepted") } catch {}
    do { _ = try PowerSetupPlan(account: "friend\n", uid: 502); fatalError("Multiline account accepted") } catch {}
    var captured = ""
    try plan.execute { script in captured = script }
    assert(captured.contains("administrator privileges") && captured.contains("nosleep_502") && captured.contains("visudo -cf"))
    do { try plan.execute { _ in throw PowerError(message: "cancelled") }; fatalError("Cancellation hidden") } catch {}
    print("PASS: first-run permissions, cached-access rejection, per-user limited rule, input validation, cancellation")
}

final class MacPower: PowerControl {
    private var assertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        do {
            return try BoundedLockProcess.run(URL(fileURLWithPath: executable), arguments, seconds: 5, limit: 65536)
        } catch ScreenLockFailure.timeout {
            throw PowerError(message: "macOS не ответила за 5 секунд. Повторите переключение.")
        } catch {
            throw PowerError(message: "macOS не подтвердила команду питания. Проверьте доступ и повторите.")
        }
    }
    func canControlSleep() -> Bool {
        guard let listing = try? run("/usr/bin/sudo", ["-n", "-l"]) else { return false }
        return allowsPasswordlessPower(listing)
    }
    func setBlocked(_ value: Bool) throws {
        _ = try run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value ? "1" : "0"])
        try waitForPowerState(value) { try self.blocked() }
    }
    func blocked() throws -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { throw PowerError(message: "Не удалось прочитать состояние сна macOS.") }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        else { throw PowerError(message: "macOS не сообщила состояние запрета сна.") }
        return value.boolValue
    }
    func holdIdle() throws {
        guard assertion == 0 else { return }
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NoSleep — System" as CFString, &assertion)
        guard status == kIOReturnSuccess else {
            assertion = 0
            throw PowerError(message: "macOS не разрешила включить защиту от бездействия.")
        }
    }
    func releaseIdle() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
    func holdDisplay() throws {
        guard displayAssertion == 0 else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NoSleep — Display" as CFString, &displayAssertion)
        guard result == kIOReturnSuccess else {
            displayAssertion = 0
            throw PowerError(message: "macOS не разрешила включить защиту экрана.")
        }
    }
    func releaseDisplay() {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }
    func displayHeld() -> Bool {
        guard displayAssertion != 0,
              let properties = IOPMAssertionCopyProperties(displayAssertion)?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (properties[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn)
    }
}

final class Protection {
    let power: PowerControl
    private(set) var active = false
    private(set) var displayActive = false
    init(_ power: PowerControl) { self.power = power }
    func enable() throws {
        let wasActive = active
        try power.holdIdle()
        do {
            try power.setBlocked(true)
            guard try power.blocked() else { throw PowerError(message: "Запрет сна не применился.") }
            active = true
        } catch {
            if !wasActive { power.releaseIdle() }
            throw error
        }
    }
    func disable() throws {
        // Retain the active state if restoring sleep fails, so the user can retry.
        try power.setBlocked(false)
        guard try !power.blocked() else { throw PowerError(message: "Не удалось вернуть обычный режим сна.") }
        // Display protection depends on system protection. Keep both if restoration fails.
        try setDisplay(false)
        power.releaseIdle()
        active = false
    }
    func refresh() throws {
        if active { if try !power.blocked() { try enable() } }
        if displayActive && !power.displayHeld() {
            power.releaseDisplay()
            try power.holdDisplay()
        }
    }
    func setDisplay(_ enabled: Bool) throws {
        if enabled {
            // Confirm the prerequisite even on retry after an external system reset.
            if !active { try enable() }
            else if try !power.blocked() { try enable() }
            try power.holdDisplay()
            guard power.displayHeld() else {
                power.releaseDisplay()
                throw PowerError(message: "Защита экрана не применилась.")
            }
        } else { power.releaseDisplay() }
        displayActive = enabled
    }
    func shutdown() throws {
        if active { try disable() }
        try setDisplay(false)
    }
}

final class FakePower: PowerControl {
    var value = false
    var idle = false
    var reject = false
    var display = false
    var rejectDisplay = false
    func setBlocked(_ v: Bool) throws {
        if reject { throw PowerError(message: "Denied") }
        value = v
    }
    func blocked() throws -> Bool { value }
    func holdIdle() throws { idle = true }
    func releaseIdle() { idle = false }
    func holdDisplay() throws {
        if rejectDisplay { throw PowerError(message: "Display denied") }
        display = true
    }
    func releaseDisplay() { display = false }
    func displayHeld() -> Bool { display }
}

func selfTest() throws {
    var reads = 0
    try waitForPowerState(false) { reads += 1; return reads < 4 }
    assert(reads == 4, "Delayed kernel acknowledgement must be awaited")
    do {
        try waitForPowerState(false, timeout: 0.04) { true }
        fatalError("Missing kernel acknowledgement was hidden")
    } catch {}
    let fake = FakePower()
    let control = Protection(fake)
    try control.enable()
    assert(control.active && fake.value && fake.idle)
    fake.value = false
    fake.reject = true
    do { try control.refresh(); fatalError("Reset failure was hidden") } catch {}
    assert(control.active && fake.idle, "Recovery failure must retain idle protection")
    fake.reject = false
    try control.refresh()
    assert(control.active && fake.value && fake.idle)
    try control.disable()
    assert(!control.active && !fake.value && !fake.idle)
    try control.refresh()
    assert(!fake.value, "Off must stay off")
    fake.reject = true
    do { try control.enable(); fatalError("Failure was hidden") } catch {}
    assert(!control.active && !fake.idle)
    fake.reject = false
    try control.enable()
    fake.reject = true
    do { try control.disable(); fatalError("Failure was hidden") } catch {}
    assert(control.active && fake.idle, "Failed shutdown must remain retryable")
    fake.reject = false
    try control.disable()
    try control.setDisplay(true)
    assert(control.displayActive && fake.display && control.active)
    try control.enable()
    try control.disable()
    assert(!control.displayActive && !fake.display, "Sleep-off must release dependent display protection")
    try control.setDisplay(true)
    fake.display = false
    try control.refresh()
    assert(fake.display, "Display assertion must recover")
    try control.setDisplay(false)
    assert(!control.displayActive && !fake.display)
    fake.rejectDisplay = true
    do { try control.setDisplay(true); fatalError("Display failure was hidden") } catch {}
    assert(!control.displayActive && !fake.display)
    fake.rejectDisplay = false
    try control.setDisplay(true)
    try control.enable()
    try control.shutdown()
    assert(!control.active && !control.displayActive && !fake.display && !fake.idle)
    print("PASS: on, off, external reset, off stays off, enable failure, retryable disable")
    print("PASS: directional display/sleep dependency, assertion recovery, failure, quit cleanup")
}

struct LiveState: Codable {
    var systemWanted: Bool
    var systemActual: Bool
    var displayWanted: Bool
    var displayActual: Bool
    // Timer presentation is delivered separately; diagnostics retain their stable schema.
    var error: String?
    var pid: Int32 = getpid()
    var updatedAt: Double = Date().timeIntervalSince1970
    var statusTitle: String {
        if error != nil || (systemWanted && !systemActual) || (displayWanted && !displayActual) { return " !" }
        if systemWanted && systemActual { return " ON" }
        if displayWanted && displayActual { return " Экран" }
        return " OFF"
    }
}

final class GuardEngine {
    let protection: Protection
    let queue = DispatchQueue(label: "NoSleep.power")
    var timer: DispatchSourceTimer?
    var changed: ((LiveState) -> Void)?
    private var actionError: String?
    private var pollError: String?
    private var timedPlan: TimedPowerPlan?
    private var timedFailure = false
    var timingChanged: ((TimedPowerSnapshot) -> Void)?
    var timedNow: () -> TimeInterval = {
        let clock = ContinuousClock(), origin = ContinuousClock.now
        return { let d = origin.duration(to: clock.now).components; return Double(d.seconds) + Double(d.attoseconds) / 1e18 }
    }()
    let powerDefaults: UserDefaults
    init(_ power: PowerControl, preferences: UserDefaults = UserDefaults.standard) { protection = Protection(power); powerDefaults = preferences }
    func timingState() -> TimedPowerSnapshot { timedPlan?.snapshot(now: timedNow(), failed: timedFailure) ?? TimedPowerSnapshot() }
    private func publishTiming() { timingChanged?(timingState()) }
    private func reconcileTimed(_ selection: PowerSelection, forceOff: Bool = false) throws {
        if selection.system && !protection.active { try protection.enable() }
        if selection.display != protection.displayActive { try protection.setDisplay(selection.display) }
        if !selection.system && (protection.active || forceOff) { try protection.disable() }
        // A selected switch alone is not confirmation: repair/read back lost assertions.
        if selection.system { try protection.refresh() }
    }
    private func saveTimedBaseline(_ baseline: PowerSelection) throws {
        powerDefaults.set(try JSONEncoder().encode(baseline), forKey: "TimedPowerBaseline")
        powerDefaults.set(baseline.system, forKey: "PreventSystemSleep")
        powerDefaults.set(baseline.display, forKey: "KeepDisplayAwake")
        guard powerDefaults.synchronize() else { throw PowerError(message: "Не удалось сохранить исходное состояние таймера.") }
    }
    private func clearTimedBaselineIfFinished() {
        if timedPlan?.leases.isEmpty == true { powerDefaults.removeObject(forKey: "TimedPowerBaseline") }
    }
    func restoreTimers(completed: @escaping (Bool) -> Void) {
        queue.async {
            guard let data = self.powerDefaults.data(forKey: "TimedPowerBaseline") else { completed(false); return }
            do {
                let baseline = try JSONDecoder().decode(PowerSelection.self, from: data)
                guard !baseline.display || baseline.system else { throw PowerError(message: "Неизвестное исходное состояние таймера.") }
                try self.reconcileTimed(baseline, forceOff: true)
                self.powerDefaults.removeObject(forKey: "TimedPowerBaseline")
                self.actionError = nil
            } catch { self.actionError = "Не удалось восстановить состояние после таймера. Повторите переключение защиты." }
            self.changed?(self.state()); completed(true)
        }
    }
    func startTimed(_ feature: TimedFeature, minutes: Int, completed: @escaping (Bool) -> Void) {
        queue.async {
            let prior = self.timedPlan
            var plan = prior ?? TimedPowerPlan(baseline: PowerSelection(system: self.protection.active, display: self.protection.displayActive))
            do {
                try plan.start(feature, minutes: minutes, now: self.timedNow())
                try self.saveTimedBaseline(plan.baseline)
                try self.reconcileTimed(plan.desired)
                // Acquisition may take time: start the full duration after confirmation.
                try plan.start(feature, minutes: minutes, now: self.timedNow())
                self.timedPlan = plan; self.timedFailure = false; self.actionError = nil; self.pollError = nil
                self.publishTiming(); self.changed?(self.state()); completed(true)
            } catch {
                self.timedPlan = prior ?? TimedPowerPlan(baseline: plan.baseline)
                self.actionError = error.localizedDescription
                self.publishTiming(); self.changed?(self.state()); completed(false)
            }
        }
    }
    func finishTimed(_ feature: TimedFeature, indefinite: Bool = false, completed: @escaping () -> Void) {
        queue.async {
            guard var plan = self.timedPlan else { completed(); return }
            let previous = plan
            plan.leases[feature] = nil
            if indefinite {
                if feature == .system { plan.baseline.system = true }
                else { plan.baseline.system = true; plan.baseline.display = true }
            }
            do {
                try self.saveTimedBaseline(plan.baseline)
                try self.reconcileTimed(plan.desired)
                self.timedPlan = plan; self.timedFailure = false; self.actionError = nil; self.pollError = nil
                self.clearTimedBaselineIfFinished()
            } catch {
                self.timedPlan = previous; self.timedFailure = true; self.actionError = error.localizedDescription
                try? self.saveTimedBaseline(previous.baseline)
            }
            self.publishTiming(); self.changed?(self.state()); completed()
        }
    }
    func tickTimed() {
        guard var next = timedPlan, !next.leases.isEmpty else { return }
        let previous = next
        next.expire(now: timedNow())
        if next.leases != previous.leases && !timedFailure {
            do {
                try reconcileTimed(next.desired)
                timedPlan = next; timedFailure = false; actionError = nil; pollError = nil
                clearTimedBaselineIfFinished()
            } catch { timedFailure = true; actionError = "Не удалось завершить таймер. Повторите восстановление в выборе времени." }
        }
        publishTiming()
    }
    func state() -> LiveState {
        var error = actionError ?? pollError
        let actual: Bool
        do { actual = try protection.power.blocked() }
        catch let failure { actual = false; error = failure.localizedDescription }
        return LiveState(systemWanted: protection.active, systemActual: actual,
                         displayWanted: protection.displayActive, displayActual: protection.power.displayHeld(), error: error)
    }
    func act(_ command: String, save: Bool = true, completed: (() -> Void)? = nil) {
        queue.async {
            do {
                switch command {
                case "sleep-on": try self.protection.enable()
                case "sleep-off": try self.protection.disable()
                case "display-on": try self.protection.setDisplay(true)
                case "display-off": try self.protection.setDisplay(false)
                case "all-on": try self.protection.setDisplay(true)
                case "all-off": try self.protection.shutdown()
                default: throw PowerError(message: "Неизвестная команда")
                }
                if var plan = self.timedPlan {
                    plan.manual(command); self.timedPlan = plan; self.timedFailure = false
                    if save == true { try self.saveTimedBaseline(plan.baseline); self.clearTimedBaselineIfFinished() }
                } else if save == true { self.powerDefaults.removeObject(forKey: "TimedPowerBaseline") }
                self.actionError = nil
                self.pollError = nil
            } catch { self.actionError = error.localizedDescription }
            // A failed combined command may still have acquired/retained protection.
            if save {
                self.powerDefaults.set(self.timedPlan?.baseline.system ?? self.protection.active, forKey: "PreventSystemSleep")
                self.powerDefaults.set(self.timedPlan?.baseline.display ?? self.protection.displayActive, forKey: "KeepDisplayAwake")
            }
            self.publishTiming()
            self.changed?(self.state())
            completed?()
        }
    }
    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.tickTimed()
            if self.protection.active, (try? self.protection.power.blocked()) == false {
                self.changed?(self.state())
            }
            do { try self.protection.refresh(); self.pollError = nil }
            catch { self.pollError = error.localizedDescription }
            self.changed?(self.state())
        }
        timer = t; t.resume()
    }
    func stop(completed: @escaping (Error?) -> Void) {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            do { try self.protection.shutdown(); if self.timedPlan != nil { self.powerDefaults.removeObject(forKey: "TimedPowerBaseline") }; self.timedPlan = nil; self.changed?(self.state()); completed(nil) }
            catch { self.start(); completed(error) }
        }
    }
    func shutdownNow() throws {
        try queue.sync {
            timer?.cancel(); timer = nil
            do { try protection.shutdown(); if timedPlan != nil { powerDefaults.removeObject(forKey: "TimedPowerBaseline") }; timedPlan = nil; changed?(state()) }
            catch { start(); throw error }
        }
    }
}

func backgroundTest() throws {
    assert(LiveState(systemWanted: false, systemActual: false, displayWanted: true, displayActual: true, error: nil).statusTitle == " Экран")
    assert(LiveState(systemWanted: true, systemActual: false, displayWanted: false, displayActual: false, error: "Denied").statusTitle == " !")
    let fake = FakePower()
    let engine = GuardEngine(fake)
    let enabled = DispatchSemaphore(value: 0)
    engine.act("sleep-on", save: false) { enabled.signal() }
    guard enabled.wait(timeout: .now() + 3) == .success else { throw PowerError(message: "Enable timeout") }
    engine.queue.sync { fake.value = false }
    engine.start()
    // The calling/UI thread stays blocked: enforcement must continue on its own queue.
    Thread.sleep(forTimeInterval: 2.2)
    let recovered = engine.queue.sync { fake.value && fake.idle }
    guard recovered else { throw PowerError(message: "Background guard stopped with blocked UI") }
    let stopped = DispatchSemaphore(value: 0)
    engine.stop { _ in stopped.signal() }
    guard stopped.wait(timeout: .now() + 3) == .success else { throw PowerError(message: "Shutdown timeout") }
    assert(!fake.value && !fake.idle)
    print("PASS: background recovery continues while UI thread is blocked; async shutdown")
}

final class MenuApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    let engine = GuardEngine(MacPower())
    var current = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)
    var item: NSStatusItem!
    var window: NSWindow!
    var sleepSwitch: NSSwitch!
    var displaySwitch: NSSwitch!
    var lockSwitch: NSSwitch!
    var lockState: NSTextField!
    var lockHelpButton: NSButton!
    var helpPopover: NSPopover?
    var durationPopover: NSPopover?
    var sleepDurationButton: NSButton!, displayDurationButton: NSButton!
    var timedState = TimedPowerSnapshot()
    lazy var durationHistory = DurationHistory(defaults: UserDefaults.standard)
    var restoreLockButton: NSButton!
    var sleepState: NSTextField!
    var displayState: NSTextField!
    var errorLabel: NSTextField!
    var setupLabel: NSTextField!
    var setupButton: NSButton!
    var setupRow: NSStackView!
    var permissionReady: Bool?
    var setupError: String?
    var busy = false
    var pendingPowerAction: String?
    var summaryIcon: StatusSymbolView!
    var summaryLabel: NSTextField!
    var summaryDetail: NSTextField!
    var observer: NSObjectProtocol?
    let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoSleep")
    lazy var diagnostics = DiagnosticStore(root: dataDir)
    lazy var lockController = AutomaticLockController(backend: SystemScreenLockBackend(),
        store: FileScreenLockRestoreStore(directory: dataDir.appendingPathComponent("AutomaticLock")))
    var lockPasswordPrompt: ((ScreenLockPlan, @escaping (ScreenLockSecret?) -> Void) -> Void)?
    var terminationCompletion: ((Bool) -> Void)?
    var lastUIData = Data()
    var allButton: NSButton!
    var exportButton: NSButton!
    var exporting = false
    private var handlingTermination = false
    private var quitScheduled = false
    private var quitInProgress = false
    static let exportToolbar = NSToolbarItem.Identifier("NoSleep.Export")

    func writeUI() {
        let state: [String: Any] = ["windowVisible": window.isVisible, "windowTitle": window.title,
                                  "statusTitle": item?.button?.title ?? current.statusTitle,
                                  "sleepChecked": sleepSwitch.state == .on, "displayChecked": displaySwitch.state == .on,
                                  "lockChecked": lockSwitch.state == .on, "lockEnabled": lockSwitch.isEnabled,
                                  "lockText": lockState.stringValue,
                                  "errorText": errorLabel.stringValue,
                                  "setupVisible": !setupRow.isHidden, "sleepEnabled": sleepSwitch.isEnabled,
                                  "setupText": setupLabel.stringValue, "setupButtonTitle": setupButton.title,
                                  "allButtonTitle": allButton.title, "diagnosticsFailed": diagnostics.storageFailed,
                                  "exporting": exporting, "summaryText": summaryLabel.stringValue, "summarySymbol": summaryIcon.symbolName]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), data != lastUIData {
            try? data.write(to: dataDir.appendingPathComponent("ui.json"), options: .atomic); lastUIData = data
        }
    }
    func uiLabel(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    func switchControl(_ title: String, action: Selector) -> NSSwitch {
        let control = NSSwitch(); control.target = self; control.action = action
        control.setAccessibilityLabel(title); control.toolTip = title
        return control
    }
    func symbolView(_ name: String, size: CGFloat = 22) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        view.contentTintColor = .secondaryLabelColor
        view.widthAnchor.constraint(equalToConstant: size + 2).isActive = true
        view.heightAnchor.constraint(equalToConstant: size + 2).isActive = true
        view.setAccessibilityElement(false)
        return view
    }
    func row(_ title: String, detail: NSTextField? = nil, symbol: String, control: NSView) -> NSStackView {
        let labels = NSStackView(); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        labels.addArrangedSubview(uiLabel(title, size: 13, weight: .medium))
        if let detail = detail { labels.addArrangedSubview(detail) }
        let icon = NSImageView(); icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor; icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true; icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let result = NSStackView(views: [icon, labels, control]); result.distribution = .fill; result.orientation = .horizontal; result.alignment = .centerY; result.spacing = 18
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return result
    }
    func separator() -> NSView {
        let view = NSBox(); view.boxType = .separator
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }
    func card(_ rows: [NSView]) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle
        box.fillColor = .controlBackgroundColor; box.borderColor = .separatorColor
        box.borderWidth = 0.5; box.cornerRadius = 12
        let stack = NSStackView(views: rows); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                                     stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
                                     stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 18),
                                     stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -18)])
        for view in rows { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return box
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "NoSleep"; window.contentMinSize = NSSize(width: 520, height: 360)
        window.delegate = self; window.isReleasedWhenClosed = false
        allButton = NSButton(title: "Выключить всё", target: self, action: #selector(toggleAll)); allButton.bezelStyle = .rounded
        allButton.setAccessibilityLabel("Включить или выключить все функции NoSleep")
        allButton.toolTip = "Включить или выключить все функции · ⇧⌘A"
        allButton.heightAnchor.constraint(equalToConstant: 28).isActive = true; allButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 135).isActive = true
        exportButton = NSButton(title: "Отчёт…", target: self, action: #selector(exportDiagnostics)); exportButton.bezelStyle = .rounded
        exportButton.toolTip = "Сохранить диагностику без паролей"
        exportButton.setAccessibilityLabel("Сохранить диагностику NoSleep")
        exportButton.heightAnchor.constraint(equalToConstant: 28).isActive = true; exportButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        let toolbar = NSToolbar(identifier: "NoSleep.Toolbar"); toolbar.delegate = self
        toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .unifiedCompact
        window.setContentSize(NSSize(width: 600, height: 620))
        window.setFrameAutosaveName("NoSleep.MainWindow"); if !window.setFrameUsingName("NoSleep.MainWindow") { window.center() }
        let scroll = FittingScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = .windowBackgroundColor
        let document = FlippedContentView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        window.contentView!.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
                                     scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
                                     scroll.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
                                     scroll.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        scroll.documentWidth = document.widthAnchor.constraint(equalToConstant: 600)
        scroll.documentWidth?.isActive = true
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 16
        body.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
                                     body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
                                     body.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
                                     body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)])
        summaryLabel = uiLabel("Проверяю готовность…", size: 22, weight: .bold)
        summaryDetail = uiLabel("Проверяю доступ к защите сна.", secondary: true)
        summaryIcon = StatusSymbolView()
        summaryIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        summaryIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        summaryIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        summaryIcon.setAccessibilityElement(false)
        let summaryText = NSStackView(views: [summaryLabel, summaryDetail]); summaryText.orientation = .vertical
        summaryText.alignment = .leading; summaryText.spacing = 5
        summaryText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let summary = NSStackView(views: [summaryIcon, summaryText]); summary.alignment = .centerY; summary.spacing = 14
        body.addArrangedSubview(summary); body.setCustomSpacing(24, after: summary)
        setupLabel = uiLabel("Проверяю готовность NoSleep…", secondary: true)
        setupButton = NSButton(title: "Настроить NoSleep", target: self, action: #selector(setupPower)); setupButton.bezelStyle = .rounded
        setupRow = NSStackView(views: [setupLabel, setupButton]); setupRow.orientation = .vertical; setupRow.alignment = .leading; setupRow.spacing = 8
        setupButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        body.addArrangedSubview(setupRow)
        setupLabel.widthAnchor.constraint(equalTo: setupRow.widthAnchor).isActive = true
        sleepSwitch = switchControl("Mac не засыпает", action: #selector(toggleSleep))
        displaySwitch = switchControl("Экран не гаснет", action: #selector(toggleDisplay))
        sleepDurationButton = NSButton(title: "∞", target: self, action: #selector(showSleepDuration))
        displayDurationButton = NSButton(title: "∞", target: self, action: #selector(showDisplayDuration))
        sleepDurationButton.setAccessibilityLabel("Время защиты сна")
        displayDurationButton.setAccessibilityLabel("Время защиты экрана")
        for button in [sleepDurationButton!, displayDurationButton!] {
            button.bezelStyle = .rounded; button.controlSize = .small
            button.widthAnchor.constraint(equalToConstant: 88).isActive = true
        }
        let sleepControls = NSStackView(views: [sleepDurationButton, sleepSwitch]); sleepControls.spacing = 8
        let displayControls = NSStackView(views: [displayDurationButton, displaySwitch]); displayControls.spacing = 8
        sleepControls.widthAnchor.constraint(equalToConstant: 150).isActive = true
        displayControls.widthAnchor.constraint(equalToConstant: 150).isActive = true
        lockSwitch = switchControl("Не блокировать автоматически", action: #selector(toggleLock))
        lockState = uiLabel("Проверяю настройку автоблокировки…", secondary: true)
        lockHelpButton = NSButton(title: "", target: self, action: #selector(showLockHelp)); lockHelpButton.bezelStyle = .helpButton
        lockHelpButton.setAccessibilityLabel("Когда включать защиту")
        lockHelpButton.toolTip = "Показать примеры: загрузки, презентации и работа нейронки"
        let lockControls = NSStackView(views: [lockHelpButton, lockSwitch]); lockControls.spacing = 8
        lockControls.distribution = .fill
        lockControls.widthAnchor.constraint(equalToConstant: 94).isActive = true
        sleepState = uiLabel("Проверяю…", secondary: true); displayState = uiLabel("Проверяю…", secondary: true)
        let power = card([row("Mac не засыпает", detail: sleepState, symbol: "laptopcomputer", control: sleepControls), separator(),
                          row("Экран не гаснет", detail: displayState, symbol: "display", control: displayControls), separator(),
                          row("Не блокировать автоматически", detail: lockState, symbol: "lock.open", control: lockControls)])
        body.addArrangedSubview(power); body.setCustomSpacing(20, after: power)
        restoreLockButton = NSButton(title: "Восстановить исходную блокировку…", target: self, action: #selector(restoreAutomaticLock))
        restoreLockButton.bezelStyle = .rounded; restoreLockButton.isHidden = true; body.addArrangedSubview(restoreLockButton)
        let actions = NSStackView(views: [allButton, NSView()]); actions.orientation = .horizontal; actions.alignment = .centerY
        body.addArrangedSubview(actions)
        errorLabel = uiLabel(""); errorLabel.textColor = .systemRed; errorLabel.isHidden = true; body.addArrangedSubview(errorLabel)
        let foot = uiLabel("Закрытие окна оставляет NoSleep работать в фоне.", size: 11, secondary: true); body.addArrangedSubview(foot)
        body.addArrangedSubview(uiLabel("Отчёт… · до 200 МБ · 7 дней · без паролей", size: 11, secondary: true))
        for view in body.arrangedSubviews { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.exportToolbar] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Self.exportToolbar {
            item.view = exportButton; item.label = "Диагностика"
        } else { return nil }
        return item
    }
    func statusMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Открыть NoSleep", action: #selector(showWindow), keyEquivalent: "")); menu.addItem(.separator())
        let sleepMenu = NSMenuItem(title: "Mac не засыпает", action: #selector(toggleSleep), keyEquivalent: ""); sleepMenu.tag = 2; menu.addItem(sleepMenu)
        let displayMenu = NSMenuItem(title: "Экран не гаснет", action: #selector(toggleDisplay), keyEquivalent: ""); displayMenu.tag = 3; menu.addItem(displayMenu)
        let lockMenu = NSMenuItem(title: "Не блокировать автоматически", action: #selector(toggleLock), keyEquivalent: ""); lockMenu.tag = 4; menu.addItem(lockMenu)
        let allMenu = NSMenuItem(title: "Выключить всё", action: #selector(toggleAll), keyEquivalent: ""); allMenu.tag = 5; menu.addItem(allMenu)
        menu.addItem(NSMenuItem(title: "Сохранить диагностику…", action: #selector(exportDiagnostics), keyEquivalent: "")); menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(quitApp), keyEquivalent: "q"))
        for entry in menu.items { entry.target = self }
        return menu
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = applicationMenu(target: self)
        NSApplication.shared.windowsMenu = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "Окно" })?.submenu
        NSApplication.shared.helpMenu = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "Помощь" })?.submenu
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true); diagnostics.record(.launch)
        buildWindow()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = statusMenu()
        startAutomaticLock()
        engine.timingChanged = { [weak self] snapshot in DispatchQueue.main.async { self?.timedState = snapshot; self?.render() } }
        engine.changed = { [weak self] state in
            guard let self = self else { return }; self.writeState(state)
            let lostPermission = state.error != nil && (self.engine.protection.power as? MacPower)?.canControlSleep() == false
            DispatchQueue.main.async { if lostPermission { self.permissionReady = false }; self.current = state; self.render() }
        }
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("local.robert.NoSleep.command"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let command = notification.userInfo?["command"] as? String else { return }
            if command == "show" { self.showWindow() }
            else if command == "hide" { self.window.close() }
            else if command == "quit" { self.quitApp() }
            else if command == "snapshot" {
                if let view = self.window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: image)
                    if let data = image.representation(using: .png, properties: [:]) { try? data.write(to: self.dataDir.appendingPathComponent("window.png")) }
                }
            } else if command == "export-test" { self.saveDiagnostics(to: self.dataDir.appendingPathComponent("last-support-test.zip")) }
            else if command == "toggle-all" { self.toggleAll() }
            else if ["sleep-on", "sleep-off", "display-on", "display-off", "all-off", "all-on", "lock-on", "lock-off"].contains(command) { self.perform(command) }
        }
        let wantedSystem = UserDefaults.standard.object(forKey: "PreventSystemSleep") == nil || UserDefaults.standard.bool(forKey: "PreventSystemSleep")
        let wantedDisplay = UserDefaults.standard.bool(forKey: "KeepDisplayAwake")
        let preview = CommandLine.arguments.contains("--preview-first-run")
        busy = true
        engine.queue.async {
            let power = self.engine.protection.power as? MacPower
            // A transient failed read must not permanently disable already-authorized controls.
            let ready = !preview && (power?.canControlSleep() == true || power?.canControlSleep() == true)
            DispatchQueue.main.async {
                self.permissionReady = ready; self.busy = false
                self.restorePower(system: wantedSystem, display: wantedDisplay)
            }
        }
        engine.start(); render(); showWindow()
    }
    func restorePower(system: Bool, display: Bool) {
        guard !busy, !handlingTermination, permissionReady == true else { render(); return }
        busy = true
        engine.restoreTimers { [weak self] recovered in DispatchQueue.main.async {
            guard let self else { return }
            if recovered || !(system || display) { self.busy = false; self.render() }
            else { self.performPower(display ? "all-on" : "sleep-on") }
        } }
    }
    func writeState(_ state: LiveState) {
        diagnostics.snapshot(state)
        diagnostics.record(.powerState, DiagnosticFacts(sleepWanted: state.systemWanted, sleepActual: state.systemActual,
                             displayWanted: state.displayWanted, displayActual: state.displayActual, issue: state.error == nil ? nil : .commandFailed))
    }
    func render() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.render() }; return }
        guard window != nil, item != nil else { return }
        let summary = PowerPresentation.make(systemWanted: current.systemWanted, systemActual: current.systemActual,
            displayWanted: current.displayWanted, displayActual: current.displayActual, permissionReady: permissionReady,
            busy: busy, hasError: setupError != nil || current.error != nil,
            lockEnabled: lockController.state.enabled, lockRecovery: lockController.state.recovery,
            lockIssue: lockController.state.issue?.localizedDescription)
        InterfaceMotion.text(summaryLabel, summary.title); InterfaceMotion.text(summaryDetail, summary.detail)
        summaryIcon.update(summary)
        let anyOwned = current.systemWanted || current.displayWanted || lockController.state.enabled || lockController.requiresRestoration
        allButton.title = aggregateTitle(system: current.systemWanted || lockController.state.enabled || lockController.requiresRestoration, display: current.displayWanted)
        allButton.isEnabled = !busy && (anyOwned || (permissionReady == true && lockController.state.ready))
        item.menu?.item(withTag: 5)?.title = allButton.title; item.menu?.item(withTag: 5)?.isEnabled = allButton.isEnabled
        InterfaceMotion.set(sleepSwitch, on: current.systemWanted)
        InterfaceMotion.set(displaySwitch, on: current.displayWanted)
        sleepSwitch.isEnabled = !busy && (current.systemWanted || permissionReady == true)
        displaySwitch.isEnabled = !busy && (current.displayWanted || permissionReady == true)
        sleepSwitch.toolTip = "Для долгих загрузок и расчётов; экран может гаснуть"
        displaySwitch.toolTip = "Для презентаций и чтения; защита сна включится автоматически"
        let lock = lockController.state
        InterfaceMotion.set(lockSwitch, on: lock.enabled)
        lockSwitch.toolTip = "Чтобы нейронка могла управлять интерфейсом без автоблокировки"
        lockSwitch.isEnabled = !busy && lock.ready
        restoreLockButton.isHidden = !lockController.requiresRestoration
        restoreLockButton.isEnabled = !busy
        InterfaceMotion.text(lockState, lock.issue?.localizedDescription ?? (lock.recovery ? "Исходная настройка сохранена. Доступно восстановление." :
            lock.enabled ? "Автоблокировка отключена. Ручная блокировка доступна." :
            lock.policy.map { "Блокировка macOS: \($0.description)" } ?? "Проверяю настройку автоблокировки…"))
        lockState.textColor = lock.issue == nil ? .secondaryLabelColor : .systemRed
        setupRow.isHidden = permissionReady == true; setupLabel.isHidden = setupRow.isHidden; setupButton.isHidden = setupRow.isHidden
        setupButton.isEnabled = permissionReady == false && !busy
        setupLabel.stringValue = permissionReady == nil ? "Проверяю готовность NoSleep…" : "Один раз разрешите NoSleep управлять защитой сна. Подтверждение macOS запрашивается только при настройке."
        var sleepText = current.systemWanted ? (current.systemActual ? "Защита сна работает" : "Не удалось подтвердить защиту сна") : (current.systemActual ? "Сон запрещён другой настройкой macOS" : "Выключено: сон разрешён")
        var displayText = current.displayWanted ? (current.displayActual ? "Экран остаётся включённым" : "Не удалось подтвердить защиту экрана") : "Выключено: обычный режим экрана"
        if let pending = pendingPowerAction {
            if ["sleep-on", "display-on", "all-on"].contains(pending) { sleepText = "Включаю защиту сна…" }
            if ["sleep-off", "all-off"].contains(pending) { sleepText = "Возвращаю обычный режим сна…" }
            if ["display-on", "all-on"].contains(pending) { displayText = "Включаю защиту экрана…" }
            if ["display-off", "sleep-off", "all-off"].contains(pending) { displayText = "Возвращаю обычный режим экрана…" }
        }
        for (feature, button) in [(TimedFeature.system, sleepDurationButton!), (.display, displayDurationButton!)] {
            button.isEnabled = !busy && permissionReady == true
            if let remaining = timedState.remaining[feature] {
                button.title = "◷ " + DurationHistory.label(max(1, (remaining + 59) / 60))
                let end = Date().addingTimeInterval(Double(remaining)).formatted(date: .omitted, time: .shortened)
                let returned = timedState.returns[feature] == true ? "останется включено" : "обычный режим"
                let detail = timedState.failed ? "Не удалось завершить таймер. Повторите восстановление." : "До \(end) · затем: \(returned)"
                let confirmed = feature == .system ? current.systemActual : current.displayActual && current.systemActual
                if feature == .system { sleepText = pendingPowerAction == nil && confirmed ? detail : sleepText + "\n" + detail }
                else { displayText = pendingPowerAction == nil && confirmed ? detail : displayText + "\n" + detail }
                button.toolTip = "Изменить время. Осталось \(remaining) с; затем: \(returned)."
            } else { button.title = "∞"; button.toolTip = "Включить на время или без таймера" }
        }
        if timedState.remaining[.system] == nil, timedState.remaining[.display] != nil, timedState.returns[.system] == false {
            if current.systemActual && pendingPowerAction == nil { sleepText = "Нужен для экрана · затем обычный режим" }
        }
        // Commit final text once: unchanged countdown labels must not restart motion.
        InterfaceMotion.text(sleepState, sleepText); InterfaceMotion.text(displayState, displayText)
        sleepState.textColor = pendingPowerAction == nil && current.systemWanted && !current.systemActual ? .systemRed : .secondaryLabelColor
        displayState.textColor = pendingPowerAction == nil && current.displayWanted && !current.displayActual ? .systemRed : .secondaryLabelColor
        InterfaceMotion.text(errorLabel, setupError ?? (permissionReady == false && current.error != nil ? "Для защиты сна нажмите «Настроить NoSleep»." : current.error.map { "Не выполнено: \($0)" } ?? ""))
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        exportButton.isEnabled = !exporting
        if let menu = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "Управление" })?.submenu {
            for (tag, control) in [(22, sleepSwitch!), (23, displaySwitch!), (24, lockSwitch!)] {
                menu.item(withTag: tag)?.state = control.state; menu.item(withTag: tag)?.isEnabled = control.isEnabled
            }
            menu.item(withTag: 25)?.title = allButton.title; menu.item(withTag: 25)?.isEnabled = allButton.isEnabled
            menu.item(withTag: 27)?.isEnabled = !exporting
        }
        item.button?.image = NoSleepBrand.menuIcon
        item.button?.title = lock.issue != nil || lock.recovery ? " !" : lock.enabled && current.statusTitle == " OFF" ? " Блокировка" : current.statusTitle
        item.button?.toolTip = "NoSleep · Сон: \(current.systemActual ? "запрещён" : "разрешён") · Экран: \(current.displayActual ? "не гаснет" : "обычный режим") · Автоблокировка: \(lock.enabled ? "отключена" : "по настройке macOS")"
        item.menu?.item(withTag: 2)?.state = sleepSwitch.state; item.menu?.item(withTag: 2)?.isEnabled = sleepSwitch.isEnabled
        item.menu?.item(withTag: 3)?.state = displaySwitch.state; item.menu?.item(withTag: 3)?.isEnabled = displaySwitch.isEnabled
        item.menu?.item(withTag: 4)?.state = lockSwitch.state; item.menu?.item(withTag: 4)?.isEnabled = lockSwitch.isEnabled
        writeUI()
    }
    func perform(_ command: String) {
        guard !busy, !handlingTermination else { return }
        guard ["sleep-on", "sleep-off", "display-on", "display-off", "all-on", "all-off", "lock-on", "lock-off"].contains(command) else { return }
        if ["sleep-on", "display-on", "all-on"].contains(command), permissionReady != true {
            setupError = "Для защиты сна и экрана сначала настройте NoSleep."; render(); return
        }
        if command == "all-on", !lockController.state.ready { render(); return }
        if command.hasPrefix("lock-") || command.hasPrefix("all-") {
            busy = true; render()
            changeAutomaticLock(enabled: command.hasSuffix("-on")) { [weak self] success in
                guard let self else { return }
                if success && command.hasPrefix("all-") { self.performPower(command) }
                else { self.busy = false; self.render() }
            }
            return
        }
        busy = true; performPower(command)
    }
    func performPower(_ command: String) {
        diagnostics.record(.powerAction, DiagnosticFacts(number: ["sleep-on", "sleep-off", "display-on", "display-off", "all-on", "all-off"].firstIndex(of: command)))
        pendingPowerAction = command
        render(); engine.act(command) { [weak self] in DispatchQueue.main.async {
            self?.pendingPowerAction = nil; self?.busy = false; self?.render()
        } }
    }
    func startAutomaticLock() {
        lockController.changed = { [weak self] _ in self?.render() }
        lockController.load()
    }
    func automaticLockPasswordAlert(_ plan: ScreenLockPlan) -> (NSAlert, NSSecureTextField) {
        let alert = NSAlert(); alert.messageText = plan.enabled ? "Отключить автоблокировку?" : "Восстановить автоблокировку?"
        alert.informativeText = "NoSleep изменит системную настройку: \(plan.target?.description ?? "исходное значение"). Введите пароль текущего пользователя Mac. Пароль не сохраняется. При следующем изменении macOS запросит его снова."
        alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Пароль пользователя Mac"; field.setAccessibilityLabel("Пароль пользователя Mac")
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        return (alert, field)
    }
    func changeAutomaticLock(enabled: Bool, completion: @escaping (Bool) -> Void) {
        lockController.prepare(enabled: enabled) { [weak self] result in
            guard let self else { return }
            guard case let .success(plan) = result else { completion(false); return }
            let apply: (ScreenLockSecret?) -> Void = { [weak self] secret in
                guard let self else { secret?.erase(); return }
                if plan.needsPassword && secret == nil {
                    self.lockController.cancel(plan) { completion(false) }
                } else { self.lockController.apply(plan, secret: secret, completion: completion) }
            }
            if !plan.needsPassword { apply(nil) }
            else if let prompt = self.lockPasswordPrompt { prompt(plan, apply) }
            else {
                let (alert, field) = self.automaticLockPasswordAlert(plan)
                self.showWindow()
                alert.beginSheetModal(for: self.window) { response in
                    let secret = response == .alertFirstButtonReturn ? try? ScreenLockSecret(field.stringValue) : nil
                    field.stringValue = ""; apply(secret)
                }
            }
        }
    }
    @objc func setupPower() {
        guard !busy, !handlingTermination else { return }; setupError = nil; busy = true; render()
        do {
            let power = engine.protection.power as! MacPower
            if !power.canControlSleep() {
                let plan = try PowerSetupPlan(account: NSUserName(), uid: getuid())
                try plan.execute { source in
                    var failure: NSDictionary?
                    guard let script = NSAppleScript(source: source) else { throw PowerError(message: "Не удалось подготовить настройку.") }
                    script.executeAndReturnError(&failure)
                    if let failure = failure {
                        if (failure[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -128 { throw PowerError(message: "Настройка отменена. Повторите её, когда будете готовы.") }
                        throw PowerError(message: "macOS не разрешила завершить настройку. Нужен пароль администратора. Если Mac рабочий, обратитесь к его администратору.")
                    }
                }
            }
            guard power.canControlSleep() else { throw PowerError(message: "Настройка не подтвердилась. Обратитесь к администратору этого Mac.") }
            finishPowerSetup()
        } catch {
            setupError = error.localizedDescription; busy = false; render()
            let message = error.localizedDescription; engine.queue.async { var state = self.engine.state(); state.error = message; self.writeState(state) }
        }
    }
    func finishPowerSetup() {
        setupError = nil; permissionReady = true; busy = false
        restorePower(system: true, display: UserDefaults.standard.bool(forKey: "KeepDisplayAwake"))
    }
    @objc func toggleSleep() { perform(current.systemWanted ? "sleep-off" : "sleep-on") }
    @objc func toggleDisplay() { perform(current.displayWanted ? "display-off" : "display-on") }
    @objc func toggleLock() { perform(lockController.state.enabled ? "lock-off" : "lock-on") }
    @objc func restoreAutomaticLock() { perform("lock-off") }
    @objc func toggleAll() { perform(current.systemWanted || current.displayWanted || lockController.requiresRestoration ? "all-off" : "all-on") }
    @objc func showSleepDuration() { showDuration(.system, from: sleepDurationButton) }
    @objc func showDisplayDuration() { showDuration(.display, from: displayDurationButton) }
    func showDuration(_ feature: TimedFeature, from button: NSButton) {
        guard !busy, !handlingTermination, permissionReady == true else { return }
        durationPopover?.close()
        let history = durationHistory
        let controller = DurationPopover(feature: feature, history: history)
        let baseline = timedState.returns[feature] ?? (feature == .system ? current.systemWanted : current.displayWanted)
        controller.afterText = baseline ? "Защита останется включённой, как до таймера." : "Вернётся обычный режим macOS."
        if feature == .system { controller.afterText += " Если сон нужен экрану, он останется защищённым." }
        controller.running = timedState.remaining[feature] != nil; controller.failed = timedState.failed
        let popover = NSPopover(); popover.behavior = .transient
        popover.animates = InterfaceMotion.popoverAnimates(visible: window.isVisible, active: NSApp.isActive, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        popover.contentViewController = controller; durationPopover = popover
        controller.start = { [weak self, weak popover] minutes, done in
            guard let self, !self.busy, !self.handlingTermination, self.permissionReady == true else { done(false); return }
            self.busy = true; self.render()
            self.engine.startTimed(feature, minutes: minutes) { success in DispatchQueue.main.async {
                self.busy = false; self.render(); done(success); if success { popover?.close() }
            } }
        }
        controller.finish = { [weak self, weak popover] in
            guard let self, !self.busy, !self.handlingTermination else { return }
            self.busy = true; self.render()
            self.engine.finishTimed(feature) { DispatchQueue.main.async { self.busy = false; self.render(); popover?.close() } }
        }
        controller.indefinite = { [weak self, weak popover] in
            guard let self, !self.busy, !self.handlingTermination else { return }
            if self.timedState.remaining[feature] == nil { self.perform(feature == .system ? "sleep-on" : "display-on"); popover?.close(); return }
            self.busy = true; self.render()
            self.engine.finishTimed(feature, indefinite: true) { DispatchQueue.main.async { self.busy = false; self.render(); popover?.close() } }
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
    func protectionHelpController() -> NSViewController {
        let controller = NSViewController()
        let content = NSView(); controller.view = content
        let rows: [NSView] = [
            uiLabel("Когда включать защиту", size: 14, weight: .semibold),
            uiLabel("Загрузка или расчёт", weight: .semibold),
            uiLabel("Включите «Mac не засыпает». Экран может гаснуть.", secondary: true),
            uiLabel("Презентация или чтение", weight: .semibold),
            uiLabel("Включите «Экран не гаснет». Защита сна включится сама.", secondary: true),
            uiLabel("Нейронка работает с интерфейсом", weight: .semibold),
            uiLabel("Включите защиту сна и отключите автоблокировку.", secondary: true),
            uiLabel("Автоблокировка меняется с паролем. Ручная блокировка доступна.", size: 11, secondary: true)
        ]
        let details = NSButton(title: "О восстановлении настройки…", target: self, action: #selector(showLockDetails))
        details.bezelStyle = .rounded; details.controlSize = .small
        details.setAccessibilityLabel("Подробнее о восстановлении автоблокировки")
        let stack = NSStackView(views: rows + [details]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([content.widthAnchor.constraint(equalToConstant: 350),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        for index in [0, 2, 4, 6] { stack.setCustomSpacing(12, after: rows[index]) }
        content.layoutSubtreeIfNeeded()
        controller.preferredContentSize = NSSize(width: 350, height: stack.fittingSize.height + 32)
        return controller
    }
    var helpAnimates: Bool {
        InterfaceMotion.popoverAnimates(visible: window?.isVisible == true, active: NSApplication.shared.isActive,
                                       reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    func closeHelp() {
        helpPopover?.animates = helpAnimates
        helpPopover?.performClose(nil)
    }
    @objc func showLockHelp() {
        if helpPopover?.isShown == true { closeHelp(); return }
        showWindow()
        let popover = helpPopover ?? NSPopover()
        popover.behavior = .transient
        popover.animates = helpAnimates
        popover.contentViewController = protectionHelpController()
        helpPopover = popover
        popover.show(relativeTo: lockHelpButton.bounds, of: lockHelpButton, preferredEdge: .maxX)
    }
    @objc func showLockDetails() {
        closeHelp()
        let alert = NSAlert(); alert.messageText = "Сон, экран и блокировка"
        alert.informativeText = "Защита экрана автоматически включает защиту сна. Выключение защиты сна выключает и защиту экрана; выключение экрана оставляет защиту сна. Можно запретить сон, разрешить экрану гаснуть и отдельно отключить автоблокировку. Блокировка может остановить управление интерфейсом нейронкой. Ручная блокировка остаётся доступна.\n\nГалочка автоблокировки изменяет системную настройку. NoSleep сохраняет исходную задержку и восстанавливает её при выключении галочки и обычном выходе с подтверждением паролем. После аварийного завершения настройка может остаться изменённой; при следующем запуске будет доступно восстановление."
        alert.beginSheetModal(for: window)
    }
    @objc func showHelp() {
        let alert = NSAlert(); alert.messageText = "Как работает NoSleep"
        alert.informativeText = "Защита экрана включает защиту сна. Выключение защиты сна выключает обе галочки; выключение экрана сохраняет защиту сна. Для обеих функций нужна первоначальная настройка NoSleep. Автоблокировка управляется отдельно; для её изменения нужен пароль текущего пользователя Mac, он не сохраняется. Отчёт сохраняется вручную и не содержит секретов. Закрытие окна оставляет NoSleep работать в фоне."
        alert.beginSheetModal(for: window)
    }
    @objc func exportDiagnostics() {
        guard !exporting else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = "NoSleep-diagnostics.zip"
        panel.title = "Сохранить диагностику без секретов"; panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] result in if result == .OK, let url = panel.url { self?.saveDiagnostics(to: url) } }
    }
    func saveDiagnostics(to url: URL) {
        guard !exporting else { return }; exporting = true; render()
        let permission = permissionReady == true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }; let failed: Bool
            do { try self.diagnostics.export(to: url, permissionReady: permission); failed = false } catch { failed = true }
            DispatchQueue.main.async {
                self.exporting = false; self.render()
                if failed {
                    let alert = NSAlert(); alert.messageText = "Не удалось сохранить диагностику"
                    alert.informativeText = "Выберите доступную папку и повторите. Защита сна продолжает работать."; alert.beginSheetModal(for: self.window)
                } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); writeUI() }
    func windowWillClose(_ notification: Notification) { DispatchQueue.main.async { self.writeUI() } }
    @objc func quitApp() {
        guard !handlingTermination, !quitScheduled else { return }
        quitScheduled = true
        scheduleQuit()
    }
    private func scheduleQuit() {
        // A cancelled AppKit termination must unwind before a fresh request begins.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self, !self.quitInProgress else { return }
            self.quitScheduled = false; self.quitInProgress = true
            NSApplication.shared.terminate(nil)
            self.quitInProgress = false
            if self.quitScheduled { self.scheduleQuit() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationCompletion = { sender.reply(toApplicationShouldTerminate: $0) }
        return terminationReply(for: NSAppleEventManager.shared().currentAppleEvent) { request in
            sender.activate(ignoringOtherApps: true)
            return runSystemTerminationConfirmation(request.confirmationAlert())
        }
    }
    func terminationReply(for event: NSAppleEventDescriptor?, confirm: (SystemTerminationRequest) -> Bool) -> NSApplication.TerminateReply {
        // runModal processes UI events: another quit must not bypass the pending decision.
        guard !handlingTermination else { return .terminateCancel }
        handlingTermination = true
        if let request = SystemTerminationRequest(event: event), !confirm(request) { handlingTermination = false; return .terminateCancel }
        guard !busy else { handlingTermination = false; return .terminateCancel }
        if !lockController.state.ready || lockController.requiresRestoration {
            busy = true; render()
            changeAutomaticLock(enabled: false) { [weak self] success in
                guard let self else { return }
                let allowed = success && self.finishTermination() == .terminateNow
                self.busy = false; self.handlingTermination = false; self.render()
                self.terminationCompletion?(allowed)
            }
            return .terminateLater
        }
        defer { handlingTermination = false }
        return finishTermination()
    }
    func finishTermination() -> NSApplication.TerminateReply {
        do {
            try engine.shutdownNow()
            diagnostics.record(.shutdown); diagnostics.flush(); return .terminateNow
        } catch {
            errorLabel.stringValue = "Не удалось снять защиту: \(error.localizedDescription)"
            errorLabel.isHidden = false; showWindow()
            return .terminateCancel
        }
    }
}

final class FlippedContentView: NSView { override var isFlipped: Bool { true } }

final class FittingScrollView: NSScrollView {
    var documentWidth: NSLayoutConstraint?
    override func tile() {
        super.tile()
        // NSScrollView tiles legacy scrollers by changing its clip frame directly.
        // A clip-view width anchor can retain the previous autoresizing width.
        if let width = documentWidth, width.constant != contentView.bounds.width {
            width.constant = contentView.bounds.width
        }
        if let document = documentView, document.frame.width != contentView.bounds.width {
            document.setFrameSize(NSSize(width: contentView.bounds.width, height: document.frame.height))
        }
    }
}

@main enum NoSleepMain {
static func main() {
do {
    if CommandLine.arguments.contains("--self-test") {
        try selfTest()
        try backgroundTest()
        try setupTests()
        try featureTests()
        try uiTests()
        try brandTests()
        try presentationTests()
        try terminationTests()
        try automaticLockTests()
        try timedProtectionTests()
    } else if let index = CommandLine.arguments.firstIndex(of: "--command"), index + 1 < CommandLine.arguments.count {
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("local.robert.NoSleep.command"), object: nil, userInfo: ["command": CommandLine.arguments[index + 1]], deliverImmediately: true)
    } else if CommandLine.arguments.contains("--verify-setup-script") {
        let plan = try PowerSetupPlan(account: NSUserName(), uid: getuid())
        try plan.execute { source in
            var failure: NSDictionary?
            guard let script = NSAppleScript(source: source), script.compileAndReturnError(&failure) else {
                throw PowerError(message: "Setup script did not compile")
            }
            print("PASS: native first-run AppleScript compiles without executing admin changes")
        }
    } else if CommandLine.arguments.contains("--verify-display") {
        let power = MacPower()
        let control = Protection(power)
        defer {
            do { try control.shutdown() }
            catch { fputs("ERROR: display verification cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
        try control.setDisplay(true)
        guard power.displayHeld() else { throw PowerError(message: "Missing real display assertion") }
        print("ON: macOS confirms display assertion Level=1")
        Thread.sleep(forTimeInterval: 2)
        try control.setDisplay(false)
        guard !power.displayHeld() else { throw PowerError(message: "Display assertion not released") }
        print("OFF: display assertion released")
        try control.setDisplay(true)
        try control.shutdown()
        guard !power.displayHeld() else { throw PowerError(message: "Display assertion survived shutdown") }
        print("PASS: real display on/off and quit cleanup")
    } else if CommandLine.arguments.contains("--verify-real") {
        let control = Protection(MacPower())
        defer { try? control.disable() }
        for n in 1...2 {
            try control.enable()
            print("ON \(n): SleepDisabled=1, idle assertion held")
            try control.disable()
            print("OFF \(n): SleepDisabled=0, idle assertion released")
        }
        try control.enable()
        try control.power.setBlocked(false)
        try control.refresh()
        guard try control.power.blocked() else { throw PowerError(message: "Reset recovery failed") }
        print("PASS: external setting reset restored; leaving protection OFF")
    } else {
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != getpid() }) {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("local.robert.NoSleep.command"), object: nil, userInfo: ["command": "show"], deliverImmediately: true)
            existing.activate(options: [])
            return
        }
        if CommandLine.arguments.contains("--keep-display-awake") {
            UserDefaults.standard.set(true, forKey: "KeepDisplayAwake")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = MenuApp()
        app.delegate = delegate
        app.run()
    }
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}

}
}
