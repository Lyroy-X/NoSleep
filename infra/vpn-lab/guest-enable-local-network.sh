#!/bin/bash
# Guest-only, finite local DNS/connectivity precondition, no external uplink.
set -euo pipefail
case $(/usr/sbin/sysctl -n hw.model) in VirtualMac*) ;; *) exit 64 ;; esac
[[ $(id -u) == 0 ]] || exit 65
task_lab_share=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
task_lab_expected_mac=$(/bin/cat "$task_lab_share/guest-owner-mac")
[[ "$task_lab_expected_mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || exit 66
task_lab_actual_mac=$(/sbin/ifconfig en0 | /usr/bin/awk '/ether / {print $2}')
[[ "$task_lab_actual_mac" == "$task_lab_expected_mac" ]] || exit 67
task_lab_expected_sha=$(/bin/cat "$task_lab_share/guest-local-network.sha256")
[[ "$task_lab_expected_sha" =~ ^[0-9a-f]{64}$ ]] || exit 68
task_lab_sha=$(/usr/bin/shasum -a 256 "$task_lab_share/guest-local-network" | /usr/bin/awk '{print $1}')
[[ "$task_lab_expected_sha" == "$task_lab_sha" ]] || exit 69
if /bin/launchctl print system/local.nosleep.vpn-lab.network >/dev/null 2>&1; then
  echo 'Refused: the owned guest network helper is already registered.' >&2
  exit 70
fi
mkdir -p /Users/admin/NoSleepLab
/bin/cp "$task_lab_share/guest-local-network" /Users/admin/NoSleepLab/guest-local-network
/usr/sbin/chown root:wheel /Users/admin/NoSleepLab/guest-local-network
chmod 755 /Users/admin/NoSleepLab/guest-local-network
cat > /Library/LaunchDaemons/local.nosleep.vpn-lab.network.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>local.nosleep.vpn-lab.network</string>
 <key>ProgramArguments</key><array><string>/Users/admin/NoSleepLab/guest-local-network</string><string>--owner-mac</string><string>$task_lab_expected_mac</string><string>--vpn-guest-interface</string></array>
 <key>RunAtLoad</key><true/>
 <key>StandardOutPath</key><string>/dev/null</string>
 <key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
PLIST
/usr/sbin/chown root:wheel /Library/LaunchDaemons/local.nosleep.vpn-lab.network.plist
chmod 644 /Library/LaunchDaemons/local.nosleep.vpn-lab.network.plist
/bin/launchctl bootstrap system /Library/LaunchDaemons/local.nosleep.vpn-lab.network.plist
# Changing DNS on this verified VM does not change host DNS or route tables.
/usr/sbin/networksetup -setdnsservers Ethernet 127.0.0.1
task_lab_self_ip=$(/sbin/ifconfig en0 | /usr/bin/awk '/inet / {print $2; exit}')
# Remove only our previous .invalid entry; preserve every unrelated host entry.
task_lab_hosts=$(/usr/bin/mktemp /etc/nosleep-lab-hosts.XXXXXX)
/usr/bin/awk '$0 !~ /^[0-9.]+[[:space:]]+vpn-lab[.]invalid([[:space:]]|$)/ {print}' /etc/hosts > "$task_lab_hosts"
echo "$task_lab_self_ip vpn-lab.invalid" >> "$task_lab_hosts"
/usr/sbin/chown root:wheel "$task_lab_hosts"
chmod 644 "$task_lab_hosts"
/bin/mv "$task_lab_hosts" /etc/hosts
/usr/bin/dscacheutil -flushcache
echo 'Owned guest DNS uses only the loopback whitelist; helper expires after three hours.'
