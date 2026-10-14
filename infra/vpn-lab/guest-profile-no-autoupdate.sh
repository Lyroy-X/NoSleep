#!/bin/bash
# Lab profile content-update control documented by Cisco. This changes neither
# TLS trust nor signature verification, and never targets a production profile.
set -euo pipefail
case $(/usr/sbin/sysctl -n hw.model) in VirtualMac*) ;; *) exit 64 ;; esac
[[ $(id -u) == 0 ]] || exit 65
task_lab_share=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
task_lab_mac=$(/bin/cat "$task_lab_share/guest-owner-mac")
[[ "$task_lab_mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || exit 66
[[ $(/sbin/ifconfig en0 | /usr/bin/awk '/ether / {print $2}') == "$task_lab_mac" ]] || exit 67
task_lab_target=/opt/cisco/secureclient/vpn/profile/NoSleepLab.xml
task_lab_source="$task_lab_share/NoSleepLab.xml"
task_lab_inputs="$task_lab_share/profile-change-inputs.plist"
task_lab_old_sha=$(/usr/libexec/PlistBuddy -c 'Print :previousSHA256' "$task_lab_inputs")
task_lab_new_sha=$(/usr/libexec/PlistBuddy -c 'Print :newSHA256' "$task_lab_inputs")
[[ "$task_lab_old_sha" =~ ^[0-9a-f]{64}$ && "$task_lab_new_sha" =~ ^[0-9a-f]{64}$ ]] || exit 68
[[ $(/usr/bin/shasum -a 256 "$task_lab_target" | /usr/bin/awk '{print $1}') == "$task_lab_old_sha" ]] || exit 69
[[ $(/usr/bin/shasum -a 256 "$task_lab_source" | /usr/bin/awk '{print $1}') == "$task_lab_new_sha" ]] || exit 70
/usr/bin/grep '<HostAddress>vpn-lab.invalid:4443</HostAddress>' "$task_lab_source" >/dev/null
/usr/bin/grep '<AutoUpdate UserControllable="false">false</AutoUpdate>' "$task_lab_source" >/dev/null
/usr/bin/xmllint --nonet --noout --schema /opt/cisco/secureclient/vpn/profile/AnyConnectProfile.xsd "$task_lab_source"
task_lab_native=$(/opt/cisco/secureclient/bin/vpn -s state)
[[ $(printf '%s\n' "$task_lab_native" | /usr/bin/grep 'state:' | /usr/bin/tail -n 1) == *'state: Disconnected'* ]] || exit 71
/usr/bin/install -o root -g wheel -m 644 "$task_lab_source" "$task_lab_target"
printf 'onlyOwnedLabProfileAutoUpdateDisabled=true previousProfileSHA256=%s newProfileSHA256=%s\n' "$task_lab_old_sha" "$task_lab_new_sha"
