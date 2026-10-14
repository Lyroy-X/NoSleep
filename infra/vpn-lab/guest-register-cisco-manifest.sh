#!/bin/bash
# Initialize only the disposable guest's missing installer metadata. The host's
# runtime manifest is never copied, and existing guest metadata is not replaced.
set -euo pipefail
case $(/usr/sbin/sysctl -n hw.model) in VirtualMac*) ;; *) exit 64 ;; esac
[[ $(id -u) == 0 ]] || exit 65
task_lab_share=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
task_lab_expected_mac=$(/bin/cat "$task_lab_share/guest-owner-mac")
[[ "$task_lab_expected_mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || exit 66
task_lab_actual_mac=$(/sbin/ifconfig en0 | /usr/bin/awk '/ether / {print $2}')
[[ "$task_lab_actual_mac" == "$task_lab_expected_mac" ]] || exit 67
task_lab_base=/opt/cisco/secureclient
task_lab_app="$task_lab_base/bin/Cisco Secure Client - AnyConnect VPN Service.app"
task_lab_tool="$task_lab_app/Contents/Helpers/manifesttool"
task_lab_xml="$task_lab_app/Contents/Resources/ACManifestVPN.xml"
task_lab_output="$task_lab_base/VPNManifest.dat"
[[ ! -e "$task_lab_output" && ! -L "$task_lab_output" ]] || exit 68
task_lab_inputs="$task_lab_share/manifest-inputs.plist"
task_lab_tool_sha=$(/usr/libexec/PlistBuddy -c 'Print :manifestToolSHA256' "$task_lab_inputs")
task_lab_xml_sha=$(/usr/libexec/PlistBuddy -c 'Print :staticManifestSHA256' "$task_lab_inputs")
[[ "$task_lab_tool_sha" =~ ^[0-9a-f]{64}$ && "$task_lab_xml_sha" =~ ^[0-9a-f]{64}$ ]] || exit 69
[[ $(/usr/bin/shasum -a 256 "$task_lab_tool" | /usr/bin/awk '{print $1}') == "$task_lab_tool_sha" ]] || exit 70
[[ $(/usr/bin/shasum -a 256 "$task_lab_xml" | /usr/bin/awk '{print $1}') == "$task_lab_xml_sha" ]] || exit 71
for task_lab_signed in "$task_lab_app" "$task_lab_tool"; do
  /usr/bin/codesign --verify --strict --deep "$task_lab_signed"
  /usr/bin/codesign -dv --verbose=2 "$task_lab_signed" 2>&1 | /usr/bin/grep '^TeamIdentifier=DE8Y96K9QP$' >/dev/null
done
# This is the vendor's installation command. It writes new local module metadata
# from the signed installation manifest, not an invented/unsigned substitute.
"$task_lab_tool" -i "$task_lab_base" "$task_lab_xml"
[[ -f "$task_lab_output" && ! -L "$task_lab_output" ]] || exit 72
task_lab_created_size=$(/usr/bin/stat -f '%z' "$task_lab_output")
[[ "$task_lab_created_size" -gt 0 && "$task_lab_created_size" -le 1048576 ]] || exit 73
printf 'guestManifestCreated=true existingOverwrite=false bytes=%s\n' "$task_lab_created_size"
/usr/bin/shasum -a 256 "$task_lab_output"
