import AppKit
import CoreServices

enum SystemTerminationRequest: Equatable {
    case shutdown, restart

    init?(event: NSAppleEventDescriptor?) {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return nil }
        // System quit reasons can be encoded as an event attribute or parameter.
        let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        switch reason?.enumCodeValue {
        case OSType(kAEShutDown), OSType(kAEShowShutdownDialog): self = .shutdown
        case OSType(kAERestart), OSType(kAEShowRestartDialog): self = .restart
        default: return nil
        }
    }

    func confirmationAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = self == .shutdown ? "Выключить Mac?" : "Перезапустить Mac?"
        alert.informativeText = "NoSleep снимет защиту сна и экрана и завершит работу. «Отмена» сохранит NoSleep и отменит эту попытку "
            + (self == .shutdown ? "выключения Mac." : "перезапуска Mac.")
        let cancel = alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Продолжить").keyEquivalent = ""
        // NSAlert lays out Cancel specially; assign the safe default after that layout.
        alert.layout()
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        return alert
    }
}

func runSystemTerminationConfirmation(_ alert: NSAlert) -> Bool {
    // A button has only one key equivalent. Keep Return as the visible default and
    // route Escape to Cancel only while this application's confirmation is modal.
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if NSApplication.shared.modalWindow === alert.window, event.keyCode == 53 {
            alert.buttons[0].performClick(nil)
            return nil
        }
        return event
    }
    defer { if let monitor { NSEvent.removeMonitor(monitor) } }
    return alert.runModal() == .alertSecondButtonReturn
}
