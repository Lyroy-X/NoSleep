#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
app="$project_dir/build/NoSleep.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$project_dir/build/module-cache"
if [[ "${1:-}" == --universal ]]; then
  for cpu in arm64 x86_64; do
    mkdir -p "$project_dir/build/module-cache/$cpu"
    swiftc -target "$cpu-apple-macos14.0" -module-cache-path "$project_dir/build/module-cache/$cpu" "$project_dir/Sources/NoSleep.swift" -o "$project_dir/build/NoSleep-$cpu"
  done
  lipo -create "$project_dir/build/NoSleep-arm64" "$project_dir/build/NoSleep-x86_64" -output "$app/Contents/MacOS/NoSleep"
  minimum_os=14.0
else
  swiftc -module-cache-path "$project_dir/build/module-cache" "$project_dir/Sources/NoSleep.swift" -o "$app/Contents/MacOS/NoSleep"
  minimum_os=12.0
fi
cp "$project_dir/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $minimum_os" "$app/Contents/Info.plist"
cp "$project_dir/Resources/NoSleep.icns" "$app/Contents/Resources/NoSleep.icns"
codesign --force --sign - "$app"
plutil -lint "$app/Contents/Info.plist"
print "$app"
