#!/bin/bash
# Read-only hardware survey for the Vivobook S 15 (X1E80100) under an ARM64 live system.
# Only side effect: sets the Bluetooth public address when the controller is unconfigured.
sec() { printf '\n===== %s =====\n' "$1"; }
sec "system"
uname -r; cat /proc/device-tree/model 2>/dev/null; echo
cat /proc/cmdline
uptime
sec "kernel errors/warnings (first 60)"
dmesg --level=err,warn 2>/dev/null | grep -v -E "clk_ignore_unused|pd_ignore_unused" | head -60
sec "remoteprocs"
for r in /sys/class/remoteproc/remoteproc*; do printf '%s %s %s\n' "$(basename $r)" "$(cat $r/name 2>/dev/null)" "$(cat $r/state 2>/dev/null)"; done
sec "cpufreq (BIOS .368 regression check)"
for p in /sys/devices/system/cpu/cpufreq/policy*; do printf '%s cur=%s min=%s max=%s hwmax=%s gov=%s\n' "$(basename $p)" "$(cat $p/scaling_cur_freq)" "$(cat $p/scaling_min_freq)" "$(cat $p/scaling_max_freq)" "$(cat $p/cpuinfo_max_freq)" "$(cat $p/scaling_governor)"; done 2>/dev/null
lsmod | grep -E "scmi|cpufreq" | head
sec "display / backlight"
for c in /sys/class/drm/card*-*; do printf '%s %s %s\n' "$(basename $c)" "$(cat $c/status 2>/dev/null)" "$(head -1 $c/modes 2>/dev/null)"; done
for b in /sys/class/backlight/*; do printf '%s brightness=%s max=%s\n' "$(basename $b)" "$(cat $b/brightness)" "$(cat $b/max_brightness)"; done 2>/dev/null
sec "gpu"
ls /sys/class/devfreq/ 2>/dev/null; dmesg | grep -i -E "adreno|msm_dpu|zap|gmu" | tail -8
vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName|driverInfo|apiVersion|conformanceVersion" | head
sec "battery / power supply"
for s in /sys/class/power_supply/*; do echo "-- $(basename $s)"; grep -E "STATUS|CAPACITY=|ENERGY_FULL|VOLTAGE_NOW|ONLINE|TYPE=|MODEL|MANUFACTURER|CHARGE_CONTROL" $s/uevent 2>/dev/null; done
sec "thermal"
for t in /sys/class/thermal/thermal_zone*; do printf '%s %s %s\n' "$(cat $t/type)" "$(cat $t/temp)" "$(cat $t/policy 2>/dev/null)"; done 2>/dev/null | head -30
ls /sys/class/hwmon/ 2>/dev/null | while read h; do printf '%s %s\n' "$h" "$(cat /sys/class/hwmon/$h/name)"; done
sec "wifi"
iw dev 2>/dev/null; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev 2>/dev/null
dmesg | grep -i ath12k | grep -i -E "board|fw|variant|error|fail" | head -10
sec "bluetooth"
btmgmt config 2>/dev/null | head -5
if ! btmgmt info 2>/dev/null | grep -q "^hci0"; then
  if [ -n "${BT_ADDR:-}" ]; then echo "hci0 not configured -> setting public address $BT_ADDR"; btmgmt -i hci0 public-addr "$BT_ADDR"; sleep 3
  else echo "hci0 not configured (set BT_ADDR to the Windows Bluetooth address to configure it)"; fi
fi
btmgmt info 2>/dev/null | head -8
sec "usb / typec"
lsusb 2>/dev/null
for p in /sys/class/typec/port*; do printf '%s data_role=%s power_role=%s\n' "$(basename $p)" "$(cat $p/data_role 2>/dev/null)" "$(cat $p/power_role 2>/dev/null)"; done
sec "input"
grep -E "^N: Name|^H: Handlers" /proc/bus/input/devices
sec "audio"
aplay -l 2>&1 | head; arecord -l 2>&1 | head -5
sec "camera"
ls /dev/video* /dev/media* 2>/dev/null; cam -l 2>/dev/null | head
sec "storage"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL 2>/dev/null
sec "pci"
lspci -nn 2>/dev/null
sec "i2c buses (no probing)"
ls /sys/bus/i2c/devices/ 2>/dev/null | tr '\n' ' '; echo
for d in /sys/bus/i2c/devices/*-00*; do printf '%s %s %s\n' "$(basename $d)" "$(cat $d/name 2>/dev/null)" "$(basename "$(readlink $d/driver 2>/dev/null)")"; done
sec "suspend capability"
cat /sys/power/state /sys/power/mem_sleep 2>/dev/null
