import AppKit

func applicationMenu(target: NSObject? = nil) -> NSMenu {
    let root = NSMenu()
    let app = NSMenuItem(); app.submenu = NSMenu(title: "NoSleep")
    app.submenu?.addItem(NSMenuItem(title: "О NoSleep", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    app.submenu?.addItem(.separator())
    app.submenu?.addItem(NSMenuItem(title: "Скрыть NoSleep", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
    let hideOthers = NSMenuItem(title: "Скрыть остальные", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"); hideOthers.keyEquivalentModifierMask = [.command, .option]
    app.submenu?.addItem(hideOthers)
    app.submenu?.addItem(NSMenuItem(title: "Показать все", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
    app.submenu?.addItem(.separator())
    app.submenu?.addItem(NSMenuItem(title: "Выйти из NoSleep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    root.addItem(app)
    // Keep editing actions on the native responder chain, including Cmd-V in text fields.
    let edit = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""); edit.submenu = NSMenu(title: "Правка")
    for (title, action, key) in [("Отменить", "undo:", "z"), ("Повторить", "redo:", "Z"),
                               ("Вырезать", "cut:", "x"), ("Копировать", "copy:", "c"),
                               ("Вставить", "paste:", "v"), ("Выбрать всё", "selectAll:", "a")] {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : .command
        edit.submenu?.addItem(item)
    }
    root.addItem(edit)
    let controls = NSMenuItem(title: "Управление", action: nil, keyEquivalent: ""); controls.submenu = NSMenu(title: "Управление"); controls.submenu?.autoenablesItems = false
    for (title, action, tag) in [("Mac не засыпает", #selector(MenuApp.toggleSleep), 22),
                                 ("Экран не гаснет", #selector(MenuApp.toggleDisplay), 23)] {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.tag = tag; item.target = target; controls.submenu?.addItem(item)
    }
    controls.submenu?.addItem(.separator())
    let all = NSMenuItem(title: "Включить всё", action: #selector(MenuApp.toggleAll), keyEquivalent: "a"); all.keyEquivalentModifierMask = [.command, .shift]; all.target = target; all.tag = 25
    controls.submenu?.addItem(all)
    let export = NSMenuItem(title: "Сохранить диагностику…", action: #selector(MenuApp.exportDiagnostics), keyEquivalent: "e"); export.target = target; export.tag = 27
    controls.submenu?.addItem(export); root.addItem(controls)
    let window = NSMenuItem(title: "Окно", action: nil, keyEquivalent: ""); window.submenu = NSMenu(title: "Окно")
    window.submenu?.addItem(NSMenuItem(title: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
    window.submenu?.addItem(NSMenuItem(title: "Масштабировать", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
    window.submenu?.addItem(.separator())
    let reopen = NSMenuItem(title: "Показать NoSleep", action: #selector(MenuApp.showWindow), keyEquivalent: ""); reopen.target = target; window.submenu?.addItem(reopen)
    window.submenu?.addItem(NSMenuItem(title: "Все окна на передний план", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")); root.addItem(window)
    let help = NSMenuItem(title: "Помощь", action: nil, keyEquivalent: ""); help.submenu = NSMenu(title: "Помощь")
    let guide = NSMenuItem(title: "Справка NoSleep", action: #selector(MenuApp.showHelp), keyEquivalent: ""); guide.target = target; help.submenu?.addItem(guide); root.addItem(help)
    return root
}
