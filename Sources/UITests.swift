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
    let check = Process(), output = Pipe()
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    check.arguments = ["python3", root.appendingPathComponent("tests/termination_regression.py").path]
    check.standardOutput = output; check.standardError = output
    try check.run()
    let data = output.fileHandleForReading.readDataToEndOfFile(); check.waitUntilExit()
    guard check.terminationStatus == 0 else {
        throw PowerError(message: "System termination regression: " + String(decoding: data, as: UTF8.self))
    }
    print("PASS: system quit cancellation and critical confirmation mutation")
    print("PASS: power and diagnostics menus remain; VPN menus absent")
}
