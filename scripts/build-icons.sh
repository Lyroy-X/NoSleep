#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
iconset="$project_dir/build/brand/NoSleep.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$project_dir/Resources/NoSleep-icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$project_dir/Resources/NoSleep-icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$project_dir/Resources/NoSleep.icns"
print "Built $project_dir/Resources/NoSleep.icns"
