import AppKit

func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
func waitForUI(_ ready: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !ready() && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return ready()
}
func captureNative(_ view: NSView, _ name: String) throws {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
          !view.bounds.isEmpty else { throw PowerError(message: "Empty native snapshot") }
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }
    // CacheDisplay omits a transparent view's window material. Render its native
    // pixels onto the matching semantic window background for a legible preview.
    let image = NSImage(size: view.bounds.size)
    image.lockFocus()
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        let foreground = NSImage(size: view.bounds.size)
        foreground.addRepresentation(bitmap)
        foreground.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero,
                        operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    let composed = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try composed.representation(using: .png, properties: [:])!.write(to: UIHarnessEnvironment.output.appendingPathComponent(name + ".png"))
}
@main enum PrivateUIHarness {
    static func main() throws {
        setbuf(stdout, nil)
        defer { UIHarnessEnvironment.defaults.removePersistentDomain(forName: UIHarnessEnvironment.defaultsName) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let owner = MenuApp()
        let lockBackend = TestScreenLockBackend(try ScreenLockPolicy(120))
        let lockStore = TestScreenLockStore()
        owner.lockController = AutomaticLockController(backend: lockBackend, store: lockStore)
        owner.lockPasswordPrompt = { _, done in done(try! ScreenLockSecret("fixture-only")) }
        owner.buildWindow()
        owner.window.orderFront(nil)
        owner.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        owner.item.menu = owner.statusMenu()
        app.mainMenu = applicationMenu(target: owner)
        owner.permissionReady = true
        owner.engine.fixtureActionsAllowed = true
        owner.diagnostics.fixturePowerActionsAllowed = true
        owner.engine.changed = { owner.current = $0 }
        try FileManager.default.createDirectory(at: UIHarnessEnvironment.dataDirectory, withIntermediateDirectories: true)
        owner.render()
        owner.perform("all-on")
        require(!owner.busy && owner.engine.fixtureCommands.isEmpty && lockBackend.value.delay == 120,
                "unready combined enable starts no password or power action")
        owner.startAutomaticLock()
        spinUntil { owner.lockController.state.ready }
        try uiTests(runTerminationRegression: false)
        if !CommandLine.arguments.contains("--readiness-only") { try timedUIAcceptance() }
        let controls = walk(owner.window.contentView!).compactMap { $0 as? NSSwitch }
        require(controls.count == 3, "dependent power switches and separate automatic lock control")
        let labels = walk(owner.window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
        require(!labels.contains { $0.contains("VPN") || $0.contains("Cisco") }, "native window has no VPN status or settings")
        require(owner.window.toolbar != nil && owner.window.contentMinSize == NSSize(width: 520, height: 360), "compact minimum content size and native resizing preserved")
        require(owner.window.contentView!.bounds.size == NSSize(width: 600, height: 620), "fresh window has selected 600x620 content size")
        func drain() {
            require(waitForUI({ !owner.busy }), "action completion leaves controls available")
        }
        require(waitForUI({ true }, timeout: 0), "already completed UI needs no wait")
        owner.engine.deferCompletion = true
        owner.displaySwitch.performClick(nil)
        require(owner.busy && !waitForUI({ !owner.busy }, timeout: 0.02), "missing completion fails within bounded wait")
        let delayedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { owner.engine.completeForTesting() }
        drain()
        require(ProcessInfo.processInfo.systemUptime - delayedAt >= 0.25, "delayed completion beyond the old 150-ms deadline is observed")
        owner.engine.deferCompletion = false
        require(owner.summaryIcon.image != nil && owner.summaryIcon.symbolName == "moon.stars.fill",
                "window retains its status icon and confirmed summary")
        require(walk(owner.window.contentView!).compactMap { $0 as? NSImageView }.count >= 4,
                "summary and all three control symbols are present")
        let readinessOnly = CommandLine.arguments.contains("--readiness-only")

        require(owner.current.displayWanted && owner.current.systemWanted && owner.sleepSwitch.state == .on,
                "display switch selects its sleep prerequisite in the window")
        if !readinessOnly {
            owner.window.appearance = NSAppearance(named: .aqua)
            try captureNative(owner.window.contentView!, "after-display-on-light")
            owner.window.appearance = NSAppearance(named: .darkAqua)
            try captureNative(owner.window.contentView!, "after-display-on-dark")
        }
        let menu = app.mainMenu!.items.first { $0.title == "Управление" }!.submenu!
        let sleep = menu.item(withTag: 22)!
        require(app.sendAction(sleep.action!, to: sleep.target, from: sleep), "native menu routes sleep action")
        drain()
        require(!owner.current.systemWanted && !owner.current.displayWanted && owner.displaySwitch.state == .off,
                "sleep menu disables dependent display protection")
        owner.displaySwitch.performClick(nil); drain()
        owner.allButton.performClick(nil); drain()
        require(!owner.current.systemWanted && !owner.current.displayWanted && !owner.lockController.state.enabled && owner.allButton.title == "Включить всё", "combined action disables all three features")
        owner.allButton.performClick(nil); drain()
        require(owner.current.systemWanted && owner.current.displayWanted && owner.lockController.state.enabled && owner.allButton.title == "Выключить всё", "combined action enables all three features")
        owner.perform("all-off"); drain()
        owner.permissionReady = false; owner.render()
        require(!owner.sleepSwitch.isEnabled && !owner.displaySwitch.isEnabled && !owner.allButton.isEnabled && !owner.setupRow.isHidden,
                "first-run permission state disables both dependent protections and exposes setup")
        owner.item.menu!.update()
        require(owner.item.menu!.item(withTag: 2)?.isEnabled == false && owner.item.menu!.item(withTag: 3)?.isEnabled == false,
                "native menu validation preserves missing-permission guards")
        let noPermissionCommands = owner.engine.fixtureCommands.count
        let noPermissionPolicy = lockBackend.value
        owner.perform("sleep-on"); owner.perform("display-on"); owner.perform("all-on")
        require(owner.engine.fixtureCommands.count == noPermissionCommands && lockBackend.value == noPermissionPolicy &&
                owner.setupError != nil, "direct enable commands cannot bypass permission or start lock policy changes")
        owner.setupError = nil; owner.permissionReady = true
        owner.restorePower(system: false, display: true); drain()
        require(owner.current.systemWanted && owner.current.displayWanted && !owner.lockController.state.enabled,
                "startup normalizes legacy display-only preferences without enabling lock policy")
        owner.perform("all-off"); drain()
        UIHarnessEnvironment.defaults.set(true, forKey: "KeepDisplayAwake")
        owner.permissionReady = false; owner.busy = true
        owner.finishPowerSetup(); drain()
        require(owner.current.systemWanted && owner.current.displayWanted && owner.permissionReady == true,
                "completed setup retains saved display selection with its sleep prerequisite")
        UIHarnessEnvironment.defaults.removeObject(forKey: "KeepDisplayAwake")
        owner.displaySwitch.performClick(nil); drain()
        require(owner.current.systemWanted && !owner.current.displayWanted && owner.sleepSwitch.state == .on,
                "display-off preserves selected system protection")
        let displayMenu = owner.item.menu!.item(withTag: 3)!
        require(app.sendAction(displayMenu.action!, to: displayMenu.target, from: displayMenu), "status menu routes display action")
        drain()
        require(owner.item.menu!.item(withTag: 2)!.state == .on && displayMenu.state == .on &&
                owner.sleepSwitch.state == .on && owner.displaySwitch.state == .on,
                "status menu and window share both dependent selections")
        owner.perform("all-off"); drain()
        owner.permissionReady = nil; owner.render()
        require(!owner.displaySwitch.isEnabled && !owner.sleepSwitch.isEnabled && !owner.allButton.isEnabled,
                "readiness checking cannot expose a dependent enable action")
        let beforeRestore = owner.engine.fixtureCommands.count
        owner.restorePower(system: false, display: true)
        require(owner.engine.fixtureCommands.count == beforeRestore, "startup cannot bypass readiness")
        owner.permissionReady = true
        owner.busy = true
        let busyCommands = owner.engine.fixtureCommands.count
        owner.perform("display-on"); owner.perform("all-on")
        owner.restorePower(system: true, display: true)
        require(owner.engine.fixtureCommands.count == busyCommands, "busy startup and direct actions cannot overlap")
        owner.busy = false; owner.render()
        let snapshot = try Data(contentsOf: UIHarnessEnvironment.dataDirectory.appendingPathComponent("ui.json"))
        let fields = try JSONSerialization.jsonObject(with: snapshot) as! [String: Any]
        require(!fields.keys.contains { $0.lowercased().contains("vpn") || $0.lowercased().contains("recovery") || $0.lowercased().contains("observer") }, "UI snapshot contains only current app features")
        if readinessOnly {
            NSStatusBar.system.removeStatusItem(owner.item); owner.window.close()
            print("PASS: targeted readiness/dependency UI contracts; complete E2E runs separately")
            return
        }
        try compactNativeAcceptance(owner)
        owner.perform("all-off"); drain()
        let commandCount = owner.engine.fixtureCommands.count
        let help = owner.protectionHelpController()
        let helpLabels = walk(help.view).compactMap { ($0 as? NSTextField)?.stringValue }
        require(["Загрузка или расчёт", "Презентация или чтение", "Нейронка работает с интерфейсом"].allSatisfy(helpLabels.contains),
                "help describes three short use cases and matching protection combinations")
        require(help.preferredContentSize.width == 350 && help.preferredContentSize.height < 420,
                "contextual help stays compact")
        owner.window.appearance = NSAppearance(named: .aqua)
        owner.showWindow()
        owner.showLockHelp()
        require(owner.helpPopover?.isShown == true && owner.window.attachedSheet == nil && !owner.busy,
                "help opens a native nonmodal popover without blocking controls")
        require(owner.helpPopover?.animates == InterfaceMotion.popoverAnimates(visible: owner.window.isVisible,
                active: app.isActive, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
                "popover honors reduced motion and inactive-window fallback")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let shownHelp = owner.helpPopover!.contentViewController!
        shownHelp.view.appearance = NSAppearance(named: .aqua)
        shownHelp.view.needsDisplay = true; shownHelp.view.displayIfNeeded()
        try captureNative(shownHelp.view, "help-light")
        shownHelp.view.appearance = NSAppearance(named: .darkAqua)
        shownHelp.view.needsDisplay = true; shownHelp.view.displayIfNeeded()
        try captureNative(shownHelp.view, "help-dark")
        // A transient popover may dismiss during appearance/snapshot events.
        // Establish a known closed state, then test an immediate open/close pair.
        print("STATE: AppKit running=\(app.isRunning), active=\(app.isActive), help shown after snapshots=\(owner.helpPopover?.isShown == true)")
        owner.closeHelp()
        spinUntil { owner.helpPopover?.isShown == false }
        owner.showLockHelp()
        require(owner.helpPopover?.isShown == true, "fresh help open establishes repeated-action precondition")
        owner.showLockHelp()
        spinUntil { owner.helpPopover?.isShown == false }
        require(owner.helpPopover?.isShown == false && owner.engine.fixtureCommands.count == commandCount,
                "repeated help action closes the same popover without changing protections")
        owner.showLockHelp()
        let detailsButton = walk(owner.helpPopover!.contentViewController!.view).compactMap { $0 as? NSButton }.first!
        require(detailsButton.isEnabled && detailsButton.action == #selector(MenuApp.showLockDetails),
                "restoration details remain an enabled native help action")
        detailsButton.performClick(nil)
        spinUntil { owner.window.attachedSheet != nil && owner.helpPopover?.isShown == false }
        let detailSheet = owner.window.attachedSheet!
        let detailText = walk(detailSheet.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
        require(detailText.contains("После аварийного завершения") && detailText.contains("исходную задержку"),
                "separate details preserve original-policy restoration and crash-persistence disclosure")
        app.endSheet(detailSheet); detailSheet.orderOut(nil)
        spinUntil { owner.window.attachedSheet == nil }
        owner.window.orderFrontRegardless()
        owner.current = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)
        owner.render()
        let beforeSymbol = owner.summaryIcon.animationRevision
        owner.busy = false; owner.current = LiveState(systemWanted: true, systemActual: true, displayWanted: true, displayActual: true, error: nil)
        owner.render()
        require(owner.summaryIcon.symbolName == "moon.stars.fill" && owner.summaryLabel.stringValue == "Mac под защитой",
                "status icon and title show confirmed protection immediately")
        let iconRevision = owner.summaryIcon.animationRevision
        require(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || iconRevision > beforeSymbol, "native symbol replacement handles a visible status change")
        for _ in 0..<5 { owner.render() }
        require(owner.summaryIcon.animationRevision == iconRevision, "unchanged renders do not restart icon animation")
        owner.current.error = "Fixture refusal"; owner.render()
        require(owner.summaryIcon.symbolName == "exclamationmark.triangle", "refusal replaces success icon with a warning")
        owner.current.error = nil; owner.render()
        require(owner.summaryIcon.symbolName == "moon.stars.fill", "successful retry restores the active icon")
        try captureNative(owner.window.contentView!, "status-icon-active")
        owner.window.orderOut(nil)
        let hiddenRevision = owner.summaryIcon.animationRevision
        owner.current = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)
        owner.render()
        require(owner.summaryIcon.animationRevision == hiddenRevision, "hidden icon updates without animation")
        owner.window.orderFrontRegardless()
        // Exercise visible native motion, including fast reversal. State must be immediate.
        owner.window.makeKeyAndOrderFront(nil)
        let started = ProcessInfo.processInfo.systemUptime
        owner.engine.deferCompletion = true
        owner.perform("display-on")
        require(owner.busy && owner.sleepState.stringValue.contains("Включаю") && owner.displayState.stringValue.contains("Включаю"),
                "pending dependent enable has explicit progress without claiming confirmation")
        owner.engine.completeForTesting(); owner.engine.deferCompletion = false; drain()
        require(owner.sleepSwitch.state == .on && owner.displaySwitch.state == .on,
                "animated dependency commits both control states immediately")
        owner.perform("sleep-off"); drain()
        require(owner.sleepSwitch.state == .off && owner.displaySwitch.state == .off,
                "rapid native animation reversal retains latest confirmed state")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        require(owner.sleepState.alphaValue == 1 && owner.displayState.alphaValue == 1,
                "status fades settle without retaining a dimmed state")
        let unchanged = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 { owner.render() }
        print("METRIC: motion scenario elapsed=\(ProcessInfo.processInfo.systemUptime - started)s; 200 unchanged renders=\(ProcessInfo.processInfo.systemUptime - unchanged)s; no frame-rate claim")
        try nativeTerminationAcceptance(owner, app)
        try automaticLockUIAcceptance(owner, app, lockBackend, lockStore)
        NSStatusBar.system.removeStatusItem(owner.item)
        owner.window.close()
        print("PASS: local native UI E2E; real power, installed app and network untouched")
    }
}
