import Foundation

struct PowerPresentation: Equatable {
    enum Tone { case neutral, active, attention }
    let title: String
    let detail: String
    let symbol: String
    let tone: Tone

    static func make(systemWanted: Bool, systemActual: Bool, displayWanted: Bool, displayActual: Bool,
                     permissionReady: Bool?, busy: Bool, hasError: Bool) -> PowerPresentation {
        if busy {
            return Self(title: "Применяю настройки…", detail: "Дождитесь подтверждения macOS.", symbol: "hourglass", tone: .neutral)
        }
        if hasError || (systemWanted && !systemActual) || (displayWanted && !displayActual) {
            return Self(title: "Проверьте защиту", detail: "Не удалось подтвердить действие. Подробности ниже.", symbol: "exclamationmark.triangle", tone: .attention)
        }
        if permissionReady == nil {
            return Self(title: "Проверяю готовность…", detail: "Проверяю доступ к защите сна.", symbol: "hourglass", tone: .neutral)
        }
        if systemWanted && systemActual {
            return Self(title: "Mac под защитой", detail: displayWanted && displayActual ? "Mac не засыпает · экран не гаснет" : "Запрет сна включён", symbol: "moon.stars.fill", tone: .active)
        }
        if displayWanted && displayActual {
            return Self(title: "Экран под защитой", detail: "Экран остаётся включённым.", symbol: "display", tone: .active)
        }
        if permissionReady == false {
            return Self(title: "Настройте NoSleep", detail: "Защиту экрана можно включить уже сейчас.", symbol: "moon.stars", tone: .neutral)
        }
        return Self(title: "Защита выключена", detail: systemActual ? "Сон запрещён другой настройкой macOS." : "Mac и экран работают в обычном режиме.", symbol: "moon.stars", tone: .neutral)
    }
}
