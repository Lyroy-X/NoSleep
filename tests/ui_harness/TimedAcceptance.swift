import AppKit

final class TimedCountingLabel: NSTextField {
    var writes = 0
    override var stringValue: String { didSet { writes += 1 } }
}

func timedUIAcceptance() throws {
    let history = DurationHistory(defaults: UIHarnessEnvironment.defaults)
    let owner = MenuApp()
    owner.durationHistory = history
    owner.engine.fixtureActionsAllowed = true
    owner.buildWindow(); owner.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    owner.permissionReady = true
    owner.engine.changed = { owner.current = $0; owner.render() }
    owner.engine.timingChanged = { owner.timedState = $0; owner.render() }
    owner.render(); owner.window.orderFrontRegardless()
    defer { owner.durationPopover?.close(); owner.window.orderOut(nil) }
    owner.showDisplayDuration()
    guard let popover = owner.durationPopover, let picker = popover.contentViewController as? DurationPopover else {
        require(false, "native duration popover exists"); return
    }
    _ = picker.view
    require(popover.isShown && picker.choices.arrangedSubviews.count == 4, "real native popover has four built-in durations")
    picker.showCustom(); picker.hours.stringValue = "5"; picker.minutes.stringValue = "00"; picker.validate()
    require(picker.apply.isEnabled && picker.apply.title.contains("5 ч"), "custom five hours validates in native fields")
    picker.minutes.stringValue = "60"; picker.validate()
    require(!picker.apply.isEnabled && !picker.error.isHidden, "invalid custom minutes visibly refuse start")
    picker.minutes.stringValue = "00"; picker.validate()
    owner.engine.rejectTimed = true; picker.applyDuration()
    spinUntil { !owner.busy }
    require(history.values(.display).isEmpty && !picker.error.isHidden, "failed activation does not save a custom chip")
    owner.engine.rejectTimed = false; picker.applyDuration()
    spinUntil { !owner.busy }
    require(history.values(.display) == [300] && owner.current.displayWanted && owner.current.systemWanted,
            "successful native custom duration saves only after protection is confirmed")
    require(owner.timedState.remaining[.display] == 18000 && owner.displayDurationButton.title.contains("5 ч"),
            "native row displays its independent remaining duration")
    let originalLabel = owner.displayState!
    let counting = TimedCountingLabel(); counting.stringValue = originalLabel.stringValue; counting.writes = 0
    owner.displayState = counting; owner.render(); owner.render()
    require(counting.writes == 0, "unchanged timer render does not rewrite text or restart label motion")
    owner.current.displayActual = false; owner.render()
    require(counting.stringValue.contains("Не удалось подтвердить"), "timer detail cannot hide unconfirmed actual protection")
    owner.current.displayActual = true; owner.displayState = originalLabel; owner.render()
    owner.showDisplayDuration()
    let again = owner.durationPopover!.contentViewController as! DurationPopover; _ = again.view
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let remove = descendants(again.view).compactMap { $0 as? NSButton }.first { $0.toolTip?.hasPrefix("Удалить сохранённый срок") == true }!
    remove.performClick(nil)
    require(history.values(.display).isEmpty && owner.timedState.remaining[.display] == 18000,
            "native chip cross removes history while the running timer stays intact")
    require(DurationHistory(defaults: UIHarnessEnvironment.defaults).values(.display).isEmpty,
            "chip deletion survives a new preferences reader")
    again.finishNow(); spinUntil { !owner.busy }
    require(!owner.current.displayWanted && !owner.current.systemWanted && owner.timedState.remaining.isEmpty,
            "finish-now returns the original state rather than an unrelated default")
    for n in [300, 301, 302, 303, 304] { history.remember(n, for: .display) }
    owner.showDisplayDuration()
    let full = owner.durationPopover!.contentViewController as! DurationPopover; _ = full.view; full.showCustom()
    full.view.layoutSubtreeIfNeeded()
    require(full.saved.arrangedSubviews.count == 3 && full.view.fittingSize.height < 640,
            "five custom choices wrap into bounded native rows")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        owner.window.appearance = NSAppearance(named: appearance)
        full.view.appearance = NSAppearance(named: appearance)
        try captureTimedView(owner.window.contentView!, "timed-window-" + appearance.rawValue)
        try captureTimedView(full.view, "timed-popover-" + appearance.rawValue)
    }
    owner.window.setContentSize(NSSize(width: 520, height: 590)); owner.window.contentView!.layoutSubtreeIfNeeded()
    require(owner.sleepDurationButton.frame.width > 0 && owner.displayDurationButton.frame.width > 0,
            "minimum window retains both duration actions")
    owner.durationPopover?.close()
    owner.permissionReady = false; owner.render(); owner.showSleepDuration()
    require(!owner.sleepDurationButton.isEnabled && owner.durationPopover?.isShown != true,
            "duration entry respects the existing permission gate")
    print("PASS: native timed popover, saved-chip removal, validation/refusal/retry, independent state, light/dark snapshots and permission guard")
}

func captureTimedView(_ view: NSView, _ name: String) throws {
    view.layoutSubtreeIfNeeded()
    let size = view.fittingSize
    if view.bounds.width == 0 || view.bounds.height == 0 { view.setFrameSize(size) }
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { require(false, "timed snapshot has bounds"); return }
    view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
    let image = NSImage(size: view.bounds.size); image.lockFocus()
    view.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: view.bounds.size).fill() }
    NSImage(cgImage: bitmap.cgImage!, size: view.bounds.size).draw(in: NSRect(origin: .zero, size: view.bounds.size))
    image.unlockFocus()
    try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: UIHarnessEnvironment.output.appendingPathComponent(name + ".png"))
}
