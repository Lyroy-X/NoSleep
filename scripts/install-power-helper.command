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
  print '\nВведите пароль администратора. Символы пароля не отображаются.'
  # Generate and validate the rule inside the privileged process. A file owned
  # by the calling user must never be reread after the administrator prompt.
  sudo /bin/zsh -c '
    set -euo pipefail
    account=$1
    account_uid=$2
    [[ "$account" =~ "^[A-Za-z0-9_.-]+$" && "$account_uid" =~ "^[0-9]+$" && "$account_uid" != 0 ]] || exit 1
    rule_path="/private/etc/sudoers.d/nosleep_${account_uid}"
    [[ ! -e "$rule_path" && ! -L "$rule_path" ]] || exit 1
    umask 077
    stage_dir=$(/usr/bin/mktemp -d /private/tmp/NoSleep-root.XXXXXX)
    trap "/bin/rm -f \"$stage_dir/power-rule\"; /bin/rmdir \"$stage_dir\"" EXIT
    /usr/bin/printf "%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n" "$account" > "$stage_dir/power-rule"
    /usr/sbin/visudo -cf "$stage_dir/power-rule"
    [[ ! -e "$rule_path" && ! -L "$rule_path" ]] || exit 1
    /usr/bin/install -o root -g wheel -m 0440 "$stage_dir/power-rule" "$rule_path"
    /usr/sbin/visudo -cf "$rule_path"
  ' -- "$account" "$account_uid"
fi
print '\nНастройка закончена. Откройте NoSleep из папки «Программы».\n'
read -r 'reply?Нажмите Enter, чтобы закрыть окно: '
