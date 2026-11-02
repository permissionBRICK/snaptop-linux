#!/bin/bash
sec() { printf '\n===== %s =====\n' "$1"; }
t() { timeout 15 "$@" 2>&1; }
sec "cpufreq detail"
ls /sys/devices/system/cpu/cpufreq/ 2>&1; lsmod | grep -i -E "scmi|cpufreq|cpucp"; dmesg | grep -i -E "scmi|cpufreq|cpucp" | head -15
sec "bluetooth"
t rfkill list; ls /sys/class/bluetooth/ 2>&1; dmesg | grep -i -E "bluetooth|hci_uart|qca|btqca" | head -20
t btmgmt -i hci0 info | head -15
sec "wifi connection"
t nmcli -f NAME,TYPE,DEVICE connection show; t nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list | head -8
sec "usb / typec"
t lsusb
for p in /sys/class/typec/port*; do printf '%s data_role=%s power_role=%s\n' "$(basename $p)" "$(cat $p/data_role 2>/dev/null)" "$(cat $p/power_role 2>/dev/null)"; done
sec "input"
grep -E "^N: Name|^H: Handlers" /proc/bus/input/devices
sec "audio"
t aplay -l; t arecord -l | head -5; ls /proc/asound/ 2>&1
sec "camera"
ls /dev/video* /dev/media* 2>&1; t cam -l | head
sec "storage"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL 2>&1
sec "pci"
t lspci -nn
sec "i2c devices (no probing)"
for d in /sys/bus/i2c/devices/*-00*; do printf '%s %s %s\n' "$(basename $d)" "$(cat $d/name 2>/dev/null)" "$(basename "$(readlink $d/driver 2>/dev/null)")"; done
sec "battery capacity fields"
cat /sys/class/power_supply/qcom-battmgr-bat/uevent 2>&1
sec "suspend"
cat /sys/power/state /sys/power/mem_sleep 2>&1
sec "watchdogs"
ls /dev/watchdog* 2>&1; for w in /sys/class/watchdog/*; do printf '%s %s state=%s timeout=%s\n' "$(basename $w)" "$(cat $w/identity 2>/dev/null)" "$(cat $w/state 2>/dev/null)" "$(cat $w/timeout 2>/dev/null)"; done
sec "failed units / errors since boot"
systemctl --failed --no-legend 2>&1; dmesg --level=err 2>/dev/null | grep -v -E "xts-aes-qce|ctr-aes-qce|alg:" | tail -25
