#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
# Packaging uses its own app output; the everyday running app must stay intact.
export NOSLEEP_BUILD_APP="${NOSLEEP_BUILD_APP:-$project_dir/build/release/NoSleep.app}"
export NOSLEEP_BUILD_CACHE="${NOSLEEP_BUILD_CACHE:-$project_dir/build/release-module-cache}"
package_app=${NOSLEEP_BUILD_APP:A}
image_output="${NOSLEEP_DMG_OUTPUT:-$project_dir/build/NoSleep-universal.dmg}"
image_output=${image_output:A}
if [[ "$image_output" != *.dmg ]]; then
  print -u2 "Package output must be a .dmg image"
  exit 2
fi
"$project_dir/scripts/build.sh" --universal
export PYTHONPATH="$project_dir/build/packaging-python${PYTHONPATH:+:$PYTHONPATH}"
python3 -c 'import ds_store, mac_alias'
work_dir=$(mktemp -d "$project_dir/build/dmg.XXXXXX")
mount_dir=""
cleanup() {
  if [[ -n "$mount_dir" ]] && mount | /usr/bin/grep -Fq " on $mount_dir "; then
    hdiutil detach "$mount_dir" >/dev/null || return
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
stage="$work_dir/staging"
mkdir -p "$stage/.background"
ditto "$package_app" "$stage/NoSleep.app"
ln -s /Applications "$stage/Программы"
swiftc -module-cache-path "$project_dir/build/module-cache" "$project_dir/scripts/dmg-background.swift" -o "$project_dir/build/dmg-background"
"$project_dir/build/dmg-background" "$stage/.background/background.png"
hdiutil create -size 32m -fs HFS+ -volname NoSleep -srcfolder "$stage" -format UDRW "$work_dir/writable.dmg"
hdiutil attach -nobrowse -plist "$work_dir/writable.dmg" > "$work_dir/attached.plist"
mount_dir=$(python3 -c 'import plistlib,sys; print(next(item["mount-point"] for item in plistlib.load(open(sys.argv[1],"rb"))["system-entities"] if "mount-point" in item))' "$work_dir/attached.plist")
python3 "$project_dir/scripts/configure-dmg.py" "$mount_dir"
sync
hdiutil detach "$mount_dir"
mkdir -p "${image_output:h}"
hdiutil convert "$work_dir/writable.dmg" -format UDZO -ov -o "$image_output"
print "$image_output"
