#!/bin/bash
# Build the Plasma network (plasma-nm) and Bluetooth (bluedevil) applets and the frameworks they need
# (NetworkManagerQt, ModemManagerQt, BluezQt) where the Steam Frame image leaves them out, against the image's own
# KDE Frameworks and Plasma versions (read from the image: 0.5.3 has KF6 6.14 / Plasma 6.2.5 and none of them; 0.5.7
# has KF6 6.23 / Plasma 6.6.2 and its own plasma-nm, so only BluezQt and bluedevil are built). Builds in a chroot of
# the image under an overlay (the image itself stays untouched). Native on ARM64 (a few minutes on the laptop), or on
# x86_64 under qemu-user binfmt (hours).
# Usage: build.sh <frame rootfs.img or rootfs directory> [workdir]   -> <workdir>/s15-desktop-net-<date>.tar.zst
# (an empty package when the image has everything). The image ships compilers, CMake and most KF6 dependencies.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=$(realpath "${1:?Frame rootfs.img or an unpacked SteamOS root directory}"); W=$(realpath -m "${2:-$HOME/snaptop-build/desktop-net}")
[ "$(uname -m)" = aarch64 ] || [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "needs qemu-user binfmt for aarch64 (qemu-user-static)"; exit 1; }
mkdir -p "$W"/{src,upper,work,ro,chroot}
if [ -d "$IMG" ]; then LOWER=$IMG; else LOWER=$W/ro; mountpoint -q "$W/ro" || mount -o loop,ro "$IMG" "$W/ro"; fi
cleanup() { for m in dev sys proc; do umount -R "$W/chroot/$m" 2>/dev/null || true; done; umount "$W/chroot" 2>/dev/null || true
            mountpoint -q "$W/ro" && umount "$W/ro"; true; }
trap cleanup EXIT

# The image's versions, from its library file names (libKF6CoreAddons.so.6.23.0, libkworkspace6.so.6.6.2)
ver() { ls "$LOWER"/usr/lib/"$1".so.6.* 2>/dev/null | sed -n "s#.*/$1\.so\.##p" | sort -V | tail -1; }
KF=$(ver libKF6CoreAddons); PL=$(ver libkworkspace6)
[ -n "$KF" ] && [ -n "$PL" ] || { echo "cannot tell the image's KDE Frameworks / Plasma version"; exit 1; }
echo "image: KDE Frameworks $KF, Plasma $PL"
has() { [ -e "$LOWER/$1" ]; }
A=usr/lib/qt6/plugins/plasma/applets
# name, KDE download path, stage into the package (yes|no), cmake arguments; only what the image lacks
COMP=()
has $A/org.kde.plasma.networkmanagement.so || {
  has usr/lib/libKF6NetworkManagerQt.so.6 || COMP+=("networkmanager-qt-$KF frameworks/${KF%.*} yes")
  has usr/lib/libKF6ModemManagerQt.so.6 || COMP+=("modemmanager-qt-$KF frameworks/${KF%.*} yes")
  COMP+=("plasma-nm-$PL plasma/$PL yes -DBUILD_OPENCONNECT=OFF"); }
has $A/org.kde.plasma.bluetooth.so || {
  has usr/lib/libKF6BluezQt.so.6 || COMP+=("bluez-qt-$KF frameworks/${KF%.*} yes")
  COMP+=("bluedevil-$PL plasma/$PL yes"); }
OUT="$W/s15-desktop-net-$(date +%Y%m%d).tar.zst"
if [ ${#COMP[@]} = 0 ]; then
  echo "the image has the network and Bluetooth applets: nothing to build"
  mkdir -p "$W/empty/usr"; tar -C "$W/empty" --owner=0 --group=0 -cf - usr | zstd -q -f -o "$OUT"; ls -la "$OUT"; exit 0
fi
grep -qs "PACKAGE_VERSION \"$KF\"" "$LOWER/usr/share/ECM/cmake/ECMConfigVersion.cmake" ||
  COMP=("extra-cmake-modules-$KF frameworks/${KF%.*} no -DBUILD_DOC=OFF" "${COMP[@]}")
printf '%s\n' "${COMP[@]}" | awk '{print "  build " $1}'

cd "$W/src"
for c in "${COMP[@]}"; do
  read -r n p _ <<< "$c"
  f=$n.tar.xz; u=https://download.kde.org/stable/$p/$f
  [ -s "$f" ] || curl -sfL -o "$f" "$u"
  curl -sfL "$u.sha256" | awk -v f="$f" '{print $1"  "f}' | sha256sum -c --quiet
  [ -d "$n" ] || tar -xf "$f"
done
# bluedevil: KF6DocTools is not in the image; drop the handbook only
[ ! -d "bluedevil-$PL" ] || sed -i -e '/^    DocTools$/d' -e 's/^add_subdirectory(doc)$/# add_subdirectory(doc)/' \
  -e 's/^kdoctools_install(po)$/# kdoctools_install(po)/' "bluedevil-$PL/CMakeLists.txt"
mountpoint -q "$W/chroot" || mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=$W/upper,workdir=$W/work" "$W/chroot"
# --make-rslave: without it the recursive unmount in cleanup() propagates to the host (/ is a shared mount)
# and takes /sys/fs/cgroup, /dev/pts, /dev/shm etc. with it, which breaks systemd until they are remounted.
for m in proc sys dev; do mount --rbind /$m "$W/chroot/$m"; mount --make-rslave "$W/chroot/$m"; done
# The overlay's upper dir keeps earlier results: finished packages (build/b/*.done) are skipped on a rerun, which
# helps because configure steps under qemu occasionally fail spuriously (once: "Could NOT find Qt6Xml").
mkdir -p "$W/chroot/build/src"
for c in "${COMP[@]}"; do read -r n _ <<< "$c"; [ -d "$W/chroot/build/src/$n" ] || cp -a "$W/src/$n" "$W/chroot/build/src/"; done
printf '%s\n' "${COMP[@]}" | awk '{$2=""; print}' > "$W/chroot/build/components"
install -m0755 "$HERE/build-in-chroot.sh" "$W/chroot/build/build-net-bt.sh"
chroot "$W/chroot" /usr/bin/env -i HOME=/root PATH=/usr/bin:/usr/sbin LANG=C.UTF-8 J="$(nproc)" /bin/bash /build/build-net-bt.sh
tar -C "$W/chroot/build/stage" --owner=0 --group=0 \
    --exclude=usr/include --exclude=usr/lib/cmake --exclude=usr/lib/pkgconfig -cf - usr | zstd -19 -T0 -q -f -o "$OUT"
ls -la "$OUT"
