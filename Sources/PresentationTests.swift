import Foundation

func presentationTests() throws {
    func present(_ sleep: Bool = false, _ sleepActual: Bool = false, _ display: Bool = false,
                 _ displayActual: Bool = false, ready: Bool? = true, busy: Bool = false, error: Bool = false) -> PowerPresentation {
        PowerPresentation.make(systemWanted: sleep, systemActual: sleepActual, displayWanted: display,
                               displayActual: displayActual, permissionReady: ready, busy: busy, hasError: error)
    }
    assert(present().title == "Защита выключена")
    assert(present(true, true).title == "Mac под защитой")
    assert(present(false, false, true, true).title == "Экран под защитой")
    assert(present(true, true, true, true).detail == "Mac не засыпает · экран не гаснет")
    assert(present(false, true).tone == .neutral, "External sleep settings are not app protection")
    assert(present(false, true).detail.contains("другой настройкой"))
    assert(present(ready: nil).title == "Проверяю готовность…")
    assert(present(ready: false).title == "Настройте NoSleep")
    assert(present(false, false, true, true, ready: false).tone == .active, "Missing sleep permission preserves display protection")
    assert(present(error: true).tone == .attention)
    assert(present(true, true, true, true, error: true).tone == .attention, "Failures remain visible even with confirmed protection")
    assert(present(busy: true, error: true).title == "Применяю настройки…")
    assert(present(true, false).tone == .attention, "Requested sleep is not confirmed success")
    assert(present(false, false, true, false).tone == .attention, "Requested display is not confirmed success")
    assert(present(true, true).tone == .active, "A successful retry clears the warning")
    for sleep in [false, true] {
        for actualSleep in [false, true] {
            for display in [false, true] {
                for actualDisplay in [false, true] {
                    let view = present(sleep, actualSleep, display, actualDisplay)
                    let failed = (sleep && !actualSleep) || (display && !actualDisplay)
                    assert((view.tone == .attention) == failed, "All request/confirmation boundaries are explicit")
                    if view.tone == .active {
                        assert((sleep && actualSleep) || (display && actualDisplay))
                    }
                }
            }
        }
    }
    print("PASS: compact status normal/checking/setup/pending/error/external state, all 16 confirmation boundaries and retry")
}
