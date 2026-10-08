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

final class MacPower: PowerControl {
    private var assertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            throw PowerError(message: "macOS не ответила за 5 секунд. Повторите переключение.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let result = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw PowerError(message: result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
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
    assert(control.displayActive && fake.display && !control.active)
    try control.enable()
    try control.disable()
    assert(control.displayActive && fake.display, "Display toggle must be independent")
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
    print("PASS: display on/off, independent toggles, assertion recovery, failure, quit cleanup")
}

struct LiveState: Codable {
    var systemWanted: Bool
    var systemActual: Bool
    var displayWanted: Bool
    var displayActual: Bool
    var error: String?
    var pid: Int32 = getpid()
    var updatedAt: Double = Date().timeIntervalSince1970
    var statusTitle: String {
        if error != nil { return " !" }
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
    init(_ power: PowerControl) { protection = Protection(power) }
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
                case "all-off": try self.protection.disable(); try self.protection.setDisplay(false)
                default: throw PowerError(message: "Неизвестная команда")
                }
                self.actionError = nil
                if save {
                    UserDefaults.standard.set(self.protection.active, forKey: "PreventSystemSleep")
                    UserDefaults.standard.set(self.protection.displayActive, forKey: "KeepDisplayAwake")
                }
            } catch { self.actionError = error.localizedDescription }
            self.changed?(self.state())
            completed?()
        }
    }
    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
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
            do { try self.protection.shutdown(); self.changed?(self.state()); completed(nil) }
            catch { self.start(); completed(error) }
        }
    }
    func shutdownNow() throws {
        try queue.sync {
            timer?.cancel(); timer = nil
            do { try protection.shutdown(); changed?(state()) }
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

final class MenuApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let engine = GuardEngine(MacPower())
    var current = LiveState(systemWanted: false, systemActual: false, displayWanted: false, displayActual: false, error: nil)
    var item: NSStatusItem!
    var window: NSWindow!
    var sleepSwitch: NSButton!
    var displaySwitch: NSButton!
    var sleepState: NSTextField!
    var displayState: NSTextField!
    var errorLabel: NSTextField!
    var busy = false
    var observer: NSObjectProtocol?
    let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoSleep")
    var lastLog = ""
    func writeUI() {
        let state: [String: Any] = ["windowVisible": window.isVisible, "windowTitle": window.title,
                                  "statusTitle": current.statusTitle,
                                  "sleepChecked": sleepSwitch.state == .on,
                                  "displayChecked": displaySwitch.state == .on,
                                  "errorText": errorLabel.stringValue]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: dataDir.appendingPathComponent("ui.json"), options: .atomic)
        }
    }
    func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 24) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.frame = NSRect(x: x, y: y, width: width, height: height)
        window.contentView!.addSubview(l); return l
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NoSleep"; window.center(); window.delegate = self
        window.isReleasedWhenClosed = false
        let title = label("NoSleep", x: 26, y: 287, width: 400, height: 32)
        title.font = .boldSystemFont(ofSize: 24)
        sleepSwitch = NSButton(checkboxWithTitle: "Не позволять Mac засыпать", target: self, action: #selector(toggleSleep))
        sleepSwitch.frame = NSRect(x: 26, y: 242, width: 410, height: 26); window.contentView!.addSubview(sleepSwitch)
        sleepState = label("Проверяю…", x: 47, y: 218, width: 385)
        displaySwitch = NSButton(checkboxWithTitle: "Не гасить экран при бездействии", target: self, action: #selector(toggleDisplay))
        displaySwitch.frame = NSRect(x: 26, y: 178, width: 410, height: 26); window.contentView!.addSubview(displaySwitch)
        displayState = label("Проверяю…", x: 47, y: 154, width: 385)
        errorLabel = label("", x: 26, y: 77, width: 410, height: 65); errorLabel.textColor = .systemRed
        let off = NSButton(title: "Выключить всё", target: self, action: #selector(allOff)); off.frame = NSRect(x: 26, y: 38, width: 150, height: 30); window.contentView!.addSubview(off)
        let quit = NSButton(title: "Выйти", target: self, action: #selector(quitApp)); quit.frame = NSRect(x: 325, y: 38, width: 108, height: 30); window.contentView!.addSubview(quit)
        let foot = label("Закрытие окна оставляет приложение работать в фоне.", x: 26, y: 8, width: 410, height: 20); foot.font = .systemFont(ofSize: 11); foot.textColor = .secondaryLabelColor
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Открыть NoSleep", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        let sleepMenu = NSMenuItem(title: "Не позволять Mac засыпать", action: #selector(toggleSleep), keyEquivalent: ""); sleepMenu.tag = 2; menu.addItem(sleepMenu)
        let displayMenu = NSMenuItem(title: "Не гасить экран", action: #selector(toggleDisplay), keyEquivalent: ""); displayMenu.tag = 3; menu.addItem(displayMenu)
        menu.addItem(NSMenuItem(title: "Выключить всё", action: #selector(allOff), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(quitApp), keyEquivalent: "q"))
        for entry in menu.items { entry.target = self }
        item.menu = menu
        engine.changed = { [weak self] state in
            guard let self = self else { return }
            self.writeState(state)
            DispatchQueue.main.async { self.current = state; self.render() }
        }
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("local.robert.NoSleep.command"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let command = notification.userInfo?["command"] as? String else { return }
            if command == "show" { self.showWindow() }
            else if command == "hide" { self.window.close() }
            else if command == "quit" { self.quitApp() }
            else if ["sleep-on", "sleep-off", "display-on", "display-off", "all-off"].contains(command) { self.perform(command) }
        }
        let wantedSystem = UserDefaults.standard.object(forKey: "PreventSystemSleep") == nil || UserDefaults.standard.bool(forKey: "PreventSystemSleep")
        let wantedDisplay = UserDefaults.standard.bool(forKey: "KeepDisplayAwake")
        if wantedSystem { engine.act("sleep-on", save: false) }
        if wantedDisplay { engine.act("display-on", save: false) }
        engine.start(); render(); showWindow()
    }
    func writeState(_ state: LiveState) {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: dataDir.appendingPathComponent("state.json"), options: .atomic) }
        let description = "sleep=\(state.systemWanted)/\(state.systemActual) display=\(state.displayWanted)/\(state.displayActual) error=\(state.error ?? "none")"
        if description != lastLog {
            lastLog = description
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(description)\n"
            let url = dataDir.appendingPathComponent("events.log")
            if !FileManager.default.fileExists(atPath: url.path) { try? Data().write(to: url) }
            if let file = try? FileHandle(forWritingTo: url) { file.seekToEndOfFile(); file.write(Data(line.utf8)); try? file.close() }
        }
    }
    func render() {
        sleepSwitch.state = current.systemWanted ? .on : .off
        displaySwitch.state = current.displayWanted ? .on : .off
        sleepSwitch.isEnabled = !busy; displaySwitch.isEnabled = !busy
        sleepState.stringValue = current.systemWanted ? (current.systemActual ? "Работает: macOS подтверждает запрет сна" : "Запрет сна не подтверждён") : (current.systemActual ? "Сон запрещён другой настройкой macOS" : "Выключено: сон разрешён")
        displayState.stringValue = current.displayWanted ? (current.displayActual ? "Работает: защита экрана включена" : "Защита экрана не подтверждена") : "Выключено: обычный режим экрана"
        sleepState.textColor = current.systemWanted && !current.systemActual ? .systemRed : .secondaryLabelColor
        displayState.textColor = current.displayWanted && !current.displayActual ? .systemRed : .secondaryLabelColor
        errorLabel.stringValue = current.error.map { "Не выполнено: \($0)" } ?? ""
        let icon = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "NoSleep")
        icon?.isTemplate = true; item.button?.image = icon
        item.button?.title = current.statusTitle
        item.button?.toolTip = "NoSleep · Сон: \(current.systemActual ? "запрещён" : "разрешён") · Экран: \(current.displayActual ? "не гаснет" : "обычный режим")"
        item.menu?.item(withTag: 2)?.state = current.systemWanted ? .on : .off
        item.menu?.item(withTag: 3)?.state = current.displayWanted ? .on : .off
        writeUI()
    }
    func perform(_ command: String) {
        busy = true; render()
        engine.act(command) { [weak self] in DispatchQueue.main.async { self?.busy = false; self?.render() } }
    }
    @objc func toggleSleep() { perform(current.systemWanted ? "sleep-off" : "sleep-on") }
    @objc func toggleDisplay() { perform(current.displayWanted ? "display-off" : "display-on") }
    @objc func allOff() { perform("all-off") }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); writeUI() }
    func windowWillClose(_ notification: Notification) { DispatchQueue.main.async { self.writeUI() } }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try engine.shutdownNow()
            return .terminateNow
        } catch {
            errorLabel.stringValue = "Не удалось снять защиту: \(error.localizedDescription)"
            return .terminateCancel
        }
    }
}

do {
    if CommandLine.arguments.contains("--self-test") {
        try selfTest()
        try backgroundTest()
    } else if let index = CommandLine.arguments.firstIndex(of: "--command"), index + 1 < CommandLine.arguments.count {
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("local.robert.NoSleep.command"), object: nil, userInfo: ["command": CommandLine.arguments[index + 1]], deliverImmediately: true)
    } else if CommandLine.arguments.contains("--verify-display") {
        let power = MacPower()
        let control = Protection(power)
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
