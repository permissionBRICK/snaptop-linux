#!/bin/bash
# One-shot install of SteamOS (Valve's Steam Frame image) on the ASUS Vivobook S 15 (S5507QA, Snapdragon X Elite),
# next to Windows. Run as root from a live ARM64 Linux booted on the laptop (see README.md), after
# windows/Prepare-S15.ps1 has freed disk space and created the S15BOOT partition with the firmware export.
#
#   sudo ./install.sh [--yes] [--timezone Area/City] [--kernel-payload DIR] [--reinstall]
#
#   --yes             do not ask for confirmation
#   --timezone TZ     time zone for SteamOS (default: the live system's, if it is not UTC)
#   --kernel-payload  use an existing kernel/build.sh payload instead of building the kernel here (~30-40 min)
#   --reinstall       reuse and reformat an existing SNAPSTEAM-NVME partition from an earlier run
#
# What it does: install build tools (apt), create the SteamOS partition in the free space, download the SteamOS
# image, fetch pinned firmware/UCM, build the kernel natively, adapt SteamOS to this laptop, build the Plasma
# Wi-Fi/Bluetooth applets, install systemd-boot on S15BOOT and add the firmware boot entry behind Windows.
# It never writes to Windows' partitions, the Windows ESP or the Qualcomm firmware partitions at the start of the disk.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
YES=; TZ_SET=; PAYLOAD=; REINSTALL=
while [ $# -gt 0 ]; do
  case $1 in
    --yes) YES=1 ;;
    --timezone) TZ_SET=$2; shift ;;
    --kernel-payload) PAYLOAD=$(realpath "$2"); shift ;;
    --reinstall) REINSTALL=1 ;;
    -h|--help) sed -n 2,20p "$0"; exit 0 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac; shift
done
LOG=/tmp/s15-install.log; exec > >(tee -a "$LOG") 2>&1
R=/mnt/steam; EM=/mnt/s15boot; WORK=/tmp/s15-install; MIN_GB=64
N=10; n=0; step() { n=$((n + 1)); echo; echo "=== [$n/$N] $* ($(date +%T))"; }
die() { echo; echo "ERROR: $*"; echo "log: $LOG"; exit 1; }

step "checks"
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ "$(uname -m)" = aarch64 ] || die "run this on the laptop itself (ARM64 live Linux)"
MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || cat /sys/class/dmi/id/product_name 2>/dev/null || true)
grep -q -i -E "vivobook.?s.?15|S5507QA" <<< "$MODEL" || die "this is not an ASUS Vivobook S 15 S5507QA ($MODEL)"
EP=$(blkid -L S15BOOT 2>/dev/null || true)
[ -n "$EP" ] || die "no partition labelled S15BOOT - run windows/Prepare-S15.ps1 in Windows first"
EP=$(readlink -f "$EP"); EPN=$(cat "/sys/class/block/$(basename "$EP")/partition"); DISK=/dev/$(lsblk -no PKNAME "$EP")
case $DISK in /dev/nvme*) ;; *) die "S15BOOT is not on the internal NVMe ($DISK)";; esac
[ "$(blkid -o value -s TYPE "$EP")" = vfat ] || die "S15BOOT is not FAT32"
[ "$(blockdev --getsize64 "$EP")" -lt $((2 * 1024 ** 3)) ] || die "S15BOOT is larger than 2 GiB - not the partition Prepare-S15.ps1 creates"
lsblk -no PARTTYPE "$DISK" | grep -q -i ebd0a0a2-b9e5-4433-87c0-68b6b72699c7 || die "no Windows data partition on $DISK"
ping -c1 -W5 download.kde.org >/dev/null 2>&1 || curl -fsI -m 10 https://download.kde.org >/dev/null || die "no internet connection"
OLD=$(readlink -f /dev/disk/by-partlabel/SNAPSTEAM-NVME 2>/dev/null || true)
if [ -n "$OLD" ]; then
  [ -n "$REINSTALL" ] || die "$OLD (SNAPSTEAM-NVME) exists from an earlier install - rerun with --reinstall to reformat it"
  P=$OLD; SIZE=$(blockdev --getsize64 "$P")
