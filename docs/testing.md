# Проверки NoSleep

## Общий запуск

GitHub CI и обязательные доказательства изменённого кода описаны в [правилах качества](quality-gates.md). Нативные проверки CI выполняются только на Apple Silicon; Intel runner полностью отключён для всех будущих PR и общей проверки main до явного повторного включения; релиз зависит от полного CI и проверенного DMG. Успешный удалённый запуск подтверждается отдельно реальным Actions run.

- `./scripts/test.sh --core`: отдельная сборка, проверки сборочного runner, защиты установки, передачи защиты питания, контракта безопасности, unit-тесты.
- `./scripts/test.sh --ci`: те же проверки и полная диагностика с лимитом 200 МБ/RSS.
- `./scripts/test.sh --local`: проверки CI и локальный нативный UI E2E с изолированной моделью питания.

Runner использует `build/regression/NoSleep.app` и не перезаписывает работающую сборку. UI E2E компилирует текущие MenuApp/ApplicationMenu и проверяет отдельные переключатели, команды меню, общую кнопку, готовность первого запуска и отсутствие VPN в окне/снимке. Он не вызывает реальные функции питания, не подключается к сети и не обращается к Связке ключей. Исходники, логи и receipt сохраняются в `build/ui-acceptance/<id>/`.

## Компактный UI 3.5.0

`Sources/PresentationTests.swift` проверяет общий статус: обычные состояния, проверку прав, первый запуск, применение команды, отказ подтверждения, внешнюю настройку сна и успешный повтор. `python3 tests/compact_status_mutation.py` запускает оригинальный нативный fixture и его отдельную дефектную копию; потерянная проверка подтверждения сна должна привести к assertion, а не к ошибке компиляции.

Изолированный native shortcut test маршрутизирует корректное ⇧⌘A событие в счётчик действий без питания. Quality gate пересаживает этот тест в точный base snapshot, собирает его и требует поведенческий отказ старой декларации. Quality lane теперь выполняет тот же полный command на macOS для AppKit; все CI jobs используют ARM macos-15 без Intel matrix; универсальный DMG по-прежнему содержит обе архитектуры.

Локальный UI E2E также проверяет повторные команды, accessibility-имена, ширину/высоту текста и готовый режим без прокрутки в 440×430. Нативные PNG сохраняются в том же каталоге receipt для 440×430, увеличенного 700×560 и состояния настройки/ошибки в минимальном 440×360, в светлой, тёмной и обеих высококонтрастных темах, для overlay и legacy scrollbars (24 сочетания). Эти проверки используют current production UI и отдельный fail-closed backend. Они не измеряют FPS или энергопотребление реального приложения и не подтверждают поведение питания.

UI-ветка запускает в CI и локально `./scripts/test.sh --local` и `python3 tests/compact_status_mutation.py`; комплект DMG проверяется отдельно. После обновления базы main до a5589e0 применяется полный `scripts/check-quality.py` из main; UI-фикстуры в `Sources/UITests.swift` компилируются только с `NOSLEEP_UI_FIXTURE` и исполняются в изолированном E2E на обеих native CI архитектурах.

## Реальное питание

Подтверждение выключения/перезапуска проверяется unit-тестами причин Apple Event и локальным UI E2E: настоящие диалоги и кнопки, отмена через Enter/Escape, повторный запрос, запрет обхода открытого диалога, подтверждённое снятие защиты в модели, обычный выход без диалога, ошибка и повторная попытка. Unit-тест использует настоящий GuardEngine с FakePower для проверки восстановления фоновой проверки после ошибки. Тесты не отправляют системную команду выключения/перезапуска.

Полный системный сценарий требует отдельной ручной приёмки: запустить новую сборку, выбрать выключение/перезапуск Mac и нажать «Отмена» в NoSleep; убедиться, что Mac и приложение продолжают работать с прежней защитой. Реальное выключение, принудительное завершение, а также отмена другим приложением после подтверждённого выхода NoSleep не подтверждаются изолированным E2E. Если системный запрос не содержит распознаваемой причины, применяется обычный выход без диалога.

