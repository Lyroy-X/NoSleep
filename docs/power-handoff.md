# Power handoff bridge

Это подготовленный инструмент и проверяемая последовательность для R1/R10.
Документ сам по себе не выполняет замену MAIN. Root выполняет её только после
полной приёмки финальной NoSleep; лабораторная проверка не заменяет эту приёмку.

## Граница защиты

`PreventUserIdleSystemSleep` (иногда называется ProtectIdle) удерживает систему
от сна по бездействию. Он не заменяет глобальный `IOPMrootDomain.SleepDisabled=1`
при закрытой крышке. Отдельный `PreventUserIdleDisplaySleep` удерживает экран.
В production NoSleep переключатель сна использует `PreventSystemSleep`, экран —
`KeepDisplayAwake`; bridge не читает и не меняет эти preferences.
Оператор передаёт проверенное намерение экрана явно как `--wanted-display 0`
или `--wanted-display 1`. Значение обязательно, не угадывается и записывается
в state.json. Во всех путях передачи bridge требует idle assertion нового/
возобновлённого/перезапущенного приложения; display assertion требуется только
при `wantedDisplay=true`. Собственные два временных assertions bridge удерживает
при обоих намерениях. Пользовательские preferences для прохождения проверки не меняются.

Bridge **никогда не меняет глобальный запрет сна**. На старте он требует уже
установленный `SleepDisabled=1`, создаёт только собственные два IOPM assertions,
проверяет их Level=On и ещё раз читает глобальное состояние. При ошибке создания
он освобождает только уже созданные им assertions. При удержании каждые 100 мс
проверяет свои assertions и глобальную защиту; bounded state.json обновляется
раз в секунду. Замеченная потеря защиты, ошибка чтения или сохранения — sticky
native failure: все три пути release/rollback запрещены даже после восстановления
текущих readings. Failure snapshot сохраняется немедленно, до обработки дальнейшего
handoff действия. Запись использует temporary file + fsync(file) + atomic rename +
fsync(directory); typed failure/prepared/released/refused события добавляются в
mode0600 events.jsonl с file/directory fsync. Snapshot ограничен 8 КиБ, event —
1 КиБ, весь event-файл — 64 КиБ. Ошибка persistence оставляет bridge holding и
не допускает PASS. Failure flags не очищаются в текущем session.
Эти выборки подтверждают наблюдавшиеся состояния, а не математическую гарантию
от внешнего изменения между выборками. Никаких глобальных setters в bridge нет.

В bridge отсутствуют pmset/sudo, установка helper, настройки Cisco, команды
завершения NoSleep и отправка сигналов другим процессам. Нет TTL и автоматического
release. SIGINT/SIGTERM/SIGHUP во время handoff игнорируются, чтобы закрытие
терминала не сняло временную защиту. SIGKILL/крах/перезагрузка остаются системными
ограничениями: assertions принадлежат живому процессу. Глобальное состояние он
и в этих случаях не возвращает в 0.

## Сборка и безопасные контракты

```sh
python3 tests/power_handoff_contract.py
swiftc -target "$(uname -m)-apple-macos14.0" -parse-as-library infra/power-handoff/bridge.swift -o build/power-handoff/bridge
```

Первый runner компилирует bridge и запускает fake Power/Identity/Persistence
контракты и fsync/atomic-write тесты только в собственном build-каталоге.
Он не создаёт реальные IOPM assertions на MAIN. Перед actual execution фиксируются
SHA256 Swift source и бинарника. Standalone bridge можно отдельно ad-hoc подписать
и проверить `codesign --verify --strict`; это не Developer ID/notarization.
Явный macOS14 deployment target обязателен для существующей Sonoma VM: текущий
SDK без `-target` создаёт бинарник minOS27, который dyld гостя откажется запускать.

## Guarded MAIN sequence для root

1. Получить свежий read-only baseline: Cisco Connected, тот же agent PID, хеши
   profile/policy; SleepDisabled=1, assertions и актуальные желаемые состояния
   старой NoSleep. Не брать PID из старого handoff без новой проверки.
