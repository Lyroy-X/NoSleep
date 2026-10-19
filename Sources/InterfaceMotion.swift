import AppKit
import QuartzCore

enum InterfaceMotion {
    static func duration(visible: Bool, reduceMotion: Bool) -> TimeInterval {
        visible && !reduceMotion ? 0.2 : 0
    }
    static func popoverAnimates(visible: Bool, active: Bool, reduceMotion: Bool) -> Bool {
        duration(visible: visible && active, reduceMotion: reduceMotion) > 0
    }
    static func duration(for view: NSView) -> TimeInterval {
        duration(visible: view.window?.isVisible == true,
                 reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    static func set(_ control: NSSwitch, on: Bool) {
        let state: NSControl.StateValue = on ? .on : .off
        guard control.state != state else { return }
        let time = duration(for: control)
        if time == 0 { control.state = state; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = time
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            control.animator().state = state
        }
    }
    static func text(_ label: NSTextField, _ value: String) {
        guard label.stringValue != value else { return }
        // Commit accessible content immediately; motion never delays confirmed state.
        label.stringValue = value
        let time = duration(for: label)
        guard time > 0, !value.isEmpty else { label.alphaValue = 1; return }
        label.alphaValue = 0.55
        NSAnimationContext.runAnimationGroup { context in
            context.duration = time
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.animator().alphaValue = 1
        }
    }
}


// Finite SF Symbol replacement: no timer or repeating idle effect.
final class StatusSymbolView: NSImageView {
    private(set) var symbolName = ""
    private var tone: PowerPresentation.Tone?
    private(set) var animationRevision = 0
    func update(_ status: PowerPresentation) {
        let animate = InterfaceMotion.duration(for: self) > 0
        if !animate { removeAllSymbolEffects(animated: false) }
        guard symbolName != status.symbol || tone != status.tone else { return }
        let hadImage = image != nil
        symbolName = status.symbol; tone = status.tone
        guard let next = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil) else { return }
        contentTintColor = status.tone == .attention ? .systemOrange : status.tone == .active ? .controlAccentColor : .secondaryLabelColor
        if animate && hadImage {
            animationRevision += 1
            setSymbolImage(next, contentTransition: .replace)
        } else { image = next }
    }
}
