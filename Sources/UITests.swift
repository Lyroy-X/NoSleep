import AppKit

func uiTests() throws {
    let menu = applicationMenu()
    let titles = menu.items.flatMap { [$0.title] + ($0.submenu?.items.map { $0.title } ?? []) }
    assert(!titles.contains { $0.contains("VPN") || $0.contains("Cisco") })
    let controls = menu.items.first { $0.title == "Управление" }!.submenu!
    assert(controls.item(withTag: 22)?.action == #selector(MenuApp.toggleSleep))
    assert(controls.item(withTag: 23)?.action == #selector(MenuApp.toggleDisplay))
    assert(controls.item(withTag: 25)?.action == #selector(MenuApp.toggleAll))
    assert(controls.item(withTag: 27)?.action == #selector(MenuApp.exportDiagnostics))
    assert(menu.items.contains { $0.title == "Правка" })
    assert(menu.items.contains { $0.title == "Окно" })
    assert(menu.items.contains { $0.title == "Помощь" })
    try nativeCombinedShortcutTest()
    print("PASS: power and diagnostics menus remain; VPN menus absent")
}

private final class ShortcutRecorder: NSObject {
    var actions = 0
    @objc func toggleAll() { actions += 1 }
}

func nativeCombinedShortcutTest() throws {
    let app = NSApplication.shared
    let previous = app.mainMenu
    defer { app.mainMenu = previous }
    let recorder = ShortcutRecorder()
    let menu = applicationMenu(target: recorder)
    app.mainMenu = menu
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
        windowNumber: 0, context: nil, characters: "A", charactersIgnoringModifiers: "A", isARepeat: false, keyCode: 0)!
    guard menu.performKeyEquivalent(with: event) else {
        throw PowerError(message: "Shift-Command-A does not match the native combined-action shortcut")
    }
    let deadline = Date(timeIntervalSinceNow: 1)
    while recorder.actions == 0 && Date() < deadline {
        if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { app.sendEvent(event) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard recorder.actions == 1 else { throw PowerError(message: "Shift-Command-A did not route to the isolated action recorder") }
    print("PASS: native Shift-Command-A reaches one isolated combined action")
}

#if NOSLEEP_UI_FIXTURE

func compactNativeAcceptance(_ owner: MenuApp) throws {
    owner.permissionReady = true; owner.render()
    owner.engine.deferCompletion = true
    owner.allButton.performClick(nil)
    require(owner.busy && !owner.sleepSwitch.isEnabled && !owner.displaySwitch.isEnabled && !owner.allButton.isEnabled, "pending action disables duplicate native controls")
    require(owner.summaryLabel.stringValue == "Применяю настройки…", "pending action is explicit in the headline")
    let commandCount = owner.engine.fixtureCommands.count
    owner.perform("all-on")
    require(owner.engine.fixtureCommands.count == commandCount, "repeated action is refused while pending")
    owner.engine.completeForTesting()
    require(waitForUI({ !owner.busy }), "completion arrives within the bounded native wait")
    require(!owner.busy && owner.allButton.isEnabled, "completed action restores native controls")
    owner.engine.deferCompletion = false
    require(owner.sleepSwitch.accessibilityLabel() == "Mac не засыпает" && owner.displaySwitch.accessibilityLabel() == "Экран не гаснет", "independent native switches retain assistive labels")
    require(owner.exportButton.accessibilityLabel() == "Сохранить диагностику NoSleep", "report toolbar has a meaningful assistive name")
    owner.current = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)
    owner.render()
    let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
        windowNumber: owner.window.windowNumber, context: nil, characters: "A", charactersIgnoringModifiers: "A", isARepeat: false, keyCode: 0)!
    require(NSApplication.shared.mainMenu!.performKeyEquivalent(with: shortcut), "native Shift-Command-A shortcut reaches the combined action")
    let shortcutDeadline = Date(timeIntervalSinceNow: 1)
    while (owner.busy || !owner.current.systemWanted || !owner.current.displayWanted) && Date() < shortcutDeadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    require(!owner.busy && owner.current.systemWanted && owner.current.displayWanted, "keyboard combined action confirms both fake protections")

    func layoutCheck(_ name: String) throws {
        owner.window.contentView!.layoutSubtreeIfNeeded()
        owner.window.displayIfNeeded()
        let scroll = walk(owner.window.contentView!).compactMap { $0 as? NSScrollView }.first!
        let document = scroll.documentView!
        require(abs(document.bounds.width - scroll.contentView.bounds.width) < 1, "\(name): document fits viewport width")
        for view in walk(document) where !view.isHiddenOrHasHiddenAncestor && (view is NSTextField || view is NSControl) {
            let frame = document.convert(view.bounds, from: view)
            require(frame.minX >= -1 && frame.maxX <= document.bounds.width + 1, "\(name): \(type(of: view)) remains within document width")
            if let label = view as? NSTextField, !label.stringValue.isEmpty {
                require(label.bounds.height + 1 >= label.intrinsicContentSize.height, "\(name): text is not vertically clipped")
            }
        }
        if owner.setupRow.isHidden && owner.errorLabel.isHidden && owner.window.contentView!.bounds.height >= 430 {
            require(document.bounds.height <= scroll.contentView.bounds.height + 1, "\(name): ready compact content needs no scrolling")
        }
        var pixels: Data?
        owner.window.appearance!.performAsCurrentDrawingAppearance {
            let view = owner.window.contentView!.superview!
            walk(view).forEach { $0.needsDisplay = true }
            view.layoutSubtreeIfNeeded()
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            pixels = image.representation(using: .png, properties: [:])
        }
        try pixels!.write(to: UIHarnessEnvironment.output.appendingPathComponent(name + ".png"))
    }
    for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
        let name = appearance.rawValue
        owner.window.appearance = NSAppearance(named: appearance)
        owner.permissionReady = true
        owner.current = LiveState(systemWanted: true, systemActual: true, displayWanted: false, displayActual: false, error: nil)
        owner.setupError = nil; owner.render()
        owner.window.setContentSize(NSSize(width: 440, height: 430)); try layoutCheck(name + "-compact")
        owner.window.setContentSize(NSSize(width: 700, height: 560)); try layoutCheck(name + "-expanded")
        owner.permissionReady = false
        owner.setupError = "Настройка отменена. Повторите её, когда будете готовы."
        owner.current = LiveState(systemWanted: true, systemActual: false, displayWanted: false, displayActual: false, error: "Denied")
        owner.window.setContentSize(NSSize(width: 440, height: 360)); owner.render(); try layoutCheck(name + "-setup-error")
        require(!owner.errorLabel.isHidden && owner.setupButton.isEnabled && owner.summaryLabel.stringValue == "Проверьте защиту", "setup cancellation stays visible and retryable")
        owner.setupError = nil; owner.permissionReady = true
        owner.current = LiveState(systemWanted: true, systemActual: true, displayWanted: false, displayActual: false, error: nil); owner.render()
        require(owner.errorLabel.isHidden && owner.summaryLabel.stringValue == "Mac под защитой", "successful retry clears error presentation")
    }
    let stateFile = UIHarnessEnvironment.dataDirectory.appendingPathComponent("ui.json")
    let before = try FileManager.default.attributesOfItem(atPath: stateFile.path)[.modificationDate] as! Date
    var samples: [Double] = []
    for _ in 0..<300 {
        let start = ProcessInfo.processInfo.systemUptime
        owner.render()
        samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    let after = try FileManager.default.attributesOfItem(atPath: stateFile.path)[.modificationDate] as! Date
    require(before == after, "unchanged render does not rewrite isolated UI state")
    samples.sort()
    let observation: [String: Any] = ["scenario": "unchanged native fixture render", "samples": samples.count,
        "medianMilliseconds": samples[samples.count / 2], "p95Milliseconds": samples[Int(Double(samples.count) * 0.95)],
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "limits": "isolated fake-power render only; no production idle energy/FPS or baseline improvement claim"]
    try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys]).write(to: UIHarnessEnvironment.output.appendingPathComponent("render-observation.json"))
}

#endif
