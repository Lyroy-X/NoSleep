#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
app="${NOSLEEP_BUILD_APP:-$project_dir/build/NoSleep.app}"
app=${app:A}
build_cache="${NOSLEEP_BUILD_CACHE:-$project_dir/build/module-cache}"
if [[ "$app" != *.app ]]; then
  print -u2 "Build output must be an .app bundle"
  exit 1
fi
if [[ -f "$app/Contents/MacOS/NoSleep" ]]; then
  if lsof_result=$(/usr/sbin/lsof -t -- "$app/Contents/MacOS/NoSleep" 2>&1); then
    print -u2 "This NoSleep is running. Close it or build a separate copy with NOSLEEP_BUILD_APP."
    exit 1
  else
    lsof_result_code=$?
    if [[ "$lsof_result_code" != 1 || -n "$lsof_result" ]]; then
      print -u2 "Cannot verify that this NoSleep is stopped. Build a separate candidate."
      exit 1
    fi
  fi
fi
if [[ -n "${NOSLEEP_SIGNING_CONFIG:-}" && ! -f "$NOSLEEP_SIGNING_CONFIG" ]]; then
  print -u2 "Requested NoSleep signing configuration is missing; no ad-hoc fallback."
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build_cache"
if [[ "${1:-}" == --universal ]]; then
  for cpu in arm64 x86_64; do
    mkdir -p "$build_cache/$cpu"
    swiftc -target "$cpu-apple-macos14.0" -module-cache-path "$build_cache/$cpu" "$project_dir"/Sources/*.swift -o "${app:h}/NoSleep-$cpu"
  done
  lipo -create "${app:h}/NoSleep-arm64" "${app:h}/NoSleep-x86_64" -output "$app/Contents/MacOS/NoSleep"
  minimum_os=14.0
else
  swiftc -target "$(uname -m)-apple-macos14.0" -module-cache-path "$build_cache" "$project_dir"/Sources/*.swift -o "$app/Contents/MacOS/NoSleep"
  minimum_os=14.0
fi
cp "$project_dir/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $minimum_os" "$app/Contents/Info.plist"
cp "$project_dir/Resources/NoSleep.icns" "$app/Contents/Resources/NoSleep.icns"
if [[ -n "${NOSLEEP_SIGNING_CONFIG:-}" ]]; then
  python3 "$project_dir/scripts/sign-local-development.py" sign "$app" --config "$NOSLEEP_SIGNING_CONFIG"
else
  codesign --force --sign - "$app"
fi
plutil -lint "$app/Contents/Info.plist"
print "$app"
