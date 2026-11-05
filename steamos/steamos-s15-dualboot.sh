#!/bin/bash
# One-click "Reboot to Windows" on SteamOS-on-S15: a root service that sets the firmware's one-time boot entry
# (BootNext) to Windows Boot Manager and reboots, a polkit rule that lets the desktop user start exactly that
# service without a password, a Desktop Mode icon, and (optional, Steam must not be running) a Game Mode entry.
# Usage: R=<root> steamos-s15-dualboot.sh        (R=/ on the running system)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=${R:-/}
install -d "$R/usr/local/sbin" "$R/etc/systemd/system" "$R/etc/polkit-1/rules.d"
cat > "$R/usr/local/sbin/s15-reboot-to-windows" <<'EOS'
#!/bin/bash
# Reboot once into Windows Boot Manager. EFI variables on X1E appear about 30 s after boot (qseecom); if they
# never do, a plain reboot still lands in Windows because it is first in BootOrder.
mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null
W=
for i in $(seq 1 45); do
  W=$(efibootmgr 2>/dev/null | sed -n 's/^Boot\([0-9A-F]\{4\}\)\* Windows Boot Manager.*/\1/p' | head -1)
  [ -n "$W" ] && break; sleep 1
done
if [ -n "$W" ]; then efibootmgr -q -n "$W" && echo "BootNext = $W (Windows Boot Manager)"; else echo "no EFI access - plain reboot"; fi
systemctl reboot
EOS
chmod 0755 "$R/usr/local/sbin/s15-reboot-to-windows"
# A plain reboot from SteamOS comes back to SteamOS: at the very end of a reboot (systemd-shutdown hook, after
# the unmounts) set BootNext to the entry we booted from, unless something already chose one ("Reboot to
# Windows"). Power-off and cold boots keep the firmware default (Windows Boot Manager first).
install -d "$R/usr/lib/systemd/system-shutdown"
cat > "$R/usr/lib/systemd/system-shutdown/s15-reboot-same-os" <<'EOS'
#!/bin/sh
[ "$1" = reboot ] || exit 0
mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null
efibootmgr 2>/dev/null | grep -q '^BootNext:' && exit 0
cur=$(efibootmgr 2>/dev/null | sed -n 's/^BootCurrent: //p')
[ -n "$cur" ] && efibootmgr -q -n "$cur"
exit 0
EOS
chmod 0755 "$R/usr/lib/systemd/system-shutdown/s15-reboot-same-os"
# A restart with a busy USB device (a dock's network adapter) crashed the next boot: the firmware does not reset the
# USB controllers on a warm restart, their DMA ran on into the new kernel, and the IOMMU, the display and the EC's
# I2C bus hung until the EC reset the machine (docs/known-issues.md). Halt the controllers before a restart (unbind
# the xHCI hosts, then their DWC3 controllers, which also powers down the USB PHYs), as Windows does on shutdown.
cat > "$R/usr/lib/systemd/system-shutdown/s15-reboot-usb-quiesce" <<'EOS'
#!/bin/sh
[ "$1" = reboot ] || exit 0
for drv in xhci-hcd dwc3-qcom; do
  D=/sys/bus/platform/drivers/$drv
  [ -d "$D" ] || continue
  for dev in "$D"/*; do
    [ -e "$dev/driver" ] || continue
    echo "${dev##*/}" > "$D/unbind" 2>/dev/null
  done
done
exit 0
EOS
chmod 0755 "$R/usr/lib/systemd/system-shutdown/s15-reboot-usb-quiesce"
cat > "$R/etc/systemd/system/s15-reboot-to-windows.service" <<'EOS'
[Unit]
Description=Reboot into Windows once (UEFI BootNext)
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/s15-reboot-to-windows
EOS
cat > "$R/etc/polkit-1/rules.d/50-s15-reboot-to-windows.rules" <<'EOS'
// The desktop user may start s15-reboot-to-windows.service (and nothing else) without a password.
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.systemd1.manage-units" &&
      action.lookup("unit") == "s15-reboot-to-windows.service" &&
      action.lookup("verb") == "start" && subject.user == "steamos") {
    return polkit.Result.YES;
  }
});
EOS
D="$R/home/steamos/Desktop"; install -d "$D"
cat > "$D/RebootWindows.desktop" <<'EOS'
[Desktop Entry]
Name=Reboot to Windows
Exec=systemctl start --no-block s15-reboot-to-windows.service
Icon=system-reboot
Terminal=false
Type=Application
StartupNotify=false
EOS
chmod 0755 "$D/RebootWindows.desktop"; chown 1000:1000 "$D" "$D/RebootWindows.desktop" 2>/dev/null || true

# Game Mode: a native non-Steam entry in the library (only when Steam is stopped; it rewrites shortcuts.vdf on exit)
S=$R/home/steamos/.local/share/Steam
if [ "$R" != / ]; then
  echo "offline install: add the Game Mode entry later on the running system"
elif pgrep -u steamos -x steam >/dev/null; then
  echo "Steam is running: Game Mode entry skipped (run again with Steam stopped)"
elif UD=$(ls -dt "$S"/userdata/*/ 2>/dev/null | head -1) && [ -n "$UD" ]; then
  sudo -u steamos python3 "$HERE/../games/steam-add-shortcut.py" "${UD%/}" "Reboot to Windows" /usr/bin/systemctl \
    "start --no-block s15-reboot-to-windows.service" none
fi
echo "dual-boot buttons installed in $R"
