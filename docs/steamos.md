# SteamOS on the Vivobook S 15

Valve has no SteamOS for ARM laptops, but the **Steam Frame** headset runs an aarch64 SteamOS (`deckard` image,
SteamOS 0.5.3) with a native ARM64 Steam client, Proton 11 (ARM64) and FEX. Its rootfs is published on Valve's
public update CDN. We put that rootfs onto the laptop's NVMe, swapped in our kernel and firmware, and turned the
headset session into a normal Steam Deck-style Game Mode on the laptop panel. The image download and casync
extraction use the extractor from [SteamOS-ARM-Port](https://github.com/hashtagbasit/SteamOS-ARM-Port), which ports
the same image to Snapdragon handhelds.

Windows stays installed (dual boot); see [Boot](#boot-bitlocker-safe).

## What `install.sh` does

The quick start is in the [README](../README.md). `install.sh` runs in a live ARM64 Linux on the laptop, after
`windows/Prepare-S15.ps1` has shrunk C: and created the 1 GB FAT32 partition `S15BOOT` with the firmware export:

1. Checks: the laptop model, `S15BOOT` on the internal NVMe with the firmware export, enough free space, internet.
   It shows the plan and asks for `YES` before writing anything.
2. Installs its tools in the live system (apt: btrfs/GPT/EFI tools, casync helpers, a native kernel toolchain).
3. Creates the partition `SNAPSTEAM-NVME` (Linux, btrfs) in the largest free block, and turns `S15BOOT` into an
   EFI system partition. Windows' own partitions, its ESP and the Qualcomm firmware partitions at the start of the
   disk (entries 1-11: ToolsFv, LogFs, NHLOS, ...) are never written to.
4. `steamos/fetch-deps.sh`: pinned linux-firmware files (Wi-Fi, Bluetooth, GPU microcode, the S15 audio topology),
   alsa-ucm-conf 1.2.16 with the community S15 profile, plus the ASUS files from `S15BOOT\s15-firmware`.
5. `steamos/frame-rootfs.sh`: downloads the Steam Frame image (about 3 GB of casync chunks from Valve's public
   CDN, checked against the sha256 in the RAUC manifest), assembles it on the new partition, copies its files.
6. `kernel/build.sh`: builds the kernel natively (30-40 min) unless `--kernel-payload` gives one.
7. `steamos/steamos-s15-setup.sh`: adapts the image (next section).
8. `desktop-net/build.sh`: builds the Plasma Wi-Fi and Bluetooth applets natively against the image (a few minutes).
9. `steamos/install-esp.sh`: systemd-boot, kernel, initramfs and DTB on `S15BOOT`, the firmware entry
   "SteamOS (S15)" after Windows Boot Manager, BootNext for the first start.

Later kernels: build a payload with `kernel/build.sh` (on the laptop in SteamOS or on any Linux PC) and run
`steamos/install-kernel.sh <payload>` in SteamOS. Later SteamOS builds from Valve: `s15-os-update`
([updates.md](updates.md)).

## Cameras and browser access

The setup script runs `steamos/install-camera.sh` inside the installed image. It builds libcamera 0.7.1
with the simple pipeline and software ISP, plus the libcamera SPA plugin from PipeWire 1.6.8. Source archives
are pinned by SHA-256. The Frame image lacks these components; its repository's libcamera 0.2.0 is too old
for the tested setup. The script installs libcamera under `/usr/local` and only adds the camera plugin to
the existing PipeWire installation. It does not replace PipeWire or its audio plugins.

For an existing installation, run as root on the laptop:

```sh
bash steamos/install-camera.sh
```

Then reboot, or run `systemctl --user restart wireplumber` from the desktop user's terminal and restart
the browser. Restarting WirePlumber briefly interrupts audio. The script skips an already installed build;
its file list is `/var/lib/s15-camera.files`. Temporary build files are removed on exit.

Check `cam -l` for sensor detection, then `wpctl status` in the desktop session for a Video source.
A raw camera capture alone does not verify browser support. Firefox Flatpak uses the desktop camera portal;
if that portal reports no camera, websites cannot see one. Test a website after granting camera access.
In Firefox, set `media.webrtc.camera.allow-pipewire` to `true` in `about:config` and fully restart Firefox.
Without that setting, the tested Flatpak build did not discover the camera even with a working portal.

Rapid reopen or resolution changes also require the CCI recovery patch in our kernel build. Without it,
the OV02C10 can leave its controller stalled (`master 1 queue 0 timeout`), and WirePlumber may hang after
the failed stream start. The patch resets CCI on runtime resume and retries a transfer once after the
existing timeout reset. A recovered transfer may still log that timeout.

The visible camera activity LED is not configured in the current device tree. Its wiring and operation
under Linux remain unverified; do not infer that the camera is off from an unlit indicator. The HM1092
IR illuminator is a separate component.

## What `steamos-s15-setup.sh` changes in the Frame image

| Change | Why |
|---|---|
| Our kernel modules, `vmlinuz`, DTBs in `/boot` | The Frame kernel is for the headset's SoC. |
| Firmware: ASUS blobs, `ath12k/WCN7850`, `qca`, `qcom/gen70500_*` | The image only has the headset's firmware. |
| ALSA UCM: S15 profile | Without it, no speaker/mic routing. |
| `scmi-cpufreq` in `modules-load.d` | It does not autoload; without it no idle downclocking. |
| Masks headset units (SteamVR, `deckard-*` fan/LED/FPGA/charger, adbd/USB gadget, `steamos-boot`, `systemd-repart`, Bluetooth/Wi-Fi MAC setters, A/B partition mounts) and, from 0.5.7, the swap file for hibernation (`swapfile.service`, `home-swapfile.swap`: btrfs refuses a swap file on a compressed mount, and zram is there), and `iio-sensor-proxy` (built for the Frame's sensor DSP: each probe waited about 100 s for `hexagonrpcd`, which the laptop lacks, and held up restarts at "A stop job is running for IIO Sensor Proxy"; the laptop has no sensor it could use) | They fail or fight with the laptop hardware. **Not** `iwd`: NetworkManager uses it as the Wi-Fi backend (masking it leaves Wi-Fi "enabled" with no networks). |
| fstab: A/B partition-set mounts commented out | Everything lives on one btrfs. |
| `gamescope-session`: `--backend drm --prefer-output '*,eDP-1'` plus `-w/-h/-W/-H` from the panel's native mode, `--keep-alive --mangoapp --steam` | The Frame runs gamescope with the OpenVR backend for the headset. |
| `RUNSTEAM.sh`: drop `-vrgamepadui`, `-deckard` → `-steampal` | Steam Deck UI instead of the headset UI. |
| `steam.service` affinity `0xfff` | The Frame pins games to 5 cores; the X1E has 12 equal cores. |
| WirePlumber: `node.stream.enable-spatial-audio = false` | The Frame spatializer needs SteamVR's `vraudiocompositor.so`. Without it, streams never link and there is no sound at all. |
| Desktop Mode (`steamos-s15-desktop.sh`) | See below. |
| Speaker UCM without the WSA macro compander | Short sounds started loud and faded ([games](games.md#audio-in-steams-menus)). |
| Reboot to Windows (`steamos-s15-dualboot.sh`) | See [Switching between Windows and SteamOS](#switching-between-windows-and-steamos). |
| USB NTFS/exFAT automount (`s15-media-mount`, udev rule on `ID_PATH=*usb*`, ntfs3 with `windows_names`) | Play from an existing Windows game drive. Match on `ID_PATH`: some USB-SATA bridges report `ID_BUS=ata`. |
| systemd initramfs `/etc/mkinitcpio-s15.conf` with hooks from `steamos/initcpio/` | See [Initramfs](#initramfs). |

## Initramfs

`/etc/mkinitcpio-s15.conf` builds a systemd-based initramfs (`/boot/initramfs-s15.img`, copied to `S15BOOT`):

| Hook / module | Why |
|---|---|
| `s15` | Clock, interconnect, PHY, PCIe/NVMe, USB and USB storage drivers for the root filesystem. |
| `s15-dsp` | Starts the ADSP and CDSP with their firmware from the initramfs. The display driver waits for the USB-C/DisplayPort chain behind the ADSP (`pmic_glink`); without the DSPs it could only start after the root filesystem. |
| `kms`, `s15-display` | The display driver (msm) is in the image but only loaded when a passphrase is requested, next to the prompt and without delaying it (`s15-prompt-display.service`); meanwhile the Caps Lock light blinks (`s15-prompt-signal.service`). See below. |
| `keyboard`, `sd-vconsole`, `i2c_hid_of`, `hid_asus_ec` | Internal keyboard, console keymap and font (`/etc/vconsole.conf`) for a passphrase prompt. The keymap is global for all consoles, so SteamOS's own `systemd-vconsole-setup` is masked. |
| `tpm_qcom_crb`, `sd-encrypt` | Firmware TPM and LUKS, for an encrypted root ([tpm.md](tpm.md)); idle without `crypttab`/`rd.luks`. |
| `sd-s15-etc-overlay` | Mounts SteamOS's `/etc` overlay before switch-root, so units enabled at runtime start at boot. |

Why the DSPs start this early: the firmware's framebuffer (efifb) does not survive the kernel's cleanup of unused
clocks and power domains (each one alone turns the panel black, and the eDP supply is cut ~30 s later), so the boot
screen goes black after a few seconds. The real display driver needs the DSPs (above); with them in the initramfs it
can take over before the root filesystem is mounted, so a passphrase prompt is visible. `s15-dsp` takes the firmware
names from the devicetree; if a file is missing it adds nothing (a DSP whose driver loads in the initramfs but whose
firmware is not there would never start), and the DSPs start from the root filesystem as before.

Why the display driver is still only loaded for a prompt: its takeover from the firmware fails in about 1 boot in 10
([known-issues.md](known-issues.md), "Display takeover"). In SteamOS the desktop's first mode set repairs that within
seconds. In the initramfs nothing does, and the console setup's font redraws each wait a second for a frame that never
comes: a boot on 2026-11-03 sat on a blue screen for over two minutes. So a normal boot (TPM unlock, or no
encryption) leaves the display to SteamOS. When a passphrase is requested, the prompt starts at once and the display
driver loads beside it; the Caps Lock light blinks until the volume is open, so the prompt is recognisable even if the
display start fails (plain blue or black screen: type the passphrase, Enter). In the initramfs nothing reloads the
console font when the driver's console appears (`90-vconsole.rules` is overridden), and nothing blanks the console:
both hold the console lock through every failing frame, which kept the prompt from printing and reading.
`s15-display-check` only logs whether the takeover worked (in SteamOS from a udev rule when `fb0` appears).

Boot (2026-11-03, display in the initramfs): display at 3.4 s, switch-root at 3.8 s, `graphical.target` at 6.6 s
after the kernel started (15-16 s with the earlier busybox initramfs, which started the DSPs from the root filesystem);
sound is ready at about 10 s instead of 20 s. Two harmless messages: `failed to load gen70500_sqe.fw` (the GPU
firmware is not in the initramfs; it loads from the root filesystem when the GPU is first used) and
`32300000.remoteproc: timeout waiting for subsystem event response` (the CDSP does not answer the ADSP's start
notification in the initramfs; the ADSP reports "up" 5 s later, everything works).

Gotchas on this image:
- `add_all_modules` takes one pattern per call; passing several silently adds nothing.
- The Frame's `deckard-uimage` post hook wraps every image mkinitcpio builds in a 64-byte U-Boot header
  (`/boot/initrd.uImage`) and deletes the plain image. The scripts strip the header again with `dd bs=64 skip=1`.
- No `cpio` in the image; use `bsdtar`.
- Do not test initramfs changes with a read-write root: a forced power-off of a hung boot once left a btrfs tree log
  that the kernel could not replay (`tree-log.c` transaction abort, -22), so every later boot stopped before the root
  was mounted (black screen, invisible emergency shell). `btrfs rescue zero-log` from a live system fixed it. Test
  entries use `rootflags=...,notreelog` or a root that does not exist.

## Desktop Mode

The Frame's `plasma.desktop` starts a nested "Gamescope VR Session" for the headset. Switching to desktop mode
on the laptop just bounced back to Game Mode, and later showed a black screen with a cursor. `steamos-s15-desktop.sh`
(adapted from SteamOS-ARM-Port) replaces it with a real Plasma Wayland session:

- `s15-startplasma` clears the Game Mode environment and starts `startplasma-wayland`.
- `s15-prepare-plasma --switch` runs from `steamos-session-select` before the switch and also unsets
  `DISPLAY`/`WAYLAND_DISPLAY`; inside the Plasma start (user unit `s15-plasma-env.service`) it must **not** unset
  them. Doing so was the cause of the black screen.
- Plasma user units get `QT_QPA_PLATFORM=wayland;xcb` and friends. Apps started from Plasma inherit it; with plain
  `wayland`, Qt apps without access to the Wayland socket (Flatpaks that only allow X11, such as the Thincast RDP
  client) did nothing when started (Qt aborts: "no Qt platform plugin could be initialized"); with the fallback
  they run on Xwayland.
- A "Return to Gaming Mode" desktop icon (the image has none).
- **60 Hz on battery, 120 Hz on AC**, like Windows (user service `s15-refresh-on-battery`, about 0.7 W less at idle):
  it follows UPower's power-supply events, so it switches as soon as the charger is plugged in or out, and right
  after a resume if that happened during sleep. A rate set by hand in the display settings stays until the next
  plug/unplug. Game Mode is not covered: Steam/gamescope own the display there.
- **Boots into Desktop Mode by default** (`DEFAULT_MODE=game` keeps Game Mode). steamos-manager keeps the default
  login session in `/etc/sddm.conf.d/zz-steamos-autologin.conf` and one-off switches in
  `zzt-steamos-temp-login.conf`; our `steamos-session-select` no longer makes "Return to Gaming Mode" the new
  default, so Game Mode lasts until the next reboot. `steamosctl set-default-login-mode game|desktop` (as the
  user) changes the default.
- **Wi-Fi and Bluetooth in the tray:** the 0.5.3 image ships neither `plasma-nm` nor `bluedevil`, so Desktop Mode
  has no network or Bluetooth applet, no settings pages for them and no secret agent (no password prompt).
  `desktop-net/` builds whichever of them the image lacks, with NetworkManagerQt, ModemManagerQt and BluezQt as
  needed, at the image's own KDE Frameworks and Plasma versions (read from the image: KF6 6.14 / Plasma 6.2.5 in
  0.5.3; 0.5.7 has KF6 6.23 / Plasma 6.6.2 and its own `plasma-nm`, so only Bluetooth is built), in a chroot of the
  image under an overlay; `install.sh` and `s15-os-update` run it natively on the laptop (a few minutes). bluedevil is built without its handbook (KF6DocTools is not in the image); VPN editor plugins are
  included, OpenConnect is not. The package holds no file that the image already has. To rebuild or remove it
  in a running SteamOS:

  ```sh
  sudo mkdir -p /run/dn && sudo mount -t tmpfs -o size=6G tmpfs /run/dn   # the build overlay needs its own fs
  sudo desktop-net/build.sh / /run/dn                     # native; an x86 host with qemu-user can build from a
                                                          # Frame rootfs.img instead (hours instead of minutes)
  sudo desktop-net/install.sh /run/dn/s15-desktop-net-<date>.tar.zst   # restarts kded and plasmashell
  sudo desktop-net/uninstall.sh                           # removes exactly the installed files
  ```

- **Battery and Bluetooth always in the tray:** both applets hide themselves in the tray's overflow when they have
  nothing to report (on AC with the battery not charging, the normal state with a charge limit; no Bluetooth device
  connected). A Plasma update script (`s15-systray-always-shown.js`, run once per user at the next Plasma start, also
  for a new user's default panel) sets them to "Always shown"; a later change in the tray settings stays. Plasma 6.6
  keeps the tray's item lists in the tray widget's own `General` group, older versions in an inner containment; the
  script handles both.
- **OpenVPN connections:** the image has no `openvpn` and no OpenVPN plugin for NetworkManager, so NetworkManager
  reports missing support for OpenVPN connections, even where Plasma's OpenVPN editor is present.
  `steamos/install-nm-openvpn.sh` (run by the setup, so by `install.sh` and for every update) installs `openvpn` from
  the image's own package repository and builds NetworkManager-openvpn 1.12.3 (GNOME's release tarball, checksum
  pinned, without the GNOME editor). A `.ovpn` profile can then be imported in the network settings or with
  `nmcli connection import type openvpn file <profile>.ovpn`. Certificates and keys belong in `/etc/openvpn`, which
  an update keeps ([updates.md](updates.md#what-an-update-keeps)); NetworkManager's connections are kept anyway.
  Remove: `sudo xargs -a /var/lib/s15-nm-openvpn.files rm -f && sudo pacman -R openvpn`.

## Keyboard colour

`steamos-s15-keyboard.sh` sets the keyboard RGB per session: rainbow in Game Mode (the EC's own effect), solid
white in Desktop Mode, and the last one again after standby. Colours are `s15-kbd-color` arguments in
`/etc/s15-kbd-mode.conf` (`GAME=...`, `DESKTOP=...`). The session targets (`gamescope-session.target`,
`plasma-workspace.target`) start a user unit that starts the root unit `s15-kbd-mode@<mode>.service`, which a polkit
rule allows the desktop user to start. Brightness stays on the Fn key.

On battery the light goes off after 30 s without a key press or touchpad touch and comes back with the next one, at
the level it had (as ASUS's software does on Windows; the light costs about 0.8 W at level 1, see
[power.md](power.md)). `s15-kbd-idle.service` watches the built-in keyboard and touchpad; `IDLE_OFF_BATTERY` and
`IDLE_OFF_AC` in `/etc/s15-kbd-mode.conf` set the seconds (0: never; default 30 and 0).

Fn lock (Fn+Esc): the EC only reports the key press; `hid-asus-ec` flips its own value (`fn_lock` in sysfs: 1 = F1-F12
first, 0 = media keys first) and sends it, and the keyboard follows. After a boot the keyboard was found in F-key
mode while the driver said 0, so the first Fn+Esc did nothing visible. `s15-kbd-mode` re-sends the driver's value at
every session start and after standby, and sets `FN_LOCK` from `/etc/s15-kbd-mode.conf` once per boot (default 0).

## Display

- 2880x1620 @ 120 Hz, 8 bpc with our kernel patch ([kernel](kernel.md)).
- Open: Steam's Game Mode treats the eDP panel as an external display (`IsExternalDisplay=1`), which caps the
  "Native" resolution offered to games at 1920x1080. gamescope now renders at the panel's native mode
  (`-w/-h/-W/-H`), but whether Steam then offers the full resolution is not verified yet.

## Boot (BitLocker-safe)

Windows Boot Manager stays first and unmodified, and nothing chainloads Windows; otherwise BitLocker's TPM
measurements change and Windows asks for the recovery key.

- `S15BOOT` (1 GB FAT32, created by `Prepare-S15.ps1`, made an EFI system partition by `install.sh`) holds
  `\EFI\S15\` with kernel, initramfs, DTB and **systemd-boot** (from the SteamOS image), and `\loader\` with entries
  for the current and the previous kernel (`*.old`). The Windows ESP is not touched.
- `/usr/local/sbin/s15-update-esp` in SteamOS copies `/boot` to `S15BOOT` and keeps the previous set
  (`install-kernel.sh` calls it).
- Firmware entry **"SteamOS (S15)"** sits *behind* Windows Boot Manager in `BootOrder`. Power on: Windows. ESC at
  power-on: firmware menu, "SteamOS (S15)" starts SteamOS without a menu wait (hold Space for systemd-boot's menu:
  previous kernel, firmware setup). The reboot shortcuts use BootNext.
- Boot time (2026-11-03, `systemd-analyze`): firmware 7.0 s, systemd-boot 0.8 s, kernel 0.8 s, initramfs 3.0 s,
  userspace 2.7 s, so about 14.5 s to the login screen (23 s on 2026-11-01 with the busybox initramfs). An earlier
  GRUB setup took about 7 s longer (3 s menu, slow reading of the 52 MB kernel).
- The initramfs written during the install carries all boot drivers; kernels installed later in SteamOS get one
  with only the drivers for present hardware (mkinitcpio autodetect, about 200 modules, 30 MB).
- EFI variables on X1E go through the TrustZone app `uefisecapp` (the S15 is on the kernel's allowlist). Linux
  registers them some seconds after boot, after systemd has mounted `efivarfs`; remount it before `efibootmgr`.

## Bluetooth devices in both systems

A Bluetooth device keeps one pairing key per host address, and Windows and SteamOS share the laptop's address, so
pairing in one system breaks the pairing in the other. Giving SteamOS Windows' keys makes one pairing serve both:

1. Pair the device in SteamOS, then in Windows (the device keeps the last one).
2. In Windows, in an elevated PowerShell: `windows\Export-BluetoothKeys.ps1`. Windows keeps the keys in a registry
   branch only SYSTEM can read; the script exports it through a short-lived SYSTEM task to `s15-bt-keys.reg` on
   `S15BOOT`, the partition both systems read (unencrypted until the import deletes it).
3. In SteamOS: `sudo s15-bt-import` (`--dry-run` first shows what it would change). It writes Windows' keys into
   SteamOS's pairing of each device (BlueZ, `/var/lib/bluetooth/<adapter>/<device>/info`), with bluetoothd stopped
   and a copy of `/var/lib/bluetooth` in `/var/lib/s15-bt-backup/`, and deletes the file. Devices paired only in
   Windows are listed, not added.

Details:
- Classic devices (headsets): the link key is copied as is. LE devices (mice, presenters): Windows' `LTK`,
  `KeyLength`, `EDIV` and `ERand` (8 bytes, little endian) become BlueZ's LE Secure Connections key
  (`[PeripheralLongTermKey]`/`[SlaveLongTermKey]`, as BlueZ stores it) or, for legacy pairing, `[LongTermKey]`.
  Tested 2026-11-05 with an OpenRun Pro 2 headset and a Logi M650 L mouse.
- Logitech devices take a new address with every pairing (the last byte counts up). An LE pairing in SteamOS that
  differs only there, and is not one of Windows' devices, is moved to the new address.
- Bluetooth LE privacy is off (`Privacy = off` in `/etc/bluetooth/main.conf`, set by the setup; SteamOS's image has
  `device`). An LE device paired in Windows reconnects by directed advertising to the laptop's real address, as
  Windows uses it; with SteamOS's rotating private address the controller ignored it and the mouse never
  reconnected. The laptop is then as visible to other Bluetooth devices as it is in Windows.
- Re-pairing a device later in either system starts over: pair in Windows last, export, import.

## Switching between Windows and SteamOS

Both directions only set the firmware's one-time boot entry (UEFI `BootNext`) and restart, so Windows stays the
default and BitLocker is not involved.

- **SteamOS → Windows:** `steamos-s15-dualboot.sh` installs `s15-reboot-to-windows.service` (sets BootNext to
  Windows Boot Manager, then reboots), a polkit rule that lets the desktop user start exactly that service
  without a password, a "Reboot to Windows" desktop icon and a "Reboot to Windows" entry in the Game Mode library.
- **Reboots stay in the same OS:** a plain reboot from SteamOS comes back to SteamOS (systemd-shutdown hook
  `s15-reboot-same-os` sets BootNext to the entry it booted from, unless one was already chosen). Windows
  restarts stay in Windows because it is first in BootOrder. Power-off and cold boots use the firmware default.
- **Windows → SteamOS:** run `windows\Install-RebootShortcut.ps1` once elevated. It creates a scheduled task
  (current user, highest privileges, on demand) that runs `Reboot-ToSteamOS.ps1` (`bcdedit /set {fwbootmgr}
  bootsequence <SteamOS entry>`, then restart), and a desktop shortcut that starts the task, so there is no UAC
  prompt per click.
