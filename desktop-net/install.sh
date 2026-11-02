#!/bin/bash
# Install the network/Bluetooth applet package from build.sh on the laptop (root), then reload the Plasma session
# pieces that pick them up. Usage: install.sh <s15-desktop-net-*.tar.zst>
set -euo pipefail
P=$(realpath "${1:?package}")
LIST=/var/lib/s15-desktop-net.files
zstd -dc "$P" | tar -tf - | grep -v '/$' > "$LIST.new"
zstd -dc "$P" | tar -xpf - -C / --no-same-owner
mv "$LIST.new" "$LIST"; echo "installed $(wc -l < "$LIST") files (list: $LIST)"
ldconfig
U=steamos; X=/run/user/$(id -u $U)
if [ -S "$X/bus" ]; then
  u() { sudo -u $U XDG_RUNTIME_DIR=$X DBUS_SESSION_BUS_ADDRESS=unix:path=$X/bus "$@"; }
  u kbuildsycoca6 >/dev/null 2>&1 || true
  if u systemctl --user is-active -q plasma-plasmashell.service; then
    u systemctl --user restart plasma-kded6.service plasma-plasmashell.service && echo "Plasma reloaded"
  fi
fi
