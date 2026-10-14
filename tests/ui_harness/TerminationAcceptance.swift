import AppKit
import CoreServices

func nativeTerminationAcceptance(_ owner: MenuApp, _ app: NSApplication) throws {
    func event(_ reason: OSType?, asParameter: Bool = false) -> NSAppleEventDescriptor {
        let value = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            let descriptor = NSAppleEventDescriptor(enumCode: reason)
            if asParameter { value.setParam(descriptor, forKeyword: AEKeyword(kAEQuitReason)) }
            else { value.setAttribute(descriptor, forKeyword: AEKeyword(kAEQuitReason)) }
        }
        return value
    }
    func enable() {
        owner.engine.act("all-on", save: false)
        require(owner.engine.state().systemWanted && owner.engine.state().displayWanted, "fixture protection enabled")
    }
    func choose(_ request: SystemTerminationRequest, button: Int, keyboard: String? = nil) -> Bool {
        let alert = request.confirmationAlert()
        require(alert.buttons.map(\.title) == ["Отмена", "Продолжить"], "native confirmation has cancel and continue actions")
        require(alert.window.defaultButtonCell === alert.buttons[0].cell, "Cancel is the default action")
        require(alert.buttons[0].keyEquivalent == "\r" && alert.buttons[1].keyEquivalent.isEmpty, "Return cancels and continue has no implicit shortcut")
        require(alert.messageText == (request == .shutdown ? "Выключить Mac?" : "Перезапустить Mac?"), "native dialog identifies system action")
        let before = owner.engine.fixtureShutdownCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            require(owner.engine.fixtureShutdownCount == before && owner.engine.state().systemWanted && owner.engine.state().displayWanted,
                    "pending confirmation retains protection without cleanup")
            require(owner.terminationReply(for: nil) { _ in fatalError("unexpected second prompt") } == .terminateCancel,
                    "overlapping ordinary quit cannot bypass confirmation")
            if let keyboard {
                let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: alert.window.windowNumber, context: nil,
                                          characters: keyboard, charactersIgnoringModifiers: keyboard,
                                          isARepeat: false, keyCode: keyboard == "\r" ? 36 : 53)!
                app.sendEvent(key)
            } else { alert.buttons[button].performClick(nil) }
        }
        app.activate(ignoringOtherApps: true)
        return runSystemTerminationConfirmation(alert)
    }
    for (reason, request) in [(kAEShutDown, SystemTerminationRequest.shutdown), (kAERestart, .restart)] {
        for keyboard in [nil, "\r", "\u{1b}"] as [String?] {
            enable()
            let before = owner.engine.fixtureShutdownCount
            let reply = owner.terminationReply(for: event(OSType(reason))) { received in
                require(received == request, "quit event reaches matching confirmation")
                return choose(received, button: 0, keyboard: keyboard)
            }
            require(reply == .terminateCancel && owner.engine.fixtureShutdownCount == before,
                    "Cancel/Return/Escape keeps app alive without power cleanup")
            require(owner.engine.state().systemWanted && owner.engine.state().displayWanted, "cancel preserves both protections")
        }
        let before = owner.engine.fixtureShutdownCount
        require(owner.terminationReply(for: event(OSType(reason), asParameter: true)) { choose($0, button: 1) } == .terminateNow,
                "fresh system request asks again and confirmed native button permits termination")
        require(owner.engine.fixtureShutdownCount == before + 1 && !owner.engine.state().systemWanted && !owner.engine.state().displayWanted,
                "confirmed system quit cleans up exactly once")
    }
    for quitEvent in [nil, event(nil), event(OSType(kAEReallyLogOut)), event(OSType(kAEQuitAll)), event(0)] as [NSAppleEventDescriptor?] {
        enable()
        require(owner.terminationReply(for: quitEvent) { _ in fatalError("ordinary quit/logout prompted") } == .terminateNow,
                "ordinary quit/logout/missing/unknown reason preserves no-dialog behavior")
    }
    enable()
    owner.engine.fixtureRejectShutdown = true
    owner.window.close()
    require(owner.terminationReply(for: event(OSType(kAEShutDown))) { choose($0, button: 1) } == .terminateCancel,
            "cleanup failure rejects confirmed system quit")
    require(owner.window.isVisible && !owner.errorLabel.isHidden && owner.errorLabel.stringValue.contains("Fixture cleanup denied"),
            "cleanup failure restores hidden window and displays error")
    require(owner.engine.state().systemWanted && owner.engine.state().displayWanted, "cleanup failure preserves protections")
    owner.engine.fixtureRejectShutdown = false
    require(owner.terminationReply(for: event(OSType(kAERestart))) { choose($0, button: 1) } == .terminateNow,
            "cleanup failure remains retryable with a new confirmation")
    require(owner.diagnostics.shutdownCount == owner.diagnostics.flushCount && owner.diagnostics.shutdownCount == owner.engine.fixtureShutdownCount - 1,
            "shutdown diagnostics emitted only for successful cleanup")
    // Exercise the actual delegate's ordinary-quit route, with no system event in progress.
    enable()
    require(owner.applicationShouldTerminate(app) == .terminateNow, "ordinary delegate quit routes through existing cleanup")
    print("PASS: native system quit confirmation, Cancel/Return/Escape, repeated/reentrant requests, explicit confirmation, ordinary quit and cleanup failure/retry")
}
