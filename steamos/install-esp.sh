#!/bin/bash
# Make the S15BOOT partition the boot partition of the SteamOS install: systemd-boot (from the SteamOS image) with
# entries for the current and the previous kernel, kernel/initramfs/DTB, the tool s15-update-esp in SteamOS for later
# kernels, and the firmware boot entry "SteamOS (S15)" *behind* Windows Boot Manager. Nothing chainloads Windows and
# the Windows ESP is not touched, so BitLocker's measurements stay the same.
# Usage (root): install-esp.sh <SteamOS root> <S15BOOT partition device>
set -euo pipefail
R=$(realpath "${1:?SteamOS root}"); EP=$(readlink -f "${2:?S15BOOT partition}")
# An encrypted SteamOS partition (docs/encryption.md) is opened by the initramfs and mounted as /dev/mapper/root;
# tpm2-measure-pcr=yes measures the volume key into PCR 15 right after, so the TPM key is released once per boot.
ROOT="root=PARTLABEL=SNAPSTEAM-NVME"
if [ "$(blkid -o value -s TYPE /dev/disk/by-partlabel/SNAPSTEAM-NVME 2>/dev/null)" = crypto_LUKS ]; then
  U=$(cryptsetup luksUUID /dev/disk/by-partlabel/SNAPSTEAM-NVME)
  ROOT="root=/dev/mapper/root rd.luks.name=$U=root rd.luks.options=$U=discard,tpm2-device=auto,tpm2-measure-pcr=yes"
fi
ARGS="$ROOT rw rootfstype=btrfs rootflags=noatime,compress=zstd:1 qcom_hamoa_ec.allow_suspend=1"
ARGS="$ARGS nvme.quirks=1344:5413:simple_suspend pcie_port_pm=force pcie_aspm.policy=powersupersave quiet loglevel=3"
# systemd.gpt_auto=0: no partitions are mounted or used as swap just because of their GPT type (docs/encryption.md).
ARGS="$ARGS systemd.show_status=auto systemd.gpt_auto=0"
KV=$(ls "$R/usr/lib/modules" | grep -E -- '-s15\+?$' | sort -V | tail -1)
[ -f "$R/boot/vmlinuz-$KV" ] && [ -f "$R/boot/initramfs-s15.img" ] || { echo "kernel/initramfs missing in $R/boot (steamos-s15-setup.sh)"; exit 1; }

cat > "$R/usr/local/sbin/s15-update-esp" <<'EOS'
#!/bin/bash
# Copy the S15 kernel, initramfs and DTB from /boot to the S15BOOT partition (keeps the previous set as *.old,
# booted by the systemd-boot entry "SteamOS (S15) - previous kernel"; hold Space at power-on for the menu).
# On an encrypted install it then re-seals the TPM unlock for the new files (s15-luks-reseal).
set -euo pipefail
KV=${1:-$(ls /usr/lib/modules | grep -E -- '-s15\+?$' | sort -V | tail -1)}
M=$(mktemp -d); mount /dev/disk/by-partlabel/S15BOOT "$M"; trap 'umount "$M"; rmdir "$M"' EXIT
T=$M/EFI/S15; mkdir -p "$T"
for f in vmlinuz initramfs-s15.img x1e80100-asus-vivobook-s15-ec.dtb; do [ -f "$T/$f" ] && cp -f "$T/$f" "$T/$f.old"; done
cp -f /boot/vmlinuz-$KV "$T/vmlinuz"
cp -f /boot/initramfs-s15.img "$T/initramfs-s15.img"
cp -f /boot/x1e80100-asus-vivobook-s15-ec.dtb "$T/x1e80100-asus-vivobook-s15-ec.dtb"
sync; umount "$M"; rmdir "$M"; trap - EXIT
echo "S15BOOT updated ($KV)"
if [ -f /var/lib/s15-luks/reseal.key ]; then /usr/local/sbin/s15-luks-reseal; fi
EOS
chmod 0755 "$R/usr/local/sbin/s15-update-esp"

M=$(mktemp -d); mount "$EP" "$M"; trap 'umount "$M"; rmdir "$M"' EXIT
T=$M/EFI/S15; mkdir -p "$T" "$M/loader/entries"
cp -f "$R/boot/vmlinuz-$KV" "$T/vmlinuz"; cp -f "$R/boot/initramfs-s15.img" "$T/initramfs-s15.img"
cp -f "$R/boot/x1e80100-asus-vivobook-s15-ec.dtb" "$T/x1e80100-asus-vivobook-s15-ec.dtb"
for f in vmlinuz initramfs-s15.img x1e80100-asus-vivobook-s15-ec.dtb; do [ -f "$T/$f.old" ] || cp -f "$T/$f" "$T/$f.old"; done
install -m 0644 "$R/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$T/systemd-bootaa64.efi"
printf 'default s15.conf\ntimeout 0\neditor no\nauto-entries no\nauto-firmware yes\nconsole-mode keep\n' > "$M/loader/loader.conf"
entry() {  # file title suffix sort-key
  printf 'title   %s\nsort-key %s\nlinux   /EFI/S15/vmlinuz%s\ninitrd  /EFI/S15/initramfs-s15.img%s\ndevicetree /EFI/S15/x1e80100-asus-vivobook-s15-ec.dtb%s\noptions %s\n' \
    "$2" "$4" "$3" "$3" "$3" "$ARGS" > "$M/loader/entries/$1"
}
entry s15.conf 'SteamOS (S15)' '' s15-1
entry s15-previous.conf 'SteamOS (S15) - previous kernel' .old s15-2
sync; umount "$M"; rmdir "$M"; trap - EXIT
echo "S15BOOT: systemd-boot, kernel $KV"

# Firmware boot entry. EFI variables on X1E go through the TrustZone app uefisecapp; Linux registers them some
# seconds after boot, so remount efivarfs before using it.
mountpoint -q /sys/firmware/efi/efivars && mount -o remount,rw /sys/firmware/efi/efivars 2>/dev/null || \
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
if ! { tr -d '\0' < /sys/firmware/devicetree/base/model; } 2>/dev/null | grep -q -i "vivobook s 15"; then
  echo "not running on the Vivobook S 15 - firmware boot entry not created"; exit 0
fi
ED=/dev/$(lsblk -no PKNAME "$EP"); EN=$(cat "/sys/class/block/$(basename "$EP")/partition")
if ! efibootmgr >/dev/null 2>&1; then
  echo "WARNING: no EFI variable access - create the boot entry later from SteamOS: efibootmgr -c -d $ED -p $EN -L 'SteamOS (S15)' -l '\\EFI\\S15\\systemd-bootaa64.efi'"
  exit 0
fi
for b in $(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\* SteamOS (S15)\t.*/\1/p'); do efibootmgr -q -b "$b" -B; done
efibootmgr -q -c -d "$ED" -p "$EN" -L "SteamOS (S15)" -l '\EFI\S15\systemd-bootaa64.efi'
NEW=$(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\* SteamOS (S15)\t.*/\1/p' | head -1)
WIN=$(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\* Windows Boot Manager.*/\1/p' | head -1)
REST=$(efibootmgr | sed -n 's/^BootOrder: //p' | tr ',' '\n' | grep -v -E "^($NEW|$WIN)$" | paste -sd, || true)
efibootmgr -q -o "${WIN:+$WIN,}$NEW${REST:+,$REST}"
efibootmgr -q -n "$NEW"
echo "firmware entry Boot$NEW \"SteamOS (S15)\" after Windows; BootNext set for the first boot"
