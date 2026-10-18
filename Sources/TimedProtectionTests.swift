import Foundation

func timedProtectionTests() throws {
    let name = "NoSleep.TimedTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let history = DurationHistory(defaults: defaults)
    assert(history.values(.system).isEmpty && history.last(.system) == 60)
    history.remember(300, for: .system); history.remember(90, for: .display)
    assert(DurationHistory(defaults: defaults).values(.system) == [300], "Custom durations survive reconstruction")
    assert(history.values(.display) == [90] && history.last(.system) == 300, "Histories remain feature-scoped")
    history.remember(300, for: .system); history.remember(60, for: .system)
    assert(history.values(.system) == [300], "No duplicate custom or standard chips")
    for n in [61, 62, 63, 64, 65, 66] { history.remember(n, for: .system) }
    assert(history.values(.system) == [66,65,64,63,62], "Only five recent custom values survive")
    history.remember(64, for: .system)
    assert(history.values(.system) == [64,66,65,63,62], "Reuse moves a custom duration to the front")
    history.remove(64, for: .system); history.remove(64, for: .system)
    assert(history.values(.system) == [66,65,63,62] && history.last(.system) == 60, "Removal and retry are harmless")
    history.remember(0, for: .system); history.remember(10081, for: .system)
    assert(history.values(.system) == [66,65,63,62])
    defaults.set([true, -1, 1.5, "300", 10081, 300, 300, 60, 1, 10080], forKey: "TimedDuration.system")
    assert(history.values(.system) == [300,1,10080], "Malformed saved choices are not coerced")
    defaults.set(true, forKey: "TimedDuration.system.last"); assert(history.last(.system) == 60)
    defaults.set("300", forKey: "TimedDuration.system.last"); assert(history.last(.system) == 60)
    for (h,m,expected) in [("0","1",1), ("1","30",90), ("168","0",10080), ("0","0",nil),
                            ("-1","5",nil), ("1","60",nil), ("168","1",nil), ("","1",nil),
                            ("1.5","0",nil), ("99999999999999999999","0",nil), ("abc","0",nil)] {
        assert(DurationHistory.parse(hours: h, minutes: m) == expected)
    }
    assert(DurationHistory.label(1) == "1 мин" && DurationHistory.label(300) == "5 ч" && DurationHistory.label(90) == "1 ч 30 мин")

    let fake = FakePower(), engine = GuardEngine(fake, preferences: defaults)
    var now: TimeInterval = 0
    engine.timedNow = { now }
    func awaitAction(_ invoke: (@escaping () -> Void) -> Void) {
        let done = DispatchSemaphore(value: 0); invoke { done.signal() }
        assert(done.wait(timeout: .now() + 5) == .success, "Timed engine callback must complete")
    }
    func start(_ feature: TimedFeature, _ minutes: Int, succeeds: Bool = true) {
        awaitAction { done in engine.startTimed(feature, minutes: minutes) { result in assert(result == succeeds, "Timer \(feature) \(minutes): \(engine.state().error ?? "none")"); done() } }
    }
    func current() -> LiveState { engine.queue.sync { engine.state() } }
    func timing() -> TimedPowerSnapshot { engine.queue.sync { engine.timingState() } }
    func tick(_ time: TimeInterval) { engine.queue.sync { now = time; engine.tickTimed() } }
    let untouchedMarker = Data("keep-private-no-save-marker".utf8)
    defaults.set(untouchedMarker, forKey: "TimedPowerBaseline")
    awaitAction { engine.act("sleep-on", save: false, completed: $0) }
    awaitAction { engine.act("all-off", save: false, completed: $0) }
    assert(defaults.data(forKey: "TimedPowerBaseline") == untouchedMarker,
           "No-save fake-power actions cannot remove or change persisted recovery state")
    defaults.removeObject(forKey: "TimedPowerBaseline")
    start(.system, 0, succeeds: false)
    assert(!current().systemWanted && defaults.data(forKey: "TimedPowerBaseline") == nil)
    start(.system, 60); start(.display, 120)
    assert(current().systemActual && current().displayActual)
    assert(defaults.bool(forKey: "PreventSystemSleep") == false && defaults.bool(forKey: "KeepDisplayAwake") == false,
           "Temporary activation must persist baseline rather than temporary on state")
    history.remember(300, for: .display); history.remove(300, for: .display)
    assert(timing().remaining[.display] == 7200, "Deleting a chip cannot cancel a running timer")
    tick(3599.9); assert(timing().remaining[.system] == 1, "Do not finish before exact deadline")
    tick(3600); assert(timing().remaining[.system] == nil && current().systemActual && current().displayActual,
                       "Longer display session retains its prerequisite")
    tick(7200); assert(!current().systemWanted && !current().displayWanted)
    assert(defaults.data(forKey: "TimedPowerBaseline") == nil)
    tick(8000); assert(!current().systemActual, "Duplicate overdue evaluation is harmless")

    start(.display, 1); fake.reject = true
    tick(8060); assert(timing().failed && current().systemWanted, "Refused restoration remains owned and visible")
    tick(9000); assert(timing().failed, "An unsuccessful expiry is not presented as completion")
    fake.reject = false
    awaitAction { engine.finishTimed(.display, completed: $0) }
    assert(!current().systemWanted && !timing().failed, "Explicit restoration retry succeeds")
    awaitAction { engine.act("sleep-on", completed: $0) }
    start(.system, 1); tick(9060)
    assert(current().systemWanted && timing().remaining.isEmpty, "Already-on baseline is restored as on")
    fake.value = false; fake.reject = true
    start(.system, 1, succeeds: false)
    assert(!current().systemActual && timing().remaining.isEmpty, "Lost system assertion cannot produce a confirmed timer")
    fake.reject = false; start(.system, 1)
    assert(current().systemActual, "Timed acquisition retries an externally lost assertion")
    start(.display, 1)
    awaitAction { engine.act("sleep-off", completed: $0) }
    tick(10000); assert(!current().systemWanted && timing().remaining.isEmpty, "Manual off cancels dependent timers")
    start(.system, 1); tick(10030); start(.system, 2); tick(10060)
    assert(current().systemWanted && timing().remaining[.system] == 90, "Replacing a timer does not replay its old deadline")
    awaitAction { engine.finishTimed(.system, indefinite: true, completed: $0) }
    tick(20000); assert(current().systemWanted && timing().remaining.isEmpty)
    awaitAction { engine.act("all-off", completed: $0) }
    fake.rejectDisplay = true; start(.display, 1, succeeds: false)
    assert(current().systemWanted && !current().displayWanted && timing().remaining.isEmpty,
           "Partial acquisition failure does not invent a running timer")
    fake.rejectDisplay = false; start(.display, 1); tick(20060)
    assert(!current().systemWanted, "Retry keeps the original baseline after partial acquisition")
    start(.system, 10080); assert(timing().remaining[.system] == 604800)
    try engine.shutdownNow()
    assert(defaults.data(forKey: "TimedPowerBaseline") == nil && !fake.value)

    // A new process restores baseline immediately instead of extending an old lease.
    defaults.set(try JSONEncoder().encode(PowerSelection(system: false, display: false)), forKey: "TimedPowerBaseline")
    fake.value = true
    let relaunched = GuardEngine(fake, preferences: defaults)
    awaitAction { done in relaunched.restoreTimers { recovered in assert(recovered); done() } }
    assert(!fake.value && defaults.data(forKey: "TimedPowerBaseline") == nil)
    defaults.set(Data("corrupt".utf8), forKey: "TimedPowerBaseline")
    awaitAction { done in relaunched.restoreTimers { recovered in assert(recovered); done() } }
    assert(relaunched.queue.sync { relaunched.state().error != nil }, "Corrupt recovery refuses automatic state change")
    awaitAction { relaunched.act("sleep-on", completed: $0) }
    assert(defaults.data(forKey: "TimedPowerBaseline") == nil, "Manual recovery retires the old marker")
    try relaunched.shutdownNow()
    // Exercise the actual existing DispatchSource watchdog while the caller/UI is blocked.
    let background = GuardEngine(FakePower(), preferences: defaults)
    var backgroundNow: TimeInterval = 0
    background.timedNow = { backgroundNow }
    awaitAction { done in background.startTimed(.system, minutes: 1) { success in assert(success); done() } }
    let expired = DispatchSemaphore(value: 0)
    background.queue.sync { backgroundNow = 60; background.changed = { if !$0.systemWanted { expired.signal() } } }
    background.start()
    assert(expired.wait(timeout: .now() + 4) == .success, "Native deadline enforcement survives a blocked UI thread")
    try background.shutdownNow()
    print("PASS: timed production engine, crossed deadlines, refusal/retry, baseline recovery, bounded persistent custom chips and invalid input")
}

func timedPersistencePhase(_ phase: String, suite: String) {
    let defaults = UserDefaults(suiteName: suite)!, history = DurationHistory(defaults: UserDefaults(suiteName: suite)!)
    if phase == "write" { history.remember(300, for: .display); history.remember(90, for: .system) }
    else if phase == "read-remove" {
        assert(history.values(.display) == [300] && history.values(.system) == [90] && history.last(.display) == 300,
               "Custom chips and last selection survive a real process restart")
        history.remove(300, for: .display)
    } else if phase == "verify-delete" {
        assert(history.values(.display).isEmpty && history.values(.system) == [90] && history.last(.display) == 60,
               "Chip deletion survives another real process restart and preserves other feature history")
    } else { defaults.removePersistentDomain(forName: suite) }
    assert(defaults.synchronize(), "Private preference phase must persist")
    print("PASS: separate-process duration phase \(phase)")
}
