#!/bin/bash
# OpenVPN for NetworkManager, so .ovpn profiles can be imported and VPN connections switched from Plasma's network
# applet. The Frame image has NetworkManager and (0.5.7; desktop-net/ builds it for 0.5.3) Plasma's OpenVPN editor
# plugin, but neither openvpn nor NetworkManager's OpenVPN plugin, so NetworkManager reports missing support for
# OpenVPN connections. Native in installed SteamOS, or in its chroot (steamos-s15-setup.sh, which s15-os-update
# runs for every new version):
#  - openvpn from the image's own package repository (pacman -S --needed, no system upgrade)
#  - NetworkManager-openvpn (not in that repository), built from GNOME's release tarball without the GNOME editor
# The plugin's files are listed in /var/lib/s15-nm-openvpn.files (docs/steamos.md: removing them).
set -euo pipefail
if [ "$(id -u)" != 0 ] || [ "$(uname -m)" != aarch64 ]; then echo 'Needs root on ARM64'; exit 1; fi
grep -q 'ASUS Vivobook S 15' /sys/firmware/devicetree/base/model || { echo 'Not a Vivobook S 15'; exit 1; }
grep -q '^ID=steamos' /etc/os-release || { echo 'Needs SteamOS'; exit 1; }
VER=1.12.3   # 1.12.4+ needs libnm >= 1.52.2; the 0.5.3 and 0.5.7 images have 1.52.1 (1.12.3 needs >= 1.45.11)
SUM=4bda1c8559bb8c35f6f131c09edae90cdfccd0314e8b8cb98ac55e09b6005adc
STAMP=/var/lib/s15-nm-openvpn.version
LIST=/var/lib/s15-nm-openvpn.files
SVC=$(pkg-config --variable=vpnservicedir libnm)/nm-openvpn-service.name
SYSUSERS=/usr/lib/sysusers.d/s15-nm-openvpn.conf
pacman -S --needed --noconfirm openvpn
if [ "$(cat "$STAMP" 2>/dev/null || true)" = "$VER" ] && [ -f "$SVC" ] && [ -x /usr/lib/nm-openvpn-service ] &&
   [ -f "$SYSUSERS" ]; then
    echo "NetworkManager-openvpn $VER already installed"; exit 0
fi
W=$(mktemp -d /var/tmp/s15-nm-openvpn.XXXXXX)
trap 'rm -rf "$W"' EXIT
cd "$W"
curl -fL --retry 3 -o nm-openvpn.tar.xz \
    "https://download.gnome.org/sources/NetworkManager-openvpn/${VER%.*}/NetworkManager-openvpn-$VER.tar.xz"
echo "$SUM  nm-openvpn.tar.xz" | sha256sum -c --quiet
tar -xf nm-openvpn.tar.xz
cd "NetworkManager-openvpn-$VER"
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --libexecdir=/usr/lib --without-gnome \
    --disable-static >"$W/configure.log" 2>&1 || { tail -30 "$W/configure.log"; exit 1; }
make -j"$(nproc)" >"$W/build.log" 2>&1 || { tail -40 "$W/build.log"; exit 1; }
make install DESTDIR="$W/stage" >/dev/null
find "$W/stage" -name '*.la' -delete
# The plugin runs openvpn as this user after it dropped its privileges (Arch's package declares it the same way).
mkdir -p "$W/stage${SYSUSERS%/*}"
echo 'u nm-openvpn - "NetworkManager OpenVPN" / /usr/bin/nologin' > "$W/stage$SYSUSERS"
tar -C "$W/stage" -cf - . | tar -C / -xpf - --no-overwrite-dir   # keeps the modes of existing directories
(cd "$W/stage" && find . \( -type f -o -type l \) | sed 's#^\.#/#; s#//#/#') > "$LIST"
systemd-sysusers "$SYSUSERS"
ldconfig
echo "$VER" > "$STAMP"
# In the running system: D-Bus picks up the plugin's bus policy; NetworkManager notices new VPN plugins itself.
if ! systemd-detect-virt -q --chroot; then
    systemctl reload dbus-broker.service 2>/dev/null || systemctl reload dbus.service 2>/dev/null || true
fi
echo "NetworkManager-openvpn $VER installed ($(wc -l < "$LIST") files)"
