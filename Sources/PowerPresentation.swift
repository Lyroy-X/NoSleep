import Foundation

struct PowerPresentation: Equatable {
    enum Tone { case neutral, active, attention }
    let title: String
    let detail: String
    let symbol: String
    let tone: Tone

    static func make(systemWanted: Bool, systemActual: Bool, displayWanted: Bool, displayActual: Bool,
                     permissionReady: Bool?, busy: Bool, hasError: Bool,
                     lockEnabled: Bool = false, lockRecovery: Bool = false, lockIssue: String? = nil) -> PowerPresentation {
        if busy {
            return Self(title: "Применяю настройки…", detail: "Дождитесь подтверждения macOS.", symbol: "hourglass", tone: .neutral)
        }
        if hasError || (systemWanted && !systemActual) || (displayWanted && (!displayActual || !systemWanted || !systemActual)) {
            return Self(title: "Проверьте защиту", detail: "Не удалось подтвердить действие. Подробности ниже.", symbol: "exclamationmark.triangle", tone: .attention)
        }
        if lockIssue != nil || lockRecovery {
            return Self(title: "Проверьте автоблокировку", detail: lockIssue ?? "Доступно восстановление исходной настройки.",
                        symbol: "lock.trianglebadge.exclamationmark", tone: .attention)
        }
        if permissionReady == nil {
            return Self(title: "Проверяю готовность…", detail: "Проверяю доступ к защите сна.", symbol: "hourglass", tone: .neutral)
        }
        if systemWanted && systemActual {
            return Self(title: "Mac под защитой", detail: displayWanted && displayActual ? "Mac не засыпает · экран не гаснет" : "Запрет сна включён", symbol: "moon.stars.fill", tone: .active)
        }
        if permissionReady == false {
            return Self(title: "Настройте NoSleep", detail: "Для защиты сна и экрана нужна первоначальная настройка.", symbol: "moon.stars", tone: .neutral)
        }
        if lockEnabled {
            return Self(title: "Автоблокировка отключена", detail: "Сон и экран — по настройкам macOS.", symbol: "lock.open", tone: .active)
        }
        return Self(title: "Защита выключена", detail: systemActual ? "Сон запрещён другой настройкой macOS." : "Mac и экран работают в обычном режиме.", symbol: "moon.stars", tone: .neutral)
    }
}