else
  SS=$(blockdev --getss "$DISK"); F=$(sgdisk -F "$DISK"); E=$(sgdisk -E "$DISK")
  SIZE=$(( (E - F + 1) * SS )); [ "$SIZE" -ge $((MIN_GB * 1024 ** 3)) ] || \
    die "only $((SIZE / 1024 ** 3)) GiB free on $DISK - shrink Windows more (Prepare-S15.ps1 -LinuxSizeGB)"
fi
[ -n "$TZ_SET" ] || { TZ_SET=$(timedatectl show -p Timezone --value 2>/dev/null || true); case $TZ_SET in ""|UTC|Etc/UTC) TZ_SET=;; esac; }
mkdir -p "$EM"; mount -o ro "$EP" "$EM"; FWX=$EM/s15-firmware
[ -f "$(find "$FWX" -name qcadsp8380.mbn 2>/dev/null | head -1)" ] || { umount "$EM"; die "no firmware export in S15BOOT:\\s15-firmware - rerun Prepare-S15.ps1"; }
cat <<EOF

  Laptop:      $MODEL
  Disk:        $DISK
  Boot:        $EP (S15BOOT, gets systemd-boot)
  SteamOS:     ${OLD:-new partition in the free space} ($((SIZE / 1024 ** 3)) GiB, will be FORMATTED)
  Time zone:   ${TZ_SET:-SteamOS default}
  Kernel:      ${PAYLOAD:-built here (30-40 min)}
  Windows and its partitions are not touched.
EOF
if [ -z "$YES" ]; then read -r -p "Type YES to install: " a; [ "$a" = YES ] || { umount "$EM"; die "aborted"; }; fi

step "build tools and helpers"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates python3 python3-requests python3-zstandard squashfs-tools btrfs-progs \
    gdisk dosfstools efibootmgr zstd cpio libarchive-tools rsync git build-essential bc flex bison libssl-dev \
    libelf-dev device-tree-compiler kmod >/dev/null
fi
for t in curl python3 unsquashfs mkfs.btrfs sgdisk efibootmgr zstd cpio bsdtar rsync git gcc make bc flex bison dtc fdtoverlay; do
  command -v $t >/dev/null || die "missing $t - install it (on Ubuntu/Debian the script does this itself)"
done
python3 -c 'import requests, zstandard' 2>/dev/null || die "missing Python modules requests and zstandard"

step "SteamOS partition"
umount "$EM"
for p in $(lsblk -nlo PATH "$DISK"); do findmnt -n "$p" >/dev/null && [ "$p" != "${OLD:-x}" ] && \
  case $(lsblk -no PARTTYPE "$p") in ebd0a0a2*|c12a7328*) die "$p is mounted - unmount Windows/EFI partitions first";; esac; done
umount -q "$R" 2>/dev/null || true; [ -n "$OLD" ] && umount -q "$OLD" 2>/dev/null || true
if [ -z "$OLD" ]; then
  sgdisk -n "0:$F:$E" -t 0:8300 -c 0:SNAPSTEAM-NVME "$DISK" >/dev/null
fi
sgdisk -t "$EPN:EF00" -c "$EPN:S15BOOT" "$DISK" >/dev/null
partprobe "$DISK" 2>/dev/null || true; udevadm settle; sleep 1
P=$(readlink -f /dev/disk/by-partlabel/SNAPSTEAM-NVME)
[ -b "$P" ] || die "the new partition did not appear"
# A rerun keeps a kernel that an earlier, failed run already built
if [ -n "$OLD" ] && [ -z "$PAYLOAD" ]; then
  mkdir -p "$WORK/old"
  if mount -o ro "$P" "$WORK/old" 2>/dev/null; then
    if [ -f "$WORK/old/var/tmp/s15-kernel-build/payload/kernel-version" ]; then
      rm -rf "$WORK/kernel-payload"; cp -a "$WORK/old/var/tmp/s15-kernel-build/payload" "$WORK/kernel-payload"
      PAYLOAD=$WORK/kernel-payload; echo "keeping the kernel built by the earlier run ($(cat "$PAYLOAD/kernel-version"))"
    fi
    umount "$WORK/old"
  fi
