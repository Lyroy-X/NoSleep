import AppKit

final class DurationPopover: NSViewController, NSTextFieldDelegate {
    let feature: TimedFeature, history: DurationHistory
    var start: ((Int, @escaping (Bool) -> Void) -> Void)?
    var finish: (() -> Void)?, indefinite: (() -> Void)?
    var afterText = "", running = false, failed = false
    let hours = NSTextField(string: "1"), minutes = NSTextField(string: "00")
    let error = NSTextField(wrappingLabelWithString: "")
    let apply = NSButton(title: "", target: nil, action: nil)
    let saved = NSStackView(), custom = NSStackView(), choices = NSStackView()
    private var selected: Int
    private var savedButtons: [NSButton] = []
    private var customSelected = false
    init(feature: TimedFeature, history: DurationHistory) {
        self.feature = feature; self.history = history; selected = history.last(feature)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func label(_ value: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return label
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded
        button.setAccessibilityLabel(title); return button
    }
    override func loadView() {
        view = NSView()
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 14
        body.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(body)
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 370),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), body.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)])
        body.addArrangedSubview(label(feature.title, size: 16, bold: true))
        let subtitle = label("На какое время включить защиту?"); subtitle.textColor = .secondaryLabelColor; body.addArrangedSubview(subtitle)
        choices.distribution = .fillEqually; choices.spacing = 6
        for value in DurationHistory.presets {
            let chip = button(DurationHistory.label(value), #selector(selectDuration(_:))); chip.tag = value; chip.setButtonType(.pushOnPushOff); choices.addArrangedSubview(chip)
        }
        body.addArrangedSubview(choices)
        saved.orientation = .vertical; saved.alignment = .leading; saved.spacing = 7; body.addArrangedSubview(saved)
        body.addArrangedSubview(button("Своё время…", #selector(showCustom)))
        custom.orientation = .horizontal; custom.spacing = 12
        for (title, field) in [("Часы", hours), ("Минуты", minutes)] {
            field.delegate = self; field.setAccessibilityLabel(title); field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let column = NSStackView(views: [label(title, size: 11), field]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
            custom.addArrangedSubview(column)
        }
        custom.isHidden = true; body.addArrangedSubview(custom)
        let divider = NSBox(); divider.boxType = .separator; body.addArrangedSubview(divider)
        let after = label("После завершения\n" + afterText); after.textColor = .secondaryLabelColor; body.addArrangedSubview(after)
        error.textColor = .systemRed; error.font = .systemFont(ofSize: 11); error.isHidden = true; error.setAccessibilityLabel("Ошибка времени")
        body.addArrangedSubview(error)
        apply.target = self; apply.action = #selector(applyDuration); apply.bezelStyle = .rounded; apply.bezelColor = .controlAccentColor
        apply.keyEquivalent = "\r"
        let actions = NSStackView(views: [button("Без таймера", #selector(makeIndefinite)), apply]); actions.spacing = 10; actions.distribution = .fill
        body.addArrangedSubview(actions)
        if running { body.addArrangedSubview(button(failed ? "Повторить восстановление" : "Завершить сейчас", #selector(finishNow))) }
        for child in [choices, saved, divider, after, error, actions] { child.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        rebuildSaved(); select(selected)
        if !DurationHistory.presets.contains(selected) && !history.values(feature).contains(selected) { showCustom() }
        preferredContentSize = view.fittingSize
    }
    func rebuildSaved() {
        savedButtons.removeAll()
        for child in saved.arrangedSubviews { saved.removeArrangedSubview(child); child.removeFromSuperview() }
        let values = history.values(feature); saved.isHidden = values.isEmpty
        for offset in stride(from: 0, to: values.count, by: 2) {
            let row = NSStackView(); row.spacing = 8
            for value in values[offset..<min(offset+2, values.count)] {
                let chip = button(DurationHistory.label(value), #selector(selectDuration(_:))); chip.tag = value; chip.setButtonType(.pushOnPushOff); savedButtons.append(chip)
                let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!, target: self, action: #selector(removeSaved(_:)))
                remove.tag = value; remove.isBordered = false; remove.contentTintColor = .secondaryLabelColor
                remove.toolTip = "Удалить сохранённый срок " + DurationHistory.label(value)
                remove.setAccessibilityLabel(remove.toolTip!)
                let pair = NSStackView(views: [chip, remove]); pair.spacing = 2; row.addArrangedSubview(pair)
            }
            saved.addArrangedSubview(row)
        }
    }
    private func select(_ value: Int) {
        selected = value; customSelected = false; custom.isHidden = true
        hours.stringValue = String(value / 60); minutes.stringValue = String(format: "%02d", value % 60)
        for chip in choices.arrangedSubviews.compactMap({ $0 as? NSButton }) + savedButtons { chip.state = chip.tag == value ? .on : .off }
        error.isHidden = true; apply.isEnabled = true; apply.title = "Включить на " + DurationHistory.label(value)
    }
    @objc func selectDuration(_ sender: NSButton) { select(sender.tag) }
    @objc func removeSaved(_ sender: NSButton) {
        history.remove(sender.tag, for: feature); rebuildSaved()
        if selected == sender.tag { select(60) }
        preferredContentSize = view.fittingSize
    }
    @objc func showCustom() {
        for chip in choices.arrangedSubviews.compactMap({ $0 as? NSButton }) + savedButtons { chip.state = .off }
        customSelected = true; custom.isHidden = false; validate()
        preferredContentSize = view.fittingSize; view.window?.makeFirstResponder(hours)
    }
    func controlTextDidChange(_ obj: Notification) { validate() }
    func validate() {
        let value = DurationHistory.parse(hours: hours.stringValue, minutes: minutes.stringValue)
        apply.isEnabled = value != nil; error.isHidden = value != nil
        error.stringValue = "Введите от 1 минуты до 7 дней. Минуты — от 0 до 59."
        if let value { selected = value; apply.title = "Включить на " + DurationHistory.label(value) }
        preferredContentSize = view.fittingSize
    }
    @objc func applyDuration() {
        if customSelected { validate() }; guard apply.isEnabled else { return }
        let chosen = selected
        apply.isEnabled = false
        start?(chosen) { [weak self] success in
            guard let self else { return }
            self.apply.isEnabled = true
            if success { self.history.remember(chosen, for: self.feature) }
            else {
                self.error.stringValue = "Не удалось включить таймер. Проверьте защиту и повторите."; self.error.isHidden = false
                self.preferredContentSize = self.view.fittingSize
            }
        }
    }
    @objc func makeIndefinite() { indefinite?() }
    @objc func finishNow() { finish?() }
}
