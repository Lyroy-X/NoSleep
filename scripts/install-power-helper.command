#!/bin/zsh
set -euo pipefail
account=$(id -un)
account_uid=$(id -u)
if [[ ! "$account" =~ '^[A-Za-z0-9_.-]+$' ]]; then
  print 'Имя учётной записи содержит неподдерживаемые символы. Настройка остановлена.'
  exit 1
fi
rule_path="/private/etc/sudoers.d/nosleep_${account_uid}"
print '\nNoSleep — настройка защиты сна\n'
print 'Будут разрешены только две команды: включить и выключить запрет сна.'
print "Разрешение получит только ваша учётная запись: $account."
print 'Другие команды администратора разрешены не будут.\n'
read -r 'answer?Установить это правило? Введите да: '
if [[ "$answer" != да && "$answer" != yes ]]; then
  print 'Установка отменена.'; exit 0
fi
if [[ -e "$rule_path" ]]; then
  print 'Правило для этой учётной записи уже существует. Оно не изменено.'
else
  stage_dir=$(mktemp -d /private/tmp/nosleep-helper.XXXXXX)
  trap 'rm -f "$stage_dir/nosleep_power"; rmdir "$stage_dir"' EXIT
  printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n' "$account" > "$stage_dir/nosleep_power"
  /usr/sbin/visudo -cf "$stage_dir/nosleep_power"
  print '\nВведите пароль администратора. Символы пароля не отображаются.'
  sudo /usr/bin/install -o root -g wheel -m 0440 "$stage_dir/nosleep_power" "$rule_path"
  sudo /usr/sbin/visudo -cf "$rule_path"
fi
print '\nНастройка закончена. Откройте NoSleep из папки «Программы».\n'
read -r 'reply?Нажмите Enter, чтобы закрыть окно: '
