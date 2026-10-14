import AppKit

func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
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
            let until = Date(timeIntervalSinceNow: 0.15)
            while owner.busy && Date() < until { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            require(!owner.busy, "action completion leaves controls available")
        }
        owner.displaySwitch.performClick(nil); drain()
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
