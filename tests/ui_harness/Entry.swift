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
@main enum PrivateUIHarness {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let owner = MenuApp()
        owner.buildWindow()
        owner.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        owner.item.menu = NSMenu()
        app.mainMenu = applicationMenu(target: owner)
        owner.permissionReady = true
        owner.engine.fixtureActionsAllowed = true
        owner.diagnostics.fixturePowerActionsAllowed = true
        owner.engine.changed = { owner.current = $0 }
        try FileManager.default.createDirectory(at: UIHarnessEnvironment.dataDirectory, withIntermediateDirectories: true)
        owner.render()
        try uiTests()
        let controls = walk(owner.window.contentView!).compactMap { $0 as? NSSwitch }
        require(controls.count == 2, "only independent sleep and display switches remain")
        let labels = walk(owner.window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
        require(!labels.contains { $0.contains("VPN") || $0.contains("Cisco") }, "native window has no VPN status or settings")
        require(owner.window.toolbar != nil && owner.window.minSize.width == 520, "toolbar, resizing and native layout preserved")
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
        require(owner.current.displayWanted && !owner.current.systemWanted, "display switch leaves sleep protection independent")
        let menu = app.mainMenu!.items.first { $0.title == "Управление" }!.submenu!
        let sleep = menu.item(withTag: 22)!
        require(app.sendAction(sleep.action!, to: sleep.target, from: sleep), "native menu routes sleep action")
        drain()
        require(owner.current.systemWanted && owner.current.displayWanted, "sleep menu enables protection without changing display")
        owner.allButton.performClick(nil); drain()
        require(!owner.current.systemWanted && !owner.current.displayWanted && owner.allButton.title == "Включить всё", "combined action disables exactly the two power features")
        owner.allButton.performClick(nil); drain()
        require(owner.current.systemWanted && owner.current.displayWanted && owner.allButton.title == "Выключить всё", "combined action enables both power features")
        owner.permissionReady = false; owner.render()
        require(!owner.sleepSwitch.isEnabled && owner.displaySwitch.isEnabled && !owner.setupRow.isHidden, "first-run permission state preserves display control and setup")
        let snapshot = try Data(contentsOf: UIHarnessEnvironment.dataDirectory.appendingPathComponent("ui.json"))
        let fields = try JSONSerialization.jsonObject(with: snapshot) as! [String: Any]
        require(!fields.keys.contains { $0.lowercased().contains("vpn") || $0.lowercased().contains("recovery") || $0.lowercased().contains("observer") }, "UI snapshot contains only current app features")
        NSStatusBar.system.removeStatusItem(owner.item)
        owner.window.close()
        print("PASS: local native UI E2E; real power, installed app and network untouched")
    }
}
