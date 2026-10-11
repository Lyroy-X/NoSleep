import AppKit

func applicationMenu() -> NSMenu {
    let root = NSMenu()
    let app = NSMenuItem(); app.submenu = NSMenu(title: "NoSleep")
    app.submenu?.addItem(NSMenuItem(title: "Выйти из NoSleep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    root.addItem(app)
    let edit = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""); edit.submenu = NSMenu(title: "Правка")
    for (title, action, key) in [("Вырезать", "cut:", "x"), ("Копировать", "copy:", "c"), ("Вставить", "paste:", "v"), ("Выбрать всё", "selectAll:", "a")] {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        edit.submenu?.addItem(item)
    }
    root.addItem(edit)
    return root
}
