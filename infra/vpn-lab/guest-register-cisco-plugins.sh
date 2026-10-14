#!/bin/bash
# Reproduce only four static installer links in the owned disposable VM.
# No host state, dynamic manifests, profiles, or credentials are copied.
set -euo pipefail
case $(/usr/sbin/sysctl -n hw.model) in VirtualMac*) ;; *) exit 64 ;; esac
[[ $(id -u) == 0 ]] || exit 65
task_lab_share=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
task_lab_expected_mac=$(/bin/cat "$task_lab_share/guest-owner-mac")
[[ "$task_lab_expected_mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || exit 66
task_lab_actual_mac=$(/sbin/ifconfig en0 | /usr/bin/awk '/ether / {print $2}')
[[ "$task_lab_actual_mac" == "$task_lab_expected_mac" ]] || exit 67
task_lab_base=/opt/cisco/secureclient/bin
for task_lab_app in 'Cisco Secure Client - AnyConnect VPN Service.app' 'Cisco Secure Client - Web Browser.app'; do
  /usr/bin/codesign --verify --strict --deep "$task_lab_base/$task_lab_app"
  /usr/bin/codesign -dv --verbose=2 "$task_lab_base/$task_lab_app" 2>&1 | /usr/bin/grep '^TeamIdentifier=DE8Y96K9QP$' >/dev/null
done
mkdir -p "$task_lab_base/plugins"
/usr/sbin/chown root:wheel "$task_lab_base/plugins"
chmod 755 "$task_lab_base/plugins"
for task_lab_plugin in api feedback ipsec webhelper; do
  task_lab_app='Cisco Secure Client - AnyConnect VPN Service.app'
  if [[ "$task_lab_plugin" == webhelper ]]; then
    task_lab_app='Cisco Secure Client - Web Browser.app'
  fi
  task_lab_name="pluginreg_vpn_${task_lab_plugin}.json"
  task_lab_source="$task_lab_base/$task_lab_app/Contents/Resources/$task_lab_name"
  task_lab_destination="$task_lab_base/plugins/$task_lab_name"
  test -f "$task_lab_source"
  if [[ -e "$task_lab_destination" || -L "$task_lab_destination" ]]; then
    [[ -L "$task_lab_destination" ]] || exit 68
    [[ $(/usr/bin/readlink "$task_lab_destination") == "$task_lab_source" ]] || exit 69
  else
    /bin/ln -s "$task_lab_source" "$task_lab_destination"
  fi
  /usr/sbin/chown -h root:wheel "$task_lab_destination"
done
echo 'Four static signed Cisco plugin links registered in the owned guest.'
