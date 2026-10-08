#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
"$project_dir/scripts/build.sh" --universal
stage="$project_dir/build/dmg-staging"
if [[ -e "$stage" ]]; then
  print 'DMG staging already exists; inspect and remove build/dmg-staging before packaging again.'
  exit 1
fi
mkdir -p "$stage"
ditto "$project_dir/build/NoSleep.app" "$stage/NoSleep.app"
ln -s /Applications "$stage/Applications"
cp "$project_dir/scripts/install-power-helper.command" "$stage/Настроить защиту сна.command"
cp "$project_dir/Resources/INSTALL-ru.txt" "$stage/Сначала прочитай.txt"
chmod 755 "$stage/Настроить защиту сна.command"
hdiutil create -volname NoSleep -srcfolder "$stage" -format UDZO "$project_dir/build/NoSleep-universal.dmg"
print "$project_dir/build/NoSleep-universal.dmg"
