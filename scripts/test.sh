#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
mode="${1:---core}"
if [[ "$mode" != --core && "$mode" != --ci && "$mode" != --local ]]; then
  print -u2 "Usage: scripts/test.sh [--core|--ci|--local]"
  exit 2
fi
test_root="$project_dir/build/regression"
mkdir -p "$test_root"
if ! mkdir "$test_root/run.lock" 2>/dev/null; then
  print -u2 "Another regression run is active; inspect build/regression/run.lock before starting again."
  exit 1
fi
trap 'rmdir "$test_root/run.lock"' EXIT
export NOSLEEP_BUILD_APP="$test_root/NoSleep.app"
export NOSLEEP_BUILD_CACHE="$test_root/module-cache"
export NOSLEEP_APP="$NOSLEEP_BUILD_APP"
python3 "$project_dir/tests/release_acceptance.py"
python3 "$project_dir/tests/quality_acceptance.py"
python3 "$project_dir/tests/quality_runner_acceptance.py"
python3 "$project_dir/tests/build_runner_acceptance.py"
python3 "$project_dir/tests/public_repository_acceptance.py"
python3 "$project_dir/tests/power_handoff_contract.py"
python3 "$project_dir/tests/power_helper_installer_contract.py"
python3 "$project_dir/tests/automatic_lock_acceptance.py"
python3 "$project_dir/tests/timed_protection_acceptance.py"
python3 "$project_dir/tests/control_dependencies_acceptance.py"
python3 "$project_dir/tests/power_process_acceptance.py"
python3 "$project_dir/tests/quit_routing_acceptance.py"
python3 "$project_dir/tests/presentation_acceptance.py"
"$project_dir/scripts/build.sh"
python3 "$project_dir/tests/brand_assets_acceptance.py"
swift -module-cache-path "$test_root/module-cache" "$project_dir/tests/icon_background_acceptance.swift" "$NOSLEEP_APP" "$project_dir/Resources/NoSleep-icon.png"
python3 "$project_dir/tests/safety_contract.py" "$NOSLEEP_APP"
if [[ "$mode" == --core ]]; then
  "$NOSLEEP_APP/Contents/MacOS/NoSleep" --self-test
else
  # The budget fixture includes all self-tests and measures RSS in its own directory.
  python3 "$project_dir/tests/diagnostics_budget_acceptance.py"
fi
if [[ "$mode" == --local ]]; then
  python3 "$project_dir/tests/ui_acceptance.py" --no-screenshots
  python3 "$project_dir/tests/lifecycle_acceptance.py"
  python3 "$project_dir/tests/control_dependencies_acceptance.py" --ui-mutations
fi
print "PASS: NoSleep regression checks ($mode); working app and real Cisco were not controlled"
