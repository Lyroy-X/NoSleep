import AppKit
import CoreServices

func terminationTestEvent(reason: OSType? = nil, asParameter: Bool = false,
                          eventClass: AEEventClass = AEEventClass(kCoreEventClass),
                          eventID: AEEventID = AEEventID(kAEQuitApplication)) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID, targetDescriptor: nil,
                                      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    if let reason {
        let descriptor = NSAppleEventDescriptor(enumCode: reason)
        if asParameter { event.setParam(descriptor, forKeyword: AEKeyword(kAEQuitReason)) }
        else { event.setAttribute(descriptor, forKeyword: AEKeyword(kAEQuitReason)) }
    }
    return event
}

func terminationTests() throws {
    for asParameter in [false, true] {
        for reason in [kAEShutDown, kAEShowShutdownDialog] {
            assert(SystemTerminationRequest(event: terminationTestEvent(reason: OSType(reason), asParameter: asParameter)) == .shutdown)
        }
        for reason in [kAERestart, kAEShowRestartDialog] {
            assert(SystemTerminationRequest(event: terminationTestEvent(reason: OSType(reason), asParameter: asParameter)) == .restart)
        }
        for reason in [kAEReallyLogOut, kAELogOut, kAEQuitAll, 0, OSType.max] {
            assert(SystemTerminationRequest(event: terminationTestEvent(reason: reason, asParameter: asParameter)) == nil)
        }
    }
    assert(SystemTerminationRequest(event: nil) == nil)
    assert(SystemTerminationRequest(event: terminationTestEvent()) == nil)
    assert(SystemTerminationRequest(event: terminationTestEvent(reason: OSType(kAEShutDown), eventID: AEEventID(kAEOpenApplication))) == nil)
    assert(SystemTerminationRequest(event: terminationTestEvent(reason: OSType(kAEShutDown), eventClass: 0)) == nil)
    let malformed = terminationTestEvent()
    malformed.setAttribute(NSAppleEventDescriptor(string: "invalid"), forKeyword: AEKeyword(kAEQuitReason))
    assert(SystemTerminationRequest(event: malformed) == nil)
    print("PASS: system quit reasons, attribute/parameter encoding, ordinary quit/logout, missing/unknown/malformed events")

    let power = FakePower(), engine = GuardEngine(FakePower())
    let failingEngine = GuardEngine(power)
    // Use the real cleanup and watchdog with fake power only; no persisted preferences.
    for candidate in [engine, failingEngine] {
        let done = DispatchSemaphore(value: 0)
        candidate.act("all-on", save: false) { done.signal() }
        assert(done.wait(timeout: .now() + 3) == .success)
    }
    try engine.shutdownNow()
    let stopped = engine.queue.sync { engine.state() }
    assert(!stopped.systemWanted && !stopped.displayWanted && engine.timer == nil)
    failingEngine.queue.sync { power.reject = true }
    do { try failingEngine.shutdownNow(); fatalError("Cleanup failure was hidden") } catch {}
    let retained = failingEngine.queue.sync { failingEngine.state() }
    assert(retained.systemWanted && retained.displayWanted && power.idle && power.display && failingEngine.timer != nil)
    failingEngine.queue.sync { power.reject = false }
    try failingEngine.shutdownNow()
    assert(!power.value && !power.idle && !power.display && failingEngine.timer == nil)
    print("PASS: confirmed cleanup releases both protections; failure retains protections and restarts guard; retry succeeds")
}
