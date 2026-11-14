#!/bin/bash
# Hibernation for the SteamOS install on the Vivobook S15 (docs/power.md#hibernation). Run as root in SteamOS.
#   hibernate.sh enable [SIZE]   swap file (default 16G) in its own subvolume of the partition's top level,
#                                resume=/resume_offset= in every boot entry of this install, initramfs, TPM re-seal
#   hibernate.sh status
#   hibernate.sh disable         resume options out of the boot entries (TPM re-seal), swap file removed
# The hooks (s15-hibernate, s15-hibernate-initrd, initcpio hook s15-hibernate, s15-hibernate-swap.service) come with
# steamos-s15-setup.sh and do nothing until this script wrote /etc/s15-hibernate.conf.
set -euo pipefail
TOP=/run/s15-os/top; SUB=$TOP/.s15-swap; SWAPFILE=$SUB/swapfile; C=/etc/s15-hibernate.conf
die() { echo "hibernate.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
{ tr -d '\0' < /sys/firmware/devicetree/base/model; } 2>/dev/null | grep -qi "vivobook s 15" || die "not the Vivobook S 15"
[ -x /usr/lib/systemd/system-sleep/s15-hibernate ] && [ -f /etc/initcpio/install/s15-hibernate ] &&
  [ -f /etc/systemd/system/s15-hibernate-swap.service ] || die "hibernation hooks missing (steamos-s15-setup.sh)"

M=
esp_mount() { M=$(mktemp -d); mount "$@" /dev/disk/by-partlabel/S15BOOT "$M"; trap 'umount "$M"; rmdir "$M"' EXIT; }
esp_umount() { sync; umount "$M"; rmdir "$M"; trap - EXIT; }
root_arg() { awk '$1 == "options" { for (i = 2; i <= NF; i++) if ($i ~ /^root=/) { print substr($i, 6); exit } }' \
  "$M/loader/entries/s15.conf"; }
entries() {   # the systemd-boot entries that boot this install (same root= as s15.conf)
  local f
  for f in "$M"/loader/entries/*.conf; do
    awk -v r="root=$1" '$1 == "options" { for (i = 2; i <= NF; i++) if ($i == r) f = 1 } END { exit !f }' "$f" && echo "$f"
  done
}
set_resume() {   # entry file, "resume=... resume_offset=..." or "" (remove)
  awk -v add="$2" '$1 == "options" { s = "options"; for (i = 2; i <= NF; i++) if ($i !~ /^resume(_offset)?=/) s = s " " $i
                                     if (add != "") s = s " " add; print s; next } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}
kver() { ls /usr/lib/modules | grep -E -- '-s15\+?$' | sort -V | tail -1; }

case ${1:-status} in
  enable)
    SIZE=${2:-16G}
    [ "$(findmnt -no FSTYPE "$TOP" 2>/dev/null)" = btrfs ] || die "$TOP (the btrfs top level, from fstab) is not mounted"
    # Valve's hibernation swap helper finds the swap file's offset with filefrag, which is wrong on btrfs: the kernel
    # would write the image over other data. It runs from hibernate.target; steamos-s15-setup.sh masks it too.
    systemctl mask -q hibernate-prepare.service
    [ -s "$SWAPFILE" ] || rm -f "$SWAPFILE"   # an empty file left by a failed attempt
    if [ ! -f "$SWAPFILE" ]; then
      [ -d "$SUB" ] || btrfs subvolume create "$SUB"
      # The top level carries the property compression=zstd and a new subvolume inherits it; a compressed file
      # cannot be made NOCOW ("cannot set NOCOW flag: Invalid argument"), so the swap subvolume gets none.
      btrfs property set "$SUB" compression ""
      btrfs filesystem mkswapfile --size "$SIZE" "$SWAPFILE"   # no copy-on-write, no compression, preallocated
    fi
    OFF=$(btrfs inspect-internal map-swapfile -r "$SWAPFILE")
    esp_mount
    R=$(root_arg)
    case $R in
      /dev/*) DEV=$R ;;
      PARTLABEL=*) DEV=/dev/disk/by-partlabel/${R#PARTLABEL=} ;;
      *) die "root=$R in s15.conf: not supported" ;;
    esac
    TD=$(findmnt -no SOURCE "$TOP" | sed 's/\[.*//')
    [ "$(stat -L -c %t:%T "$DEV")" = "$(stat -L -c %t:%T "$TD")" ] || die "root=$R is not $TD, the swap file's device"
    printf 'RESUME_DEV=%s\nRESUME_OFFSET=%s\nSWAPFILE=%s\n' "$DEV" "$OFF" "$SWAPFILE" > $C
    for f in $(entries "$R"); do
      set_resume "$f" "resume=$R resume_offset=$OFF"
      echo "boot entry $(basename "$f"): resume=$R resume_offset=$OFF"
    done
    esp_umount
    systemctl enable -q s15-hibernate-swap.service
    systemctl restart s15-hibernate-swap.service
    swapon --show
    KV=$(kver)
    rm -f /boot/initramfs-s15.img /boot/initrd.uImage
    mkinitcpio -c /etc/mkinitcpio-s15.conf -k "$KV" -g /boot/initramfs-s15.img 2>&1 | grep -i -E "error|image generation" || true
    # The Frame's deckard-uimage post hook wraps the image in a 64-byte U-Boot header and deletes the original.
    [ -f /boot/initramfs-s15.img ] || dd if=/boot/initrd.uImage of=/boot/initramfs-s15.img bs=64 skip=1 status=none
    lsinitcpio /boot/initramfs-s15.img | grep -q 's15-hibernate-initrd$' || die "s15-hibernate-initrd is not in the initramfs"
    /usr/local/sbin/s15-update-esp "$KV"   # copies it to S15BOOT and re-seals the TPM unlock for the new entries
    echo "hibernation enabled: systemctl hibernate" ;;
  status)
    if [ -r $C ]; then . $C; echo "config: resume from $RESUME_DEV page $RESUME_OFFSET ($SWAPFILE)"; else echo "not enabled"; fi
    swapon --show
    [ -f "$SWAPFILE" ] && echo "swap file offset now: page $(btrfs inspect-internal map-swapfile -r "$SWAPFILE")"
    echo "this boot: $(grep -o 'resume[^ ]*' /proc/cmdline | tr '\n' ' ')(kernel: $(cat /sys/power/resume) page $(cat /sys/power/resume_offset))"
    esp_mount -o ro
    for f in "$M"/loader/entries/*.conf; do echo "boot entry $(basename "$f"): $(grep -o 'resume[^ ]*' "$f" | tr '\n' ' ')"; done
    esp_umount
    lsinitcpio /boot/initramfs-s15.img 2>/dev/null | grep -q 's15-hibernate-initrd$' && echo "initramfs: s15-hibernate hook" ||
      echo "initramfs: no s15-hibernate hook"
    echo "hibernate-prepare.service: $(systemctl is-enabled hibernate-prepare.service 2>/dev/null || true)"
    echo "logind CanHibernate: $(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate 2>/dev/null)" ;;
  disable)
    esp_mount
    R=$(root_arg)
    for f in $(entries "$R"); do set_resume "$f" ""; echo "boot entry $(basename "$f"): resume options removed"; done
    esp_umount
    [ -f /var/lib/s15-luks/reseal.key ] && /usr/local/sbin/s15-luks-reseal
    rm -f $C
    systemctl disable -q s15-hibernate-swap.service || true
    if [ -f "$SWAPFILE" ]; then
      swapoff "$SWAPFILE" 2>/dev/null || true
      rm -f "$SWAPFILE"
      btrfs subvolume delete "$SUB"
    fi
    echo "hibernation disabled" ;;
  *) die "usage: hibernate.sh enable [SIZE] | status | disable" ;;
esac