fi
mkfs.btrfs -q -f -L steamos "$P"
mkdir -p "$R"; mount -o noatime,compress=zstd:1 "$P" "$R"
echo "$P formatted and mounted at $R"

step "firmware and audio configuration (pinned downloads + your Windows export)"
mkdir -p "$EM" "$WORK"; mount -o ro "$EP" "$EM"
bash "$HERE/steamos/fetch-deps.sh" "$WORK/deps" "$EM/s15-firmware"
umount "$EM"

step "SteamOS image (Steam Frame build, about 3 GB download)"
bash "$HERE/steamos/frame-rootfs.sh" "$R"

step "kernel"
if [ -z "$PAYLOAD" ]; then
  echo "building natively, about 30-40 minutes; progress in $LOG"
  KW=$R/var/tmp/s15-kernel-build
  WORK=$KW bash "$HERE/kernel/build.sh" > >(grep -E -v "^  (CC|LD|AR|AS|HOSTCC|DTC|OBJCOPY|SIGN|STRIP|INSTALL|SYNC|DEPMOD|GEN|UPD|CHK|CALL|WRAP|MKELF|LDS|CPP|SHIPPED|COPY|ZSTD|XZ)" >> "$LOG") 2>&1 \
    || die "kernel build failed (end of $LOG)"
  PAYLOAD=$KW/payload
fi
[ -f "$PAYLOAD/kernel-version" ] || die "no kernel payload"
echo "kernel $(cat "$PAYLOAD/kernel-version")"

step "adapting SteamOS to the laptop"
R=$R PAYLOAD=$PAYLOAD FW=$WORK/deps/firmware UCM=$WORK/deps/ucm2 TIMEZONE=$TZ_SET INITRAMFS_ALL_DRIVERS=1 \
  bash "$HERE/steamos/steamos-s15-setup.sh"

step "Plasma Wi-Fi and Bluetooth applets (built natively, a few minutes)"
# The overlay the build uses cannot sit on the live system's own overlay root, so it gets a small tmpfs.
mkdir -p "$WORK/desktop-net"; mountpoint -q "$WORK/desktop-net" || mount -t tmpfs -o size=6G tmpfs "$WORK/desktop-net"
bash "$HERE/desktop-net/build.sh" "$R" "$WORK/desktop-net" > >(tail -n 20 >> "$LOG") 2>&1 || die "desktop-net build failed (end of $LOG)"
PKG=$(ls -t "$WORK"/desktop-net/s15-desktop-net-*.tar.zst | head -1)
zstd -dc "$PKG" | tar -tf - | { grep -v '/$' || true; } | sed 's#^#/#' > "$R/var/lib/s15-desktop-net.files"
zstd -dc "$PKG" | tar -xpf - -C "$R" --no-same-owner
chroot "$R" ldconfig
echo "installed $(wc -l < "$R/var/lib/s15-desktop-net.files") files"
umount "$WORK/desktop-net"

step "boot partition, systemd-boot and firmware boot entry"
bash "$HERE/steamos/install-esp.sh" "$R" "$EP"

step "cleanup"
rm -rf "$R/var/tmp/s15-kernel-build"
# This repository on the installed system, for later kernels, the game tools and the Game Mode reboot entry
rm -rf "$R/opt/snaptop-linux"; mkdir -p "$R/opt"; rsync -a --exclude=.git "$HERE/" "$R/opt/snaptop-linux/"
cp "$LOG" "$R/var/log/s15-install.log"
sync; umount "$R"
cat <<'EOF'

Done. Reboot: the laptop starts SteamOS once (BootNext). Afterwards Windows stays the default:
  - SteamOS -> Windows: "Reboot to Windows" icon on the desktop; for a Game Mode entry run, after logging in
    to Steam (with Steam closed): sudo /opt/snaptop-linux/steamos/steamos-s15-dualboot.sh
  - Windows -> SteamOS: windows/Install-RebootShortcut.ps1 adds a "Reboot to SteamOS" icon, or press ESC at power-on
  - first start: Desktop Mode (Plasma). Wi-Fi in the tray, then "Return to Gaming Mode" to log in to Steam.
  - Resume BitLocker in Windows when you are done with BIOS changes: Resume-BitLocker -MountPoint C:
EOF
