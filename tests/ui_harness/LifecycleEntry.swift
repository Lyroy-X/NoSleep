import AppKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
final class LifecycleDriver: NSObject, NSApplicationDelegate {
    let owner = MenuApp()
    var timer: Timer?, phase = 0
    var quitStarted = Date()
    func applicationDidFinishLaunching(_ notification: Notification) {
        owner.engine.fixtureActionsAllowed = true; owner.diagnostics.fixturePowerActionsAllowed = true
        owner.lockController = AutomaticLockController(backend: TestScreenLockBackend(try! ScreenLockPolicy(120)), store: TestScreenLockStore())
        owner.lockPasswordPrompt = { _, done in done(try! ScreenLockSecret("fixture-only")) }
        UIHarnessEnvironment.defaults.set(false, forKey: "PreventSystemSleep")
        owner.applicationDidFinishLaunching(notification)
        let next = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.step() }
        timer = next
        RunLoop.main.add(next, forMode: .default); RunLoop.main.add(next, forMode: .modalPanel)
    }
    func quitThroughActualObserver() {
        quitStarted = Date()
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(CommandLine.arguments[2] + ".command"),
            object: nil, userInfo: ["command": "quit"], deliverImmediately: true)
    }
    func step() {
        switch phase {
        case 0:
            if CommandLine.arguments.contains("--missing-permission") {
                guard owner.permissionReady == false, owner.lockController.state.ready, !owner.busy else { return }
                require(MacPower.readinessQueries == 2 && !owner.sleepSwitch.isEnabled && !owner.displaySwitch.isEnabled &&
                        !owner.setupRow.isHidden && owner.engine.fixtureCommands.isEmpty,
                        "definitive missing permission stays disabled after bounded retry without admin or power action")
                phase = 6; owner.quitApp(); return
            }
            guard owner.permissionReady == true, owner.lockController.state.ready, !owner.busy else { return }
            require(MacPower.readinessQueries == 2 && owner.sleepSwitch.isEnabled && owner.displaySwitch.isEnabled, "real app launch retries a transient failed read and enables both controls")
            owner.toggleDisplay(); phase = 1
        case 1:
            guard !owner.busy else { return }
            require(owner.current.systemWanted && owner.current.displayWanted && owner.summaryIcon.image != nil,
                    "real event loop applies dependent controls and retains status icon")
            owner.perform("lock-on"); phase = 2
        case 2:
            guard !owner.busy else { return }
            require(owner.lockController.state.enabled, "fake lock prerequisite is enabled")
            owner.lockPasswordPrompt = nil; phase = 3; quitThroughActualObserver()
        case 3:
            guard let sheet = owner.window.attachedSheet else {
                require(Date().timeIntervalSince(quitStarted) < 3, "async quit must present its sheet without starving main-queue callbacks")
                return
            }
            require(owner.busy && owner.engine.fixtureShutdownCount == 0, "native quit waits without power cleanup")
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            require(views(sheet.contentView!).contains { $0 is NSSecureTextField }, "actual async quit presents its secure sheet through the real app loop")
            phase = 4; owner.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        case 4:
            guard !owner.busy, owner.window.attachedSheet == nil else { return }
            require(owner.current.systemWanted && owner.current.displayWanted && owner.lockController.state.enabled,
                    "cancelled native quit preserves app and all protections")
            owner.lockPasswordPrompt = { _, done in done(try! ScreenLockSecret("fixture-only")) }
            phase = 5; quitThroughActualObserver()
        default: break
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = owner.applicationShouldTerminate(sender)
        print("STATE: termination delegate phase=\(phase), reply=\(reply.rawValue), shutdowns=\(owner.engine.fixtureShutdownCount)")
        return reply
    }
    func applicationWillTerminate(_ notification: Notification) {
        print("STATE: will terminate phase=\(phase), shutdowns=\(owner.engine.fixtureShutdownCount), lock=\(owner.lockController.state.enabled)")
        require((phase == 5 || phase == 6) && owner.engine.fixtureShutdownCount == 1 && !owner.lockController.state.enabled,
                "fresh native quit retries and cleans up exactly once")
        UIHarnessEnvironment.defaults.removePersistentDomain(forName: UIHarnessEnvironment.defaultsName)
        timer?.invalidate()
        try! Data("passed".utf8).write(to: UIHarnessEnvironment.output.appendingPathComponent("lifecycle-result.txt"))
        print("PASS: full native startup, dependent controls, asynchronous password sheet, cancellation and quit retry")
    }
}
@main enum LifecycleMain {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let driver = LifecycleDriver(); app.delegate = driver
        withExtendedLifetime(driver) { app.run() }
    }
}
