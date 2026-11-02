#!/bin/bash
# Download Valve's Steam Frame SteamOS image (public update CDN) and copy its root filesystem into <target>, an empty,
# mounted btrfs on the laptop's NVMe. The 10 GiB image is assembled in <target>/.frame-image (not in RAM), loop-mounted
# read-only, copied with all attributes, and removed again.
# Usage (root): frame-rootfs.sh <target mountpoint>
# Needs: curl python3 python3-requests python3-zstandard squashfs-tools rsync
set -euo pipefail
T=$(realpath "${1:?target mountpoint}")
mountpoint -q "$T" || { echo "$T is not a mount point"; exit 1; }
B=${FRAME_BUILD:-20261002.6232440}; V=${FRAME_VERSION:-0.5.3}
U=https://steamdeck-images.steamos.cloud/vr/$B
# casync extractor from SteamOS-ARM-Port, pinned
X_REV=4f1892e46e6c6be8359d0cef583e5906bfca66cb
X_SHA=f6e5840a6d14b08b026e20442ab4597af1d780bb779fea91cdd8c11fe2ffb378
W=$T/.frame-image; mkdir -p "$W"; cd "$W"
curl -fsSL -o extract_rootfs.py "https://raw.githubusercontent.com/hashtagbasit/SteamOS-ARM-Port/$X_REV/scripts/extract_rootfs.py"
echo "$X_SHA  extract_rootfs.py" | sha256sum -c --quiet
[ -f bundle/rootfs.img.caibx ] || { curl -fsSL -o bundle.raucb "$U/deckard-$B-$V.raucb" && unsquashfs -q -d bundle bundle.raucb >/dev/null; }
SHA=$(sed -n "/^\[image.rootfs\]/,/^\[/{s/^sha256=//p}" bundle/manifest.raucm)
echo "downloading and assembling SteamOS $V ($B), about 3 GB ..."
python3 -I extract_rootfs.py --caibx bundle/rootfs.img.caibx --output rootfs.img --store "$U/deckard-$B-$V.castr" \
  --workers 16 --expected-sha256 "$SHA" 2>&1 | tr "\r" "\n" | grep -E "sha256|match|rror" | tail -3
echo "$SHA  rootfs.img" | sha256sum -c --quiet || { echo "rootfs.img checksum mismatch"; exit 1; }
mkdir -p "$W/mnt"; mount -o loop,ro rootfs.img "$W/mnt"
trap 'umount "$W/mnt" 2>/dev/null || true' EXIT
echo "copying the root filesystem ..."
rsync -aHAXS --numeric-ids --exclude=/.frame-image "$W/mnt/" "$T/"
umount "$W/mnt"; trap - EXIT
cd /; rm -rf "$W"
grep -q '^ID=steamos' "$T/etc/os-release" && echo "SteamOS root filesystem in $T"
