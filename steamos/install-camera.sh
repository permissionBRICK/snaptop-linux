#!/bin/bash
# Native build for installed SteamOS, or in its chroot with /sys and /dev bound.
set -euo pipefail
if [ "$(id -u)" != 0 ] || [ "$(uname -m)" != aarch64 ]; then echo 'Needs root on ARM64'; exit 1; fi
grep -q 'ASUS Vivobook S 15' /sys/firmware/devicetree/base/model || { echo 'Not a Vivobook S 15'; exit 1; }
grep -q '^ID=steamos' /etc/os-release || { echo 'Needs SteamOS'; exit 1; }
LC=0.7.1; PW=1.6.8
[ "$(pkg-config --modversion libpipewire-0.3)" = "$PW" ] || { echo "Expected PipeWire $PW; update the camera build pin for this image"; exit 1; }
STAMP=/var/lib/s15-camera.version
if [ "$(cat "$STAMP" 2>/dev/null || true)" = "$LC/$PW" ] &&
   [ -x /usr/local/bin/cam ] && [ -f /usr/local/lib/libcamera.so.0.7 ] &&
   [ -f /usr/local/lib/libcamera/ipa/ipa_soft_simple.so ] &&
   [ -f /usr/lib/spa-0.2/libcamera/libspa-libcamera.so ]; then
    echo 'S15 camera components already installed'; exit 0
fi
pacman -S --needed --noconfirm python-jinja python-ply
W=$(mktemp -d /var/tmp/s15-camera.XXXXXX)
trap 'rm -r "$W"' EXIT
cd "$W"
curl -fL --retry 3 "https://github.com/libcamera-org/libcamera/archive/refs/tags/v$LC.tar.gz" -o libcamera.tar.gz
curl -fL --retry 3 "https://github.com/PipeWire/pipewire/archive/refs/tags/$PW.tar.gz" -o pipewire.tar.gz
sha256sum -c <<'SUMS'
d9e73b8d9c38080aa874138d870faaf1b682199349c04b0a7710aba834e0d181  libcamera.tar.gz
8181172a1d95131f6af8bbc0b98f90b2a33349b042b84c3ce57dd5d11348cc58  pipewire.tar.gz
SUMS
tar -xf libcamera.tar.gz
tar -xf pipewire.tar.gz
meson setup libcamera-build "libcamera-$LC" --prefix=/usr/local --libdir=lib --buildtype=release \
    -Dauto_features=disabled -Dpipelines=simple -Dipas=simple -Dcam=enabled -Dudev=enabled
ninja -C libcamera-build -j4
DESTDIR="$W/stage" ninja -C libcamera-build install
cp -a "$W/stage/." /
mkdir -p /etc/ld.so.conf.d
echo /usr/local/lib > /etc/ld.so.conf.d/s15-camera.conf
ldconfig
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
meson setup pipewire-build "pipewire-$PW" --prefix=/usr --libdir=lib --buildtype=release \
    -Dauto_features=disabled -Dlibcamera=enabled -Dsession-managers=[]
ninja -C pipewire-build -j4 spa/plugins/libcamera/libspa-libcamera.so
install -Dm755 pipewire-build/spa/plugins/libcamera/libspa-libcamera.so /usr/lib/spa-0.2/libcamera/libspa-libcamera.so
mkdir -p /var/lib
(cd "$W/stage" && find . \( -type f -o -type l \) | sed 's#^\.#/#; s#//#/#') > /var/lib/s15-camera.files
printf '%s\n' /etc/ld.so.conf.d/s15-camera.conf /usr/lib/spa-0.2/libcamera/libspa-libcamera.so >> /var/lib/s15-camera.files
echo "$LC/$PW" > "$STAMP"
echo 'Camera components installed. Restart the desktop WirePlumber service, or reboot.'
