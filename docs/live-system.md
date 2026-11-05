# The live system for the install

`install.sh` runs in a live ARM64 Linux booted from a USB stick on the laptop. It needs: UEFI boot on the Snapdragon
X1E with the Vivobook S 15 device tree, the NVMe, a network connection, a root shell and `apt` (on other
distributions install the tools listed in `install.sh` by hand).

## Which live system

- **Ubuntu Desktop for ARM64** (26.04 LTS or newer) supports Snapdragon X Elite laptops in its generic ARM64 ISO and
  picks the device tree by itself. We have not run its live session on this model ourselves; if it does not boot,
  see below. Write the ISO to a stick with balenaEtcher or Rufus (DD mode), or `dd` on Linux.
- Network: Wi-Fi (ath12k; the firmware is in linux-firmware), or a USB Ethernet adapter on a USB-C port.
- 16 GB of RAM are enough: `install.sh` keeps the SteamOS image and the kernel build on the NVMe, not in RAM.

## BIOS settings (F2 at power-on)

- Secure Boot: **Disabled** (our boot loader and kernel are unsigned). `Prepare-S15.ps1` suspends BitLocker first,
  so Windows does not ask for the recovery key afterwards. Resume BitLocker when you are done with BIOS changes.
- Fast Boot: **Disabled**, otherwise USB is not initialised before the boot menu.
- Boot menu: **ESC** at power-on. Use the USB-A port for the stick, not a hub or dock.

## If a live system does not boot

What we learned while testing from a self-built Debian trixie ARM64 stick (the root filesystem as initramfs, a
standalone GRUB):

- The board needs its device tree: GRUB `devicetree /path/x1e80100-asus-vivobook-s15.dtb` before `linux`. Mainline
  ships it since Linux 6.11 (`arch/arm64/boot/dts/qcom/`, in Debian's and Ubuntu's kernel packages under
  `/usr/lib/linux-image-*/qcom/`).
- A standalone GRUB reads the `grub.cfg` next to its binary first and skips its embedded config: put the `search`
  for its partition into that `grub.cfg` as well.
- A worn USB 3 stick read fine but dropped off the bus under sustained writes; keep the live root in RAM.
- Device names change between boots (`sda` was once an external drive). Find disks by label/partlabel.
- Early boots from the stick sometimes reset or hung before any kernel log (3 of about 10); boots from the NVMe
  have been reliable.

## Diagnostics

`tools/snaptop-diag.sh` (read-only hardware survey: remoteprocs, DRM, GPU, audio, cameras, input, USB, power,
thermal, Wi-Fi/BT) and `tools/snaptop-diag2.sh` (cpufreq, Bluetooth, Wi-Fi scan, cameras) work in a live system and
in SteamOS.
