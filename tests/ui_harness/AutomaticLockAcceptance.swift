import AppKit
import CoreServices

func spinUntil(_ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    require(condition(), "asynchronous fixture reached expected state")
}

func automaticLockUIAcceptance(_ owner: MenuApp, _ app: NSApplication,
                               _ backend: TestScreenLockBackend, _ store: TestScreenLockStore) throws {
    owner.permissionReady = true
    func perform(_ command: String) { owner.perform(command); spinUntil { !owner.busy } }
    var prompts = 0
    owner.lockPasswordPrompt = { _, done in prompts += 1; done(nil) }
    let commands = owner.engine.fixtureCommands.count
    perform("all-on")
    require(prompts == 1 && owner.engine.fixtureCommands.count == commands && store.value == nil,
            "cancelled combined password prompt starts no power action and captures no journal")
    require(owner.lockSwitch.state == .off && owner.lockSwitch.isEnabled, "cancel retains checkbox and permits retry")
    var pending: ((ScreenLockSecret?) -> Void)?
    var capturedPlan: ScreenLockPlan?
    owner.lockPasswordPrompt = { plan, done in prompts += 1; capturedPlan = plan; pending = done }
    owner.toggleLock(); spinUntil { pending != nil }
    let (alert, field) = owner.automaticLockPasswordAlert(capturedPlan!)
    require(alert.accessoryView === field && field.stringValue.isEmpty,
            "native password accessory is an empty secure field")
    require(alert.informativeText.contains("не сохраняется") && alert.informativeText.contains("снова"),
            "prompt explains password lifetime and repeated system authentication")
    let promptCount = prompts
    owner.toggleLock(); owner.perform("all-on"); owner.toggleDisplay()
    require(prompts == promptCount && owner.engine.fixtureCommands.count == commands && !owner.displaySwitch.isEnabled,
            "pending authentication serializes duplicate, combined and independent actions")
    require(owner.terminationReply(for: nil) { _ in false } == .terminateCancel,
            "quit cannot bypass an unfinished password decision")
    backend.rejectWrite = true
    pending?(try ScreenLockSecret("incorrect-fixture")); pending = nil
    spinUntil { !owner.busy }
    require(owner.lockSwitch.state == .off && store.value == nil && owner.lockState.stringValue.contains("macOS"),
            "wrong password preserves unchecked state and displays safe refusal")
    backend.rejectWrite = false
    owner.lockPasswordPrompt = { _, done in prompts += 1; done(try! ScreenLockSecret("fixture")) }
    let powerBefore = owner.engine.fixtureCommands.count
    perform("lock-on")
    require(owner.lockSwitch.state == .on && backend.value == .off && store.value?.delay == 120 &&
            owner.engine.fixtureCommands.count == powerBefore && owner.item.button?.title == " Блокировка",
            "lock-only retry preserves power and indicates active policy in the menu bar")
    require(!owner.restoreLockButton.isHidden, "managed system policy exposes restoration action")
    require(owner.lockSwitch.accessibilityLabel() == "Не блокировать автоматически" && owner.summaryLabel.stringValue == "Автоблокировка отключена",
            "lock-only mode has an accessible control and an accurate compact headline")
    let lockSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: UIHarnessEnvironment.dataDirectory.appendingPathComponent("ui.json"))) as! [String: Any]
    require(lockSnapshot["statusTitle"] as? String == " Блокировка", "UI snapshot matches the actual lock-only menu title")
    let beforeNoop = prompts
    perform("lock-on")
    require(prompts == beforeNoop, "already applied target does not ask for unnecessary password")
    owner.lockPasswordPrompt = { _, done in done(nil) }
    perform("all-off")
    require(owner.lockSwitch.state == .on && owner.engine.fixtureCommands.count == powerBefore,
            "cancelled restoration retains active checkbox and does not start combined power change")
    owner.lockPasswordPrompt = { _, done in prompts += 1; done(try! ScreenLockSecret("fixture")) }
    perform("lock-off")
    require(owner.lockSwitch.state == .off && backend.value.delay == 120 && store.value == nil,
            "second authenticated change restores exact initial delay")
    let menu = app.mainMenu!.items.first { $0.title == "Управление" }!.submenu!
    let lockItem = menu.item(withTag: 24)!
    require(app.sendAction(lockItem.action!, to: lockItem.target, from: lockItem), "application menu routes lock action")
    spinUntil { !owner.busy }
    require(owner.lockSwitch.state == .on && lockItem.state == .on, "menu and window share confirmed checkbox state")

    // Owned restoration delays quit, shutdown and restart until password and readback succeed.
    func event(_ reason: OSType) -> NSAppleEventDescriptor {
        let value = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        value.setAttribute(NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(kAEQuitReason)); return value
    }
    for reason in [nil, OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut)] as [OSType?] {
        if !owner.lockController.state.enabled { perform("lock-on") }
        var reply: Bool?
        owner.terminationCompletion = { reply = $0 }
        owner.lockPasswordPrompt = { _, done in pending = done }
        let shutdowns = owner.engine.fixtureShutdownCount
        require(owner.terminationReply(for: reason.map(event)) { _ in true } == .terminateLater,
                "owned policy defers termination until restoration")
        spinUntil { pending != nil }
        require(owner.engine.fixtureShutdownCount == shutdowns && owner.lockSwitch.state == .on,
                "deferred termination preserves all protection before authentication")
        require(owner.terminationReply(for: nil) { _ in true } == .terminateCancel,
                "second termination cannot bypass pending restoration")
        pending?(nil); pending = nil; spinUntil { reply != nil }
        require(reply == false && owner.lockSwitch.state == .on && owner.engine.fixtureShutdownCount == shutdowns,
                "cancelled quit restoration keeps app alive")
        reply = nil; backend.rejectWrite = true
        owner.lockPasswordPrompt = { _, done in done(try! ScreenLockSecret("incorrect")) }
        require(owner.terminationReply(for: reason.map(event)) { _ in true } == .terminateLater, "failed restore starts deferred route")
        spinUntil { reply != nil }
        require(reply == false && owner.engine.fixtureShutdownCount == shutdowns && store.value != nil,
                "refused quit restoration retains journal and prevents power cleanup")
        reply = nil; backend.rejectWrite = false
        owner.lockPasswordPrompt = { _, done in done(try! ScreenLockSecret("fixture")) }
        require(owner.terminationReply(for: reason.map(event)) { _ in true } == .terminateLater, "retry starts deferred restore")
        spinUntil { reply != nil }
        require(reply == true && backend.value.delay == 120 && store.value == nil && owner.engine.fixtureShutdownCount == shutdowns + 1,
                "successful restore precedes one final power cleanup")
    }
    // Relaunch only loads an existing restoration record; no unauthenticated reapplication.
    store.value = try ScreenLockPolicy(120); backend.value = .off
    let writesBeforeLaunch = backend.writes.count
    owner.lockController = AutomaticLockController(backend: backend, store: store)
    owner.startAutomaticLock(); spinUntil { owner.lockController.state.ready }
    require(owner.lockController.state.recovery && owner.lockSwitch.state == .on &&
            !owner.restoreLockButton.isHidden && backend.writes.count == writesBeforeLaunch,
            "startup offers interrupted-run recovery without changing policy")
    var recoveryReply: Bool?
    owner.terminationCompletion = { recoveryReply = $0 }
    owner.engine.fixtureRejectShutdown = true
    require(owner.terminationReply(for: nil) { _ in true } == .terminateLater, "recovery restores before power cleanup")
    spinUntil { recoveryReply != nil }
    require(recoveryReply == false && backend.value.delay == 120 && store.value == nil && owner.lockSwitch.state == .off,
            "later power cleanup failure preserves the confirmed policy restoration")
    owner.engine.fixtureRejectShutdown = false
    require(owner.terminationReply(for: nil) { _ in true } == .terminateNow,
            "power cleanup retries without another policy password after confirmed restoration")
    owner.terminationCompletion = nil
    owner.window.setContentSize(NSSize(width: 520, height: 620))
    owner.window.contentView!.layoutSubtreeIfNeeded()
    require(owner.lockSwitch.frame.width > 0 && owner.lockState.frame.width > 100,
            "third control and wrapped state have usable native layout")
    // AppKit intrinsic switch widths differ across supported macOS versions.
    // Exercise those native size variants without weakening the shared trailing edge.
    for size in [NSControl.ControlSize.regular, .small, .mini] {
        for control in [owner.sleepSwitch!, owner.displaySwitch!, owner.lockSwitch!] { control.controlSize = size }
        for width: CGFloat in [520, 600, 700] {
            owner.window.setContentSize(NSSize(width: width, height: 620))
            owner.window.contentView!.layoutSubtreeIfNeeded()
            let edges = [owner.sleepSwitch!, owner.displaySwitch!, owner.lockSwitch!].map {
                $0.convert($0.bounds, to: owner.window.contentView).maxX
            }
            print("LAYOUT: size=\(size.rawValue), width=\(width), edges=\(edges)")
            require(edges.max()! - edges.min()! < 2, "native size variants keep all switch trailing edges aligned")
        }
    }
    for control in [owner.sleepSwitch!, owner.displaySwitch!, owner.lockSwitch!] { control.controlSize = .regular }
    let displayEdge = owner.displaySwitch.convert(owner.displaySwitch.bounds, to: owner.window.contentView).maxX
    let lockEdge = owner.lockSwitch.convert(owner.lockSwitch.bounds, to: owner.window.contentView).maxX
    require(abs(displayEdge - lockEdge) < 2, "all three native switches share the trailing alignment")
    if let view = owner.window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: image)
        if let png = image.representation(using: .png, properties: [:]) {
            try png.write(to: UIHarnessEnvironment.output.appendingPathComponent("automatic-lock-ui.png"))
        }
    }
    let snapshot = try String(contentsOf: UIHarnessEnvironment.dataDirectory.appendingPathComponent("ui.json"), encoding: .utf8)
    require(!snapshot.contains("incorrect-fixture") && !snapshot.contains("fixture-only"), "UI snapshots contain no entered password")
    print("PASS: isolated lock UI, secure prompt, cancellation/refusal/retry, combined actions, serialization and deferred termination")
}
