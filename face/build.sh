#!/bin/bash
# Build the auth part of Biopass (face unlock, docs/login.md#face-unlock) with our patches for the laptop's IR camera
# (face/patches/), against a SteamOS root: biopass-helper, the PAM module, the keyring tool, their libraries, the
# bundled libcamera and ONNX Runtime, and libcamera's camera test tool. The Biopass app itself (GUI) comes from
# Biopass's arm64 release (steamos/install-face.sh puts this build over it).
# Builds in a chroot of the root under an overlay, so the root stays untouched; cli11 (a header-only build dependency)
# comes from the image's own package repository into the overlay. Every source is pinned and checksummed and
# downloaded before the chroot starts; the build itself is offline. Native on ARM64 (about 10 minutes on the laptop),
# or on x86_64 under qemu-user binfmt (about an hour).
# Usage: build.sh <SteamOS rootfs.img or root directory> [workdir]   -> <workdir>/s15-face-<version>.tar.zst
# The workdir must not sit on an overlay (install-face.sh gives it a tmpfs).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=$(realpath "${1:?SteamOS rootfs.img or root directory}"); W=$(realpath -m "${2:-$HOME/snaptop-build/face}")
[ "$(uname -m)" = aarch64 ] || [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "needs qemu-user binfmt for aarch64"; exit 1; }
# shellcheck source=face/sources.sh
. "$HERE/sources.sh"
mkdir -p "$W"/{src,upper,work,ro,chroot}
if [ -d "$IMG" ]; then LOWER=$IMG; else LOWER=$W/ro; mountpoint -q "$W/ro" || mount -o loop,ro "$IMG" "$W/ro"; fi
grep -q '^ID=steamos' "$LOWER/etc/os-release" || { echo "$IMG is not SteamOS"; exit 1; }
cleanup() { for m in run dev sys proc; do umount -R "$W/chroot/$m" 2>/dev/null || true; done
            umount "$W/chroot" 2>/dev/null || true; mountpoint -q "$W/ro" && umount "$W/ro"; true; }
trap cleanup EXIT

cd "$W/src"
while read -r sum f url; do
  [ -s "$f" ] && echo "$sum  $f" | sha256sum -c --quiet 2>/dev/null && continue
  curl -fsSL --retry 3 -o "$f" "$url"
  echo "$sum  $f" | sha256sum -c --quiet || { echo "checksum mismatch: $f"; exit 1; }
done <<< "$FACE_SOURCES"
echo "sources: $(wc -l <<< "$FACE_SOURCES") archives checked"

mountpoint -q "$W/chroot" || mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=$W/upper,workdir=$W/work" "$W/chroot"
# --make-rslave: without it the recursive unmount in cleanup() propagates to the host (see desktop-net/build.sh).
# /run: name resolution for pacman (the image's resolv.conf points into it).
for m in proc sys dev run; do mount --rbind /$m "$W/chroot/$m"; mount --make-rslave "$W/chroot/$m"; done
rm -rf "$W/chroot/build"; mkdir -p "$W/chroot/build/src" "$W/chroot/build/patches"
cp "$W"/src/* "$W/chroot/build/src/"
cp "$HERE"/patches/*.patch "$W/chroot/build/patches/"
install -m0755 "$HERE/build-in-chroot.sh" "$W/chroot/build/build-face.sh"
chroot "$W/chroot" /usr/bin/env -i HOME=/root PATH=/usr/bin:/usr/sbin LANG=C.UTF-8 J="${J:-$(nproc)}" \
  BIOPASS_VERSION="$BIOPASS_VERSION" /bin/bash /build/build-face.sh
OUT="$W/s15-face-$(face_build_id).tar.zst"
tar -C "$W/chroot/build/stage" --owner=0 --group=0 -cf - . | zstd -19 -T0 -q -f -o "$OUT"
ls -la "$OUT"
