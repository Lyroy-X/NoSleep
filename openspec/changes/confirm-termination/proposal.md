# Proposal

## Why

При выключении Mac NoSleep немедленно снимает защиту и завершает процесс. Если пользователь или другое приложение отменяет выключение, NoSleep уже закрыт. В приложении отсутствует подтверждение завершения.

## What Changes

- Подтверждать завершение приложения только при выключении/перезапуске Mac до снятия защиты.
- Сохранять защиту и фоновую проверку при отмене или пока диалог открыт.
- Разрешать завершение только после явного подтверждения и успешного снятия защиты.
- Проверять отмену, подтверждение, повторный запрос и отказ снятия защиты изолированно от настоящего питания.

## Capabilities

### New Capabilities

- `application-termination`: подтверждение завершения и сохранение защиты при отмене.

### Modified Capabilities

Нет. В openspec/specs пока нет опубликованной спецификации завершения; связанный power-only-utility остаётся активным отдельным изменением.

## Impact

MenuApp в Sources/NoSleep.swift, целевые Swift-тесты и изолированный UI harness. README и документация проверок. Завершённая автоматизация GitHub Releases используется из main как основа релиза; нативные red-green proofs выполняются в macOS lanes. Установленное приложение и системные настройки питания не изменяются. Выбран локальный E2E без пользовательского ревью; обычный выход и выход из учётной записи остаются без диалога.

Final integration: automation was merged into main during verification. The candidate was rebased on a5589e08f11e7394b42db7b7ec7a5981822a415b; incoming automation/Intel contracts and changelog history are retained. Existing application/package input hashes match the verified DMG. Quality and full native checks are refreshed on this base; release/DMG metadata will bind to the final commit.
