#!/bin/bash
# Install a newer kernel/build.sh payload into the running SteamOS: modules, kernel, DTBs, initramfs, S15BOOT.
# The previous set stays bootable as "SteamOS (S15) - previous kernel" in the S15BOOT menu.
# Usage (root, on the laptop): install-kernel.sh <payload dir>
set -euo pipefail
P=$(realpath "${1:?payload dir from kernel/build.sh}")
KV=$(cat "$P/kernel-version"); M=/usr/lib/modules/$KV
[ -d "$M" ] && { rm -rf "$M.old"; mv "$M" "$M.old"; }
zstd -dc "$P/modules-$KV.cpio.zst" | bsdtar -xpf - -C /
echo "modules: $(find $M -name '*.ko*' | wc -l)"
depmod "$KV"
install -m 0644 "$P/vmlinuz-$KV" "/boot/vmlinuz-$KV"
install -m 0644 "$P/dtb/x1e80100-asus-vivobook-s15-$KV-ec.dtb" /boot/x1e80100-asus-vivobook-s15-ec.dtb
install -m 0644 "$P/dtb/x1e80100-asus-vivobook-s15-$KV.dtb" /boot/x1e80100-asus-vivobook-s15.dtb
rm -f /boot/initramfs-s15.img /boot/initrd.uImage
mkinitcpio -c /etc/mkinitcpio-s15.conf -k "$KV" -g /boot/initramfs-s15.img 2>&1 | grep -i -E "error|s15-dsp|image generation" | head -6 || true
# The Frame's deckard-uimage post hook wraps the image in a 64-byte U-Boot header and deletes the original.
[ -f /boot/initramfs-s15.img ] || dd if=/boot/initrd.uImage of=/boot/initramfs-s15.img bs=64 skip=1 status=none
echo "initramfs: $(stat -c %s /boot/initramfs-s15.img) bytes, modules inside: $(lsinitcpio /boot/initramfs-s15.img | grep -c '\.ko')"
/usr/local/sbin/s15-update-esp "$KV"
