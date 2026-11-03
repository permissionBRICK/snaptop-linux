#!/bin/bash
# Build the Plasma network (plasma-nm) and Bluetooth (bluedevil) applets the Steam Frame image leaves out, plus
# the frameworks they need (NetworkManagerQt, ModemManagerQt, BluezQt), against the image's own Qt 6.8 /
# KF6 6.14 / Plasma 6.2.5, in a chroot of the image under an overlay (the image itself stays untouched). Native on
# ARM64 (a few minutes on the laptop), or on x86_64 under qemu-user binfmt (hours).
# Usage: build.sh <frame rootfs.img or rootfs directory> [workdir]   -> <workdir>/s15-desktop-net-<date>.tar.zst
# The image ships compilers, CMake, headers and most KF6 dependencies; only these packages are missing.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=$(realpath "${1:?Frame rootfs.img or an unpacked SteamOS root directory}"); W=$(realpath -m "${2:-$HOME/snaptop-build/desktop-net}")
KF=6.14.0; PL=6.2.5
SRCS="frameworks/${KF%.*}/extra-cmake-modules-$KF frameworks/${KF%.*}/networkmanager-qt-$KF frameworks/${KF%.*}/modemmanager-qt-$KF frameworks/${KF%.*}/bluez-qt-$KF plasma/$PL/plasma-nm-$PL plasma/$PL/bluedevil-$PL"
[ "$(uname -m)" = aarch64 ] || [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "needs qemu-user binfmt for aarch64 (qemu-user-static)"; exit 1; }
mkdir -p "$W"/{src,upper,work,ro,chroot}
cd "$W/src"
for s in $SRCS; do
  f=$(basename "$s").tar.xz; u=https://download.kde.org/stable/$s.tar.xz
  [ -s "$f" ] || curl -sfL -o "$f" "$u"
  curl -sfL "$u.sha256" | awk -v f="$f" '{print $1"  "f}' | sha256sum -c --quiet
  [ -d "$(basename "$s")" ] || tar -xf "$f"
done
# bluedevil: KF6DocTools is not in the image; drop the handbook only
sed -i -e '/^    DocTools$/d' -e 's/^add_subdirectory(doc)$/# add_subdirectory(doc)/' -e 's/^kdoctools_install(po)$/# kdoctools_install(po)/' \
  "bluedevil-$PL/CMakeLists.txt"
if [ -d "$IMG" ]; then LOWER=$IMG; else LOWER=$W/ro; mountpoint -q "$W/ro" || mount -o loop,ro "$IMG" "$W/ro"; fi
mountpoint -q "$W/chroot" || mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=$W/upper,workdir=$W/work" "$W/chroot"
cleanup() { for m in dev sys proc; do umount -R "$W/chroot/$m" 2>/dev/null || true; done; umount "$W/chroot" 2>/dev/null || true
            mountpoint -q "$W/ro" && umount "$W/ro"; true; }
trap cleanup EXIT
# --make-rslave: without it the recursive unmount in cleanup() propagates to the host (/ is a shared mount)
# and takes /sys/fs/cgroup, /dev/pts, /dev/shm etc. with it, which breaks systemd until they are remounted.
for m in proc sys dev; do mount --rbind /$m "$W/chroot/$m"; mount --make-rslave "$W/chroot/$m"; done
# The overlay's upper dir keeps earlier results: finished packages (build/b/*.done) are skipped on a rerun, which
# helps because configure steps under qemu occasionally fail spuriously (once: "Could NOT find Qt6Xml").
mkdir -p "$W/chroot/build/src"
for s in $SRCS; do [ -d "$W/chroot/build/src/$(basename "$s")" ] || cp -a "$W/src/$(basename "$s")" "$W/chroot/build/src/"; done
install -m0755 "$HERE/build-in-chroot.sh" "$W/chroot/build/build-net-bt.sh"
chroot "$W/chroot" /usr/bin/env -i HOME=/root PATH=/usr/bin:/usr/sbin LANG=C.UTF-8 J="$(nproc)" /bin/bash /build/build-net-bt.sh
OUT="$W/s15-desktop-net-$(date +%Y%m%d).tar.zst"
tar -C "$W/chroot/build/stage" --owner=0 --group=0 \
    --exclude=usr/include --exclude=usr/lib/cmake --exclude=usr/lib/pkgconfig -cf - usr | zstd -19 -T0 -q -f -o "$OUT"
ls -la "$OUT"
