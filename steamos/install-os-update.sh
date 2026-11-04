#!/bin/bash
# Install s15-os-update (docs/updates.md) into a SteamOS root: the tool, its units and the /etc keep list.
# steamos-s15-setup.sh calls it for every new install and SteamOS version; on an install from before, run it once:
#   sudo /opt/snaptop-linux/steamos/install-os-update.sh
# Usage (root): install-os-update.sh [root, default /]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=${1:-}; R=${R%/}
grep -q '^ID=steamos' "$R/etc/os-release" || { echo "$R is not SteamOS"; exit 1; }
install -D -m0755 "$HERE/s15-os-update" "$R/usr/local/sbin/s15-os-update"
install -D -m0644 "$HERE/s15-os-confirm.service" "$HERE/s15-os-confirm.timer" "$HERE/s15-os-catchup.service" \
  -t "$R/etc/systemd/system/"
# Steam's "Check for updates" / "Apply" (it runs steamos-polkit-helpers/steamos-update): s15-os-update instead of
# Valve's updater, which would write the image to A/B partitions this install does not have. Valve's scripts stay
# next to them as *.valve.
for f in /usr/bin/steamos-update /usr/bin/steamos-polkit-helpers/steamos-update; do
  if [ -f "$R$f" ] && ! grep -q 's15-os-update' "$R$f"; then mv -f "$R$f" "$R$f.valve"; fi
  install -D -m0755 "$HERE/steamos-update-s15" "$R$f"
done
install -d "$R/etc/systemd/system/timers.target.wants" "$R/etc/systemd/system/shutdown.target.wants"
ln -sfn ../s15-os-confirm.timer "$R/etc/systemd/system/timers.target.wants/s15-os-confirm.timer"
ln -sfn ../s15-os-catchup.service "$R/etc/systemd/system/shutdown.target.wants/s15-os-catchup.service"
# /etc files that an update carries into the next SteamOS version, besides Valve's list
# (/usr/lib/rauc/atomic-update-keep.conf): files our tools change at runtime, the console keymap, which the
# initramfs needs for the disk passphrase, and OpenVPN files that NetworkManager's VPN connections point to
install -d "$R/etc/atomic-update.conf.d"
cat > "$R/etc/atomic-update.conf.d/s15.conf" <<'EOK'
# snaptop-linux (docs/updates.md): kept by s15-os-update in addition to /usr/lib/rauc/atomic-update-keep.conf
/etc/vconsole.conf
/etc/locale.conf
/etc/X11/xorg.conf.d/*.conf
/etc/s15-wifi-nopowersave
/etc/s15-kbd-mode.conf
/etc/s15-sleep-keep-bt
/etc/openvpn/**
EOK
[ -n "$R" ] || systemctl daemon-reload
echo "s15-os-update installed${R:+ in $R}"