2. Завершить все обязательные QA, universal/DMG и freeze новой сборки. Проверить
   подпись, bundle ID/version и SHA бинарника staging-копии. Не записывать новую
   сборку поверх ещё работающего старого executable. Сохранить old bundle и его
   бинарник для rollback. Не ставить новый privileged helper в этой операции.
3. Подготовить обычный запуск новой NoSleep с сохранённой защитой и recovery OFF.
   Зафиксировать прежний `KeepDisplayAwake` и передать соответствующее точное
   `--wanted-display 0|1`: для текущего MAIN sleep ON/display OFF это `0`.
   При display OFF новый процесс подтверждает idle assertion; отсутствие display
   assertion соответствует желанию пользователя и не препятствует release.
4. Создать новый private state-dir mode0700, новый UUID session и запустить bridge
   отдельно от терминальной process group. В аргументах передать **свежий** exact
   old PID/path/SHA и ожидаемый installed new path/SHA:

   ```text
   bridge --hold --old-pid <OLD_PID> --old-executable <OLD_EXECUTABLE>
     --old-sha256 <OLD_BINARY_SHA256> --new-executable <NEW_EXECUTABLE>
     --new-sha256 <NEW_BINARY_SHA256> --state-dir <PRIVATE_DIRECTORY>
     --session <NEW_UUID> --wanted-display <EXACT_0_OR_1>
   ```

   Проверить state.json: phase=holding, sleepDisabled=true, ownAssertionsOn=true,
   все четыре failure flags=false и wantedDisplay соответствует baseline. Проверить
   свежесть samples/state и events.jsonl: ранее записанный failure запрещает
   продолжение независимо от текущей защиты. Он сохраняет также exact old process start seconds
   и microseconds; эта lifetime identity нужна против повторного использования PID.
   Одного stdout `bridgeHolding` недостаточно для продолжения.
5. Root повторно проверяет old lifetime/path/hash и новый ready state, затем
   отправляет SIGSTOP **только этому exact old PID**. Не использовать normal Quit,
   `--command quit`, `killall`, `pkill`, SIGTERM: обычный shutdown старой NoSleep
   может записать глобальный запрет сна в 0. После SIGSTOP проверить stopped state,
   bridge assertions и SleepDisabled=1. Cisco и его GUI не затрагивать.
6. До SIGKILL rollback обратим: SIGCONT тому же lifetime old PID; подтвердить его
   idle assertion, требуемый display assertion только при display ON и SleepDisabled=1. Затем разрешён control action
   `abort-old-resumed`. Bridge сам проверит ту же old lifetime и отсутствие stopped
   state, требуемые по pinned intent assertions и глобальную защиту; освобождает только свои assertions.
7. Только при сохранённых guards root отправляет SIGKILL **только exact old PID**.
   Это контролируемая замена, которая обходит его normal shutdown. Подтвердить, что
   старый process исчез; singleton новой NoSleep иначе вернётся к старой копии.
   Bridge продолжает держать защиту. Теперь установить проверенный bundle atomic
   replacement с сохранённым rollback artifact и выполнить обычный запуск новой
   NoSleep. Не запускать power verification modes на MAIN: некоторые снимают защиту.
8. Подтвердить новый PID/path/hash/signature, фактический SleepDisabled=1 и **его**
   idle assertion Level=On, display assertion Level=On только при pinned display ON,
   сохранённое состояние переключателя экрана, работающий UI, recovery OFF и неизменный
   corporate baseline. Только после этого передать release request:

   ```json
   {"session":"<SAME_SESSION_UUID>","request":"<FRESH_REQUEST_UUID>","action":"release-new","pid":12345}
   ```

   Запись command.json должна быть atomic, mode0600, owner того же пользователя.
   PID в примере — placeholder. Bridge сравнит процесс с ожидаемыми new path/SHA,
   проверит отсутствие old PID, глобальную защиту, собственные assertions bridge и
   минимально требуемые assertions нового PID. Перед release fsync-сохраняется
   prepared event/state, затем повторно читаются target assertions/lifetime/path/hash
   и, после медленных чтений, собственные assertions bridge и SleepDisabled.
   Эти проверки остаются последовательными выборками OS; атомарной проверки
   состояния всех процессов macOS API не предоставляет.
   Неудачный target readiness request не вызывает release; retry требует новый
   request UUID. Любой sticky protection/read/persistence failure блокирует retry
   и оба rollback release в текущем session. Нельзя очистить flag восстановлением
   предпочтения или новым request UUID.
