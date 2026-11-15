#!/bin/bash
# Build Biopass (face unlock, docs/login.md#face-unlock) with our patches (face/patches/) against a SteamOS root: its
# auth part (biopass-helper, the PAM module, the keyring tool, their libraries, the bundled libcamera and ONNX Runtime,
# libcamera's camera test tool) and its app (the Tauri GUI that sets face unlock up), with the unit tests the patches
# touch.
# Builds in a chroot of the root under an overlay, so the root stays untouched; the build tools (cli11, libcamera's
# code generators, Rust, Node.js) come from the image's own package repository into the overlay. Every source is pinned
# and checksummed: the archives in sources.sh and the app's frontend packages (from its bun.lock) are downloaded and
# checked before the chroot starts, the app's crates by cargo against its Cargo.lock in the chroot; then the build runs
# offline. Native on ARM64 (about 30 minutes on the laptop), or on x86_64 under qemu-user binfmt (hours).
# Usage: build.sh <SteamOS rootfs.img or root directory> [workdir]   -> <workdir>/s15-face-<version>.tar.zst
# The workdir must not sit on an overlay. S15_FACE_SRC: where downloads are kept (default <workdir>/src).
set -euo pipefail
# All mounts of the build (image, overlay, chroot binds) in a mount namespace of its own: they do not propagate into
# the namespaces of running services (which would keep copies, and the tmpfs and the loop device with them, after
# the build) and vanish with the build.
[ -n "${S15_FACE_NS:-}" ] || exec env S15_FACE_NS=1 unshare --mount --propagation private bash "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=$(realpath "${1:?SteamOS rootfs.img or root directory}"); W=$(realpath -m "${2:-$HOME/snaptop-build/face}")
[ "$(uname -m)" = aarch64 ] || [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "needs qemu-user binfmt for aarch64"; exit 1; }
# shellcheck source=face/sources.sh
. "$HERE/sources.sh"
SRC=$(realpath -m "${S15_FACE_SRC:-$W/src}")
mkdir -p "$W"/{upper,work,ro,chroot} "$SRC/npm"
if [ -d "$IMG" ]; then LOWER=$IMG; else LOWER=$W/ro; mountpoint -q "$W/ro" || mount -o loop,ro "$IMG" "$W/ro"; fi
grep -q '^ID=steamos' "$LOWER/etc/os-release" || { echo "$IMG is not SteamOS"; exit 1; }
cleanup() { for m in run dev sys proc; do umount -R "$W/chroot/$m" 2>/dev/null || true; done
            umount "$W/chroot" 2>/dev/null || true; mountpoint -q "$W/ro" && umount "$W/ro"; true; }
trap cleanup EXIT

cd "$SRC"
while read -r sum f url; do
  [ -s "$f" ] && echo "$sum  $f" | sha256sum -c --quiet 2>/dev/null && continue
  curl -fsSL --retry 3 -o "$f" "$url"
  echo "$sum  $f" | sha256sum -c --quiet || { echo "checksum mismatch: $f"; exit 1; }
done <<< "$FACE_SOURCES"
echo "sources: $(wc -l <<< "$FACE_SOURCES") archives checked"
# The app's frontend packages, as its bun.lock pins them (sha512 each), from the checked Biopass archive.
tar -xzOf "biopass-$BIOPASS_VERSION.tar.gz" "biopass-$BIOPASS_VERSION/app/bun.lock" > npm/bun.lock
python3 -I "$HERE/bunlock.py" fetch npm/bun.lock npm

mountpoint -q "$W/chroot" || mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=$W/upper,workdir=$W/work" "$W/chroot"
# --make-rslave: without it the recursive unmount in cleanup() propagates to the host (see desktop-net/build.sh).
# /run: name resolution for pacman (the image's resolv.conf points into it).
for m in proc sys dev run; do mount --rbind /$m "$W/chroot/$m"; mount --make-rslave "$W/chroot/$m"; done
rm -rf "$W/chroot/build"; mkdir -p "$W/chroot/build/src/npm" "$W/chroot/build/patches" "$W/chroot/build/node-test"
while read -r _ f _; do cp "$SRC/$f" "$W/chroot/build/src/"; done <<< "$FACE_SOURCES"
cp "$SRC"/npm/*.tgz "$W/chroot/build/src/npm/"
cp "$HERE"/patches/*.patch "$W/chroot/build/patches/"
cp "$HERE"/node-test/*.mjs "$W/chroot/build/node-test/"
install -m0755 "$HERE/build-in-chroot.sh" "$W/chroot/build/build-face.sh"
install -m0755 "$HERE/bunlock.py" "$W/chroot/build/bunlock.py"
chroot "$W/chroot" /usr/bin/env -i HOME=/root PATH=/usr/bin:/usr/sbin LANG=C.UTF-8 J="${J:-$(nproc)}" \
  BIOPASS_VERSION="$BIOPASS_VERSION" /bin/bash /build/build-face.sh
OUT="$W/s15-face-$(face_build_id).tar.zst"
tar -C "$W/chroot/build/stage" --owner=0 --group=0 -cf - . | zstd -19 -T0 -q -f -o "$OUT"
ls -la "$OUT"
