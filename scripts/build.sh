#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
app="$project_dir/build/NoSleep.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$project_dir/build/module-cache"
swiftc -module-cache-path "$project_dir/build/module-cache" "$project_dir/Sources/NoSleep.swift" -o "$app/Contents/MacOS/NoSleep"
cp "$project_dir/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/Resources/NoSleep.icns" "$app/Contents/Resources/NoSleep.icns"
codesign --force --sign - "$app"
plutil -lint "$app/Contents/Info.plist"
print "$app"