`tests/live_acceptance.py` меняет настройки сна и экрана и требует отдельного осознанного запуска. Он не включён в общий runner. Физическое закрытие крышки, запуск Intel и первая административная установка на новом аккаунте проверяются отдельно.

## Упаковка

Первая административная настройка, выключение/перезапуск, физическое закрытие крышки и Gatekeeper для скачанного приложения требуют отдельной явной команды на ручную приёмку. Наличие обеих архитектур в DMG не доказывает нативное выполнение на Intel.

`./scripts/package-dmg.sh` создаёт отдельную универсальную сборку. `python3 tests/dmg_acceptance.py build/NoSleep-universal.dmg` проверяет подпись, состав образа и расположение значков.

`python3 tests/dmg_acceptance.py --ci build/NoSleep-universal.dmg` сохраняет проверки содержимого, подписи, версии, архитектур, данных расположения значков и пикселей стрелки, но явно пропускает управление Finder. Он не подтверждает фактическое окно Finder.

## Очистка репозитория 3.5.1

`tests/public_repository_acceptance.py` проверяет отсутствие удалённой лаборатории и её зависимых VM-runner файлов, персональных путей и сломанных локальных ссылок в README. Проверка входит в каждый режим общего runner.

Самостоятельный мост `infra/power-handoff/bridge.swift` и его пять изолированных проверок сохранены; [границы проверки моста](power-handoff.md). Удалены только старые VM-операторы, зависящие от лаборатории.

Нативный self-test выполняет компилируемый old/new proof и критическую мутацию один раз; UI fixture проверяет меню без повторной компиляции, затем выполняет собственные настоящие диалоги и клавиши. Лимит UI остаётся 30 секунд.

## Automatic lock (3.6.0)

`tests/automatic_lock_acceptance.py` compiles native normal/refusal/boundary/retry
contracts and five isolated critical mutants. `tests/ui_acceptance.py` executes
the current compact UI with fake policy/power/store, including secure prompt,
cancellation, concurrency, combined actions, recovery and deferred termination.
No automated app test changes real host policy or an installed app.

Real macOS27 before/off/restored, manual-lock preservation and independent
controller-crash cleanup passed in the retained local fixture. Exact setup,
receipts, safety constraints and limits are in [test-vm.md](test-vm.md). Those
receipts validate the system route; the ported compact UI requires fresh local
and remote regression. Universal packaging does not prove Intel execution;
Intel CI remains disabled by the existing repository decision.

## Timed protection 4.1.0

The isolated native suite covers finite system/display leases, overlapping deadlines, baseline restoration, acquisition/refusal/retry, separate-process history and deletion, seven critical timer mutations, native popover fields and light/dark layouts. Updated native viewport acceptance retains the current-main fitting scroll view, keyboard shortcut, delayed completion and high-contrast/legacy-scroller cases at 600×620 with a 520-point minimum width for duration controls. No test operates the installed app or real power settings.

Manual sleep/wake, lid closure, first administrative setup, physical process interruption, shutdown/restart and downloaded-app Gatekeeper require separate explicit acceptance. Intel execution remains disabled by current-main CI policy; universal packaging is not an Intel runtime result.

The release CI found a native trailing-edge difference on macOS 15.7.9/Swift 6.1.2. An isolated local small-switch case reproduced a 10-point error before the fix; timer groups now fill their width just like the lock group. The retained alignment assertion also exercises regular/small/mini sizes and widths 520/600/700.

Idle duration actions use the native timer SF Symbol and the localized “Таймер” label; focused native checks cover disabled, running and completed states. The modal fixture validates the AppKit Return binding by activating its configured native default cell (physical keyboard delivery requires desktop focus and is not claimed); Escape still exercises the production local event monitor. This avoids depending on a background fixture stealing the user’s foreground application.