9. Дождаться phase=released-to-new, ownAssertionsOn=false, fsync-сохранённого released
   event и нормального terminal exit0 именно owned bridge; повторно проверить
   target assertions/global/installed app. `release-prepared`, живой процесс,
   устаревший state, failure event или ненулевой/crash exit не означают PASS. Сохранить bridge
   receipt/source/binary SHA и свежую installed NoSleep/Cisco/power проверку.
   Failure flag в receipt нельзя объявлять PASS после восстановления.

После release завершающая receipt также fsync-сохраняется. Если эта запись
не удалась, bridge пытается вновь создать только свои два assertions и сохраняет
sticky persistence failure; release не считается успешным. Отказ повторного
создания, filesystem failure и crash в этой последовательности не обещают
непрерывность bridge assertions. Поэтому final phase без нормального terminal
exit и свежего независимого target/global proof недостаточна. До записи
prepared receipt любые persistence failures происходят при ещё удерживаемых
assertions; функция never writes global power. Никакой fsync здесь не доказывает
устойчивость к отказу устройства хранения или питанию всей машины.

После old SIGKILL SIGCONT уже невозможен. При ошибке нового запуска bridge держится
до успешного проверенного запуска. Root может остановить/удалить только exact failed
new PID с теми же guards и без normal shutdown, вернуть сохранённый old bundle
**по исходному pinned old path** и запустить его заново. Глобальная защита остаётся в
1. Это новая lifetime, поэтому `abort-old-resumed` её намеренно отклоняет. Только
после проверки нового PID старого бинарника, его исходных path/SHA, idle assertion,
display assertion только при pinned display ON, сохранённого прежнего намерения и
глобального состояния используется explicit control action
`rollback-old-restarted` с этим новым PID. Bridge проверяет эту альтернативу так же
строго и записывает phase=released-to-restarted-old. Такой rollback не является
успешной установкой новой версии. Не выключать bridge и не вызывать normal shutdown
новой NoSleep, пока alternative protection не подтверждена.

## Только existing owned VM: реальная проверка lifecycle

`bridge --lab-lifecycle` сначала требует UID501, VirtualMac и exact MAC
`42:35:8c:14:fd:0c`, затем использует тот же SleepDisabled=1 prerequisite. Он проверяет
реальную process identity, создаёт assertions, проверяет Level по ID и по owner PID
через IOPMCopyAssertionsByProcess и освобождает только свои два; сравнивает global before/after.
Физическое закрытие крышки не выполняется и не считается проверенным.

Оператор вправе временно установить SleepDisabled=1 **только в уже принадлежащей
лаборатории VM**, предварительно сохранив exact prior setting; после завершения
восстановить prior setting. Эти pmset действия находятся вне bridge и выполняются
только через `infra/vpn-lab/guest_command.py` с existing vsock/hardware/MAC guards.
Все immutable transferred bytes проверяются до запуска. Безопасное восстановление
обязательно и при отказе bridge; никаких изменений MAIN или Cisco GUI/network.

Неподтверждённая реальная lifecycle-проверка, отсутствие нового assertions proof,
ошибка чтения или потеря SleepDisabled — блокер actual handoff, а не основание
считать R1/R10 выполненными.

## Обязательная полная проверка old/new в existing owned VM

`--lab-lifecycle` доказывает только создание и release собственных assertions
моста. Она не является проверкой установки или rollback. После freeze финальных
байтов отдельно нужны три реальные последовательности через existing owned vsock:

1. Точная историческая NoSleep, sleep ON/display OFF/recovery OFF; bridge holding;
   revalidated old SIGSTOP и SIGCONT той же lifetime; `abort-old-resumed` подтверждает
   её idle assertion и global SleepDisabled1, освобождает только bridge assertions.
2. Та же исходная конфигурация; bridge holding; exact old SIGSTOP/SIGKILL; atomic
   replacement сохранённого bundle и обычный запуск final new NoSleep. Проверяются
   new path/hash/signature/lifetime, сохранённые sleep ON/display OFF/recovery OFF,
   idle assertion по owner PID, отсутствие display assertion у new и global1.
   Atomic request `release-new` завершает передачу, не меняя preferences.
