import Foundation

private final class FakeLidPower: LidPowerControl {
    var supportsLid = true
    var blocked = false
    var refuse = false
    var ignore = false
    var writes: [Bool] = []
    func lidBlocked() throws -> Bool { blocked }
    func setLidBlocked(_ value: Bool) throws {
        writes.append(value)
        if refuse { throw PowerError(message: "Lid command denied") }
        if !ignore { blocked = value }
    }
}

func lidProtectionTests() throws {
    let suite = "NoSleep.LidTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let system = FakePower(), lid = FakeLidPower()
    let engine = GuardEngine(system, preferences: defaults, lidPower: lid)
    func act(_ command: String) -> LiveState {
        let done = DispatchSemaphore(value: 0)
        engine.act(command) { done.signal() }
        assert(done.wait(timeout: .now() + 3) == .success)
        return engine.queue.sync { engine.state() }
    }
    func restore() {
        let done = DispatchSemaphore(value: 0)
        engine.restoreTimers { _ in done.signal() }
        assert(done.wait(timeout: .now() + 3) == .success)
    }

    restore()
    assert(lid.writes.isEmpty && !defaults.bool(forKey: LidProtection.selectionKey), "Fresh launch defaults the lid control off")
    let display = act("display-on")
    assert(display.systemActual && display.displayActual && !display.lidActual && lid.writes.isEmpty,
           "Display and idle protection leave the closed-lid policy untouched")
    let both = act("lid-on")
    assert(both.lidActual && both.lidWanted && both.lidOwned && both.systemActual && both.displayActual)
    let lidOnly = act("sleep-off")
    assert(lidOnly.lidWanted && lidOnly.lidActual && !lidOnly.systemWanted && !lidOnly.displayWanted,
           "Disabling idle protection leaves independent lid protection on")
    let systemAgain = act("sleep-on")
    assert(systemAgain.lidActual && systemAgain.systemActual && !systemAgain.displayActual)
    let noLid = act("lid-off")
    assert(!noLid.lidWanted && !noLid.lidActual && !noLid.lidOwned && noLid.systemActual,
           "Disabling lid protection leaves idle protection on")
    assert(lid.writes == [true, false])
    assert(act("lid-off").lidError == nil && lid.writes == [true, false], "Repeated off is harmless")
    assert(act("all-on").lidActual && act("all-off").statusTitle == " OFF")

    lid.refuse = true
    let refused = act("lid-on")
    assert(!refused.lidActual && !refused.lidWanted && !refused.lidOwned && refused.lidError != nil)
    lid.refuse = false; lid.ignore = true
    let unconfirmed = act("lid-on")
    assert(!unconfirmed.lidActual && !unconfirmed.lidWanted && !unconfirmed.lidOwned && unconfirmed.lidError != nil)
    lid.ignore = false
    assert(act("lid-on").lidActual && defaults.bool(forKey: LidProtection.selectionKey))
    lid.refuse = true
    let blockedRestore = act("lid-off")
    assert(blockedRestore.lidActual && blockedRestore.lidWanted && blockedRestore.lidOwned && blockedRestore.lidError != nil)
    lid.refuse = false
    let restored = act("lid-off")
    assert(!restored.lidActual && !restored.lidOwned && restored.lidError == nil)

    lid.blocked = true
    let writesBefore = lid.writes
    let external = act("lid-on")
    assert(external.lidActual && !external.lidWanted && !external.lidOwned && external.lidError != nil)
    _ = act("all-off")
    try engine.shutdownNow()
    assert(lid.blocked && lid.writes == writesBefore, "NoSleep must not clear an override it did not set")
    lid.blocked = false
    lid.supportsLid = false
    assert(!act("all-on").lidAvailable && lid.writes == writesBefore)
    _ = act("all-off")
    lid.supportsLid = true

    defaults.set(true, forKey: "PreventSystemSleep")
    defaults.removeObject(forKey: LidProtection.selectionKey)
    restore()
    assert(lid.blocked && defaults.bool(forKey: LidProtection.selectionKey), "Legacy saved protection includes lid protection")
    try engine.shutdownNow()
    assert(!lid.blocked && defaults.bool(forKey: LidProtection.selectionKey), "Quit releases only the owned override and keeps the preference")
    restore()
    assert(lid.blocked, "Relaunch restores explicit lid selection")
    try engine.shutdownNow()

    // A previous process may have recorded ownership and failed before release.
    defaults.set(false, forKey: LidProtection.selectionKey)
    defaults.set(true, forKey: LidProtection.ownershipKey)
    lid.blocked = true
    restore()
    assert(!lid.blocked && !defaults.bool(forKey: LidProtection.ownershipKey), "Startup clears an owned stale override")
    print("PASS: independent lid protection, combinations, migration, ownership, refusal and retry")
}
