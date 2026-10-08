#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
"$project_dir/scripts/build.sh"
"$project_dir/build/NoSleep.app/Contents/MacOS/NoSleep" --self-test