3. Отдельный session: после old SIGKILL контролируемый отказ нового запуска.
   Bridge продолжает holding. Возвращается pinned old bundle на исходный guest path,
   обычный запуск создаёт новую old lifetime с сохранёнными preferences. Старый
   `abort-old-resumed` её не принимает; `rollback-old-restarted` проверяет новый PID,
   old path/SHA, idle/global1 и освобождает bridge. Результат обозначается rollback,
   а не успешной установкой new.

До выполнения сохраняются targeted guest preferences с присутствием/отсутствием
ключей и prior power state; после сценариев они восстанавливаются только в owned VM.
Код old/new переносится immutable hash-named файлами и проверяется в госте до запуска.
Используются public lab inputs, без корпоративных данных. При display ON нужна
отдельная проверка обязательного display assertion. Synthetic contracts покрывают
оба намерения, missing assertions, wrong configuration, hash/PID/lifetime ошибки,
SleepDisabled0, потерю собственных assertions внутри slow external proof,
target assertion/PID lifetime changes во время проверки, durable-preparation race,
sticky failure после restoration, failed persistence и crash target, при котором bridge
остаётся holding без TTL. Crash самого bridge/SIGKILL снимает его OS-owned assertions
и остаётся системным ограничением, не обещанием непрерывности.

Каждый сценарий сохраняет source/binary hashes, точные lifetime IDs, sampled global1,
assertions по владельцу, session/request IDs, commands/phase, typed event history,
file/directory fsync proof и failure latches. Если Cisco в lab уже
Connected, серверный fingerprint и tunneled nonce до/после должны сохраниться без
connect/GUI/network действий внутри handoff. Физическая крышка не считается проверенной.
До полной current old/new VM проверки и финальной VPN приёмки MAIN install запрещён.

## Постоянный owned-VM runner

`infra/power-handoff/run_owned_vm.py` содержит четыре явных режима. Без режима
runtime не загружается. `--make-manifest` и `--prepare` выполняют только локальную
проверку/сборку/копирование артефактов; они не обращаются к VM или power APIs.
`guest_operator.py` исполняется только через существующий guarded virtio-vsock,
требует VirtualMac, UID501, console admin и точную MAC до каждой мутации.
Он переносится с тем же именем `guest_operator.py`, чтобы не затенять стандартный
Python-модуль `operator`. Контракт проверяет запуск перенесённого файла отдельным
интерпретатором до любого hardware/power action.
`owned_vm_probe.swift` — отдельный процесс только на чтение: public IORegistry,
IOPMCopyAssertionsByProcess, proc lifetime/hash и ровно три targeted boolean preferences.
Он не создаёт assertions, не меняет power/preferences, не читает Keychain и не
выполняет экспорт domain. Helper собирается arm64/minOS14.

Подготовить code-only old/new ZIP с корнем `NoSleep.app`. Старый архив разрешено
создать только чтением MAIN bundle, никогда не переписывая или запуская его:
historical executable должен иметь SHA `3f27d94d0532b3c8a608bf99cb3208d3eab9e812c02f9c7eae80db67db7e9ecd`.
Readiness проверяет свежий UI и независимые три boolean preferences. Только этот
точный historical SHA допускает отсутствие `recoveryEnabled` в старой UI-схеме;
новый executable обязан явно сообщать `recoveryEnabled=false`. Оба требуют sleep ON,
прикреплённый display intent и recovery preference OFF.
Новый ZIP должен совпасть по executable/Info SHA и source hashes с отдельно
полученным build receipt. Для bridge закреплены reviewed source `57eb42f2…`
и exact reviewed binary `42c74464…`; пересборка/замена требует нового freeze/review.

