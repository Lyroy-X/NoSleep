#!/bin/zsh
set -euo pipefail
account=$(id -un)
if [[ ! "$account" =~ '^[A-Za-z0-9_.-]+$' ]]; then
  print 'Unsupported account name'; exit 1
fi
stage_dir=$(mktemp -d /private/tmp/nosleep-helper.XXXXXX)
trap 'rm -f "$stage_dir/nosleep_power"; rmdir "$stage_dir"' EXIT
printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n' "$account" > "$stage_dir/nosleep_power"
/usr/sbin/visudo -cf "$stage_dir/nosleep_power"
print 'This grants only the current account passwordless access to two sleep commands.'
print 'Enter the administrator password if you agree.'
if sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 && sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  print 'The required commands are already allowed. No change made.'
else
  if [[ -e /private/etc/sudoers.d/nosleep_power ]]; then
    print 'An existing helper rule was found. Review it before replacing.'; exit 1
  fi
  sudo /usr/bin/install -o root -g wheel -m 0440 "$stage_dir/nosleep_power" /private/etc/sudoers.d/nosleep_power
  sudo /usr/sbin/visudo -cf /private/etc/sudoers.d/nosleep_power
fi