```text
python3 infra/power-handoff/run_owned_vm.py --make-manifest
  --old-archive <OWNED_OLD_ZIP> --new-archive <OWNED_FINAL_NEW_ZIP>
  --bridge <EXACT_REVIEWED_42C74464_BINARY> --wanted-display 0
  --candidate-receipt <CURRENT_BUILD_RECEIPT> --candidate-receipt-sha256 <BUILD_RECEIPT_SHA>
  --output <BUILD_POWER_HANDOFF_OWNED_MANIFEST_PATH>

python3 infra/power-handoff/run_owned_vm.py --prepare
  --manifest <MANIFEST_PATH> --manifest-sha256 <EXACT_MANIFEST_SHA>
```

В manifest обязательны source/build/runner hashes, оба архива, точные binary/Info SHA,
намерение экрана и required connected tunnel. Prepare создаёт fresh execution UUID,
immutable payload в private read-only guest share и `prepared.json` с config SHA.
Архивы имеют ограничение размера/числа файлов; traversal и symlinks отвергаются
до извлечения. Old/new/helper/bridge bytes сверяются после переноса, перед запуском
и при proof; NoSleep bundle signature проверяется в guest. Эти результаты называются
preparation, а не actual handoff PASS.

Только после отдельного разрешения root и terminal auth acceptance:

```text
python3 infra/power-handoff/run_owned_vm.py --run-owned-lab
  --prepared <PREPARED_RECEIPT_PATH> --prepared-sha256 <EXACT_PREPARED_SHA>
```

До remote dispatch runner требует одну connected сессию exact owned server и
повторно проверяет current source/build freeze. В госте требуется отсутствие
конкурирующих NoSleep/bridge; owned operator удерживает отдельный flock. Backup
содержит только presence/value boolean `PreventSystemSleep`, `KeepDisplayAwake`,
`CiscoGUIRecoveryEnabled` и prior global state, сохраняется с atomic/fsync до действий.
Fixture intent sleep ON/display OFF/recovery OFF задаётся явно; display ON требует
отдельного manifest с `--wanted-display 1`, не используется для прохождения OFF.

Runner выполняет три обычных app lifecycle сценария: same-lifetime SIGSTOP/CONT abort;
exact old SIGKILL + atomic bundle replacement + ordinary final new release; реально
запущенный final new SIGSTOP/readiness refusal + guarded kill + original-path old
restart и explicit restarted-old rollback. Normal Quit/SIGTERM/all-off не используются.
Каждый bridge request проверяет durable state/events, все sticky flags, actual owner
assertions, intent и normal terminal exit0.
UUID запроса сравнивается как значение UUID в state и released event: регистр
строкового представления Swift Codable/Python не влияет на совпадение.
Принимается только полная форма 8-4-4-4-12 hexadecimal; braces, URN, отсутствие
или лишние дефисы, пробелы и переносы отвергаются в state и released event.
После release следует новый независимый target/global/UI/prefs proof, fresh nonce
через существующий utun и проверка сохранности
server session fingerprint. Никаких connect/auth/Cisco/route/profile edits здесь нет.

Каждый app/bridge spawn сразу journaled до ожидания identity/readiness. Transport
timeout, unknown identity или live bridge сохраняют тот же execution checkpoint
и actors; повторный dispatch того же execution запрещён. Нельзя объявлять процесс
завершённым по файлу или timeout. Следующий шаг только inspection того же checkpoint:

```text
python3 infra/power-handoff/run_owned_vm.py --inspect-owned-lab
  --prepared <SAME_PREPARED_RECEIPT_PATH> --prepared-sha256 <SAME_PREPARED_SHA>
```

Inspection не посылает signals и не меняет preferences/power; читает текущие реальные
operator/bridge/app PID lifetimes, global/owner assertions и targeted preferences.
Для каждого checkpoint actor возвращаются fresh process/assertion snapshot,
same-lifetime match и отдельный provisional marker. PID reuse, другой SHA/path или
неподтверждённая initial identity не выдаются за совпавший checkpoint; stopped status
показывается в snapshot и не меняет birthtime identity.
Если failure оставил живой bridge, автоматическая очистка/restore откладывается:
она не должна снять временную защиту или создать конкурирующий процесс. После всех
успешных случаев только exact owned app SIGKILL/reap, затем restore трёх ключей с
исходной семантикой отсутствия и exact prior global state; restored state проверяется.
MAIN app, power, Cisco, сеть и clipboard этим runner никогда не управляются.
