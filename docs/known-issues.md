# Known issues and open work

## Open

- **Face unlock (Biopass) is not yet tested on the laptop** ([login](login.md#face-unlock)). Open: recognition quality
  on the 560x360 IR frames (and with glasses), how long a scan takes, whether phone screens and prints are rejected,
  the RGB path through libcamera 0.8.0 (Biopass's bundled version; the system has 0.7.1). Known limits: the camera
  does not work after a resume from hibernation (CAMSS, below), so face unlock is unavailable then and the password
  or PIN is asked; after a password unlock of the lock screen, Biopass may keep the camera (and its light) on for up
  to a few seconds until its scan ends; the IR illuminator is not synchronised with the frames (half of them dark or
  banded; Biopass skips them, an exposure/strobe tuning in the driver could make scans faster).

- **Secure Boot.** It has to be off: systemd-boot, kernel and modules are unsigned. The firmware `db` on our machine holds the Windows
  CAs ("Microsoft Windows Production PCA 2011", possibly also "Windows UEFI CA 2023"), but not the Microsoft
  third-party UEFI CA that shim is signed with, so stock shim does not boot either. Two options:
  1. Enroll our own key in `db` via the BIOS key management (if it offers "append"), and boot a signed unified
     kernel image (systemd-stub with `.linux`, `.initrd` and `.dtb` sections)
     plus signed modules (`CONFIG_MODULE_SIG`, `sign-file`).
  2. Add the Microsoft 3rd-party UEFI CA to `db`, then shim + MOK with our key.

  Either way the `db` change alters the PCR 7 measurement, so **suspend BitLocker in Windows first** (or have the
  recovery key ready).
- **Wrong resolution offered in Game Mode.** Steam treats the eDP panel as external and offers "Native" =
  1920x1080 to games; to be verified with the native-mode gamescope arguments.
- **QUP serial engines broken by the forced `sync_state` (fixed by moving it):** with `fw_devlink.sync_state=timeout`,
  about 1 boot in 5 went wrong at the moment of the forced `sync_state()` (~31-34 s): I2C bus 7 (EC and keyboard)
  `geni_i2c ... Timeout cancel_m_cmd`, the EC Tj feed `-110`, the Bluetooth UART timing out, once also a GPU
  hang in kwin. The session hung on the blue splash screen, the EC ran the fan at full speed and cut the power after
  about a minute (no Tj feed); the firmware then started Windows. The boot parameter is gone; `s15-sync-state`
  forces `sync_state()` right before the first suspend instead. Root cause (which provider's cut-off breaks the QUP
  engines, whose votes are declared in the DT) still unknown.
- **Display takeover:** in about 1 boot in 10 the first frame after the display driver (msm) takes over from the
  firmware fails on the eDP path: `hw recovery is not complete for ctl:1`, `[dpu error]enc42 intf5 ctl 1 reset
  failure: -22`, frame done and vblank timeouts (seen on 2026-11-01 with the driver loaded at 15-18 s, and on
  2026-11-03). Every later frame fails too, each failure takes a display state snapshot, and the console waits a
  second per frame; the screen keeps its last image (plain blue). When the desktop starts, its mode set repairs it
  within seconds, which is why it went unnoticed. With the driver in the initramfs (2026-11-03) the console setup's
  font redraws blocked the boot instead: a blue screen for over two minutes, Ctrl+Alt+F2 dead (twice). Now the
  driver is only loaded in the initramfs for a passphrase prompt, SteamOS's console setup is masked, and
  `s15-display-check` blanks and unblanks the console once when the first frame failed
  ([steamos.md](steamos.md#initramfs)). The snapshots are kept in `/var/log/s15-devcoredump/` for finding the
  cause. Counted over 46 logged boots: the takeover failed in 3 of 9 boots where it happened in the initramfs (about
  3.5 s after power-on handover, firmware image still on screen) and in 3 of 37 where it happened in SteamOS
  (15-21 s). The one test of the prompt path after the change also ended on a blue screen (its log was lost): the
  blank/unblank repair did not help, and typing the passphrase blind did not work either (the password agent only
  started after `s15-display-check`, which hung with the display). Now the prompt starts without waiting for the
  display, nothing blanks the console or reloads its font in the initramfs (both hold the console lock through the
  failing frames), and the Caps Lock light blinks while the passphrase is requested. Cause still to be found with
  the saved snapshots. Whether a charger on a USB-C hub plays a part is open (the
  hung boots had one; boots with the hub but no charger were fine).
  Possibly gone with kernel patch `0015` ([kernel.md](kernel.md), 2026-11-14): until then the display engine lost its
  memory clock in the middle of the firmware's scanout, about 20 s before `msm` took it over. To be confirmed by
  `s15-display-check` finding no failed first frame over many boots.
- **Boot time:** about 14 s from a restart to the login screen (2026-11-14, kernel #7 with `0015`): firmware ~7 s,
  systemd-boot 0.8 s, kernel 0.4 s, initramfs 2.0 s (TPM unlock included), userspace 3.9 s
  ([steamos.md](steamos.md#initramfs)). It had crept back to ~30 s after `msm` left the initramfs: the machine ran
  throttled until `msm` reset the display engine, which then happened ~20 s into the boot instead of ~3.5 s
  ([kernel.md](kernel.md), patch `0015`). Before: 23 s with the busybox initramfs, ~30 s with GRUB.
- **Volume keys in Game Mode:** they work in Desktop Mode; in Game Mode the volume overlay appears only
  sometimes and the volume does not change. Under investigation (key events vs. the sink Steam controls).
- **Wi-Fi power save and some access points:** with power save on, two access points (UniFi-type, 2.4 GHz)
  disassociated the laptop with `DISASSOC_LOW_ACK` about 30 s after every connect; with power save off the link
  stayed up. Power save stays on by default (it saves power while awake); `s15-wifi-powersave` turns it off per
  network (`/etc/s15-wifi-nopowersave`) and adds a network there by itself after two such drops within 15 min.
  With the iwd backend, NetworkManager's `wifi.powersave` is not applied, and iwd's `PowerSaveDisable` quirk did
  not hold either (power save was on again after a reboot).
- **Wi-Fi firmware can get stuck:** dmesg fills with `ath12k ... received scan start failure event`, and
  connects fail with reason 15 (handshake timeout) because the firmware never sends the EAPOL replies
  (`Control port TX status (ack=0)`), although the password is right. `s15-wifi-reset` (reload `ath12k_wifi7`)
  recovers it; `s15-wifi-watchdog` does that automatically when a connect hangs or the scan list stays empty.
- **GPU fault** in No Man's Sky after a while (Turnip; try `TU_DEBUG=sysmem`, newer Mesa).
- **Restart with a USB-C dock crashed the next boot** (2026-11-05, a dock with Ethernet, either port): only
  SteamOS -> SteamOS restarts; cold starts and restarts into or out of Windows were fine. The next boot's display
  stalled ("ctl 1 reset failure", "vblank wait timed out"), a CPU hung in the IOMMU (`arm_smmu_iotlb_sync`) while
  xHCI released a transfer, the I2C bus of the EC timed out, and the EC reset the machine because it got no SoC
  temperature (the firmware's crash screen). The firmware does not reset the USB controllers on a warm restart, so
  the dock's network DMA ran on into the new kernel. Workaround: the shutdown hook `s15-next-boot-same-os`
  (`steamos-s15-dualboot.sh`) unbinds the xHCI and DWC3 controllers before every restart, after setting BootNext;
  several restarts with the dock attached went through. (As a separate hook it ran in parallel with the BootNext
  one, and once a restart lost its BootNext and started Windows.)
- **First boot after Windows went down (2026-11-07):** started with the "Reboot to SteamOS" shortcut, it reached
  SteamOS (journal flushed ~7 s after the kernel started) and went down within the next ~30 s with a black screen.
  What happened after the flush was lost with its tree log ([below](#btrfs-tree-log)); before it nothing stands
  out. Cause unknown; watch whether it recurs.
- **Reboot hang:** twice the machine stopped after "Reached target reboot.target" and needed a forced power-off.
  Possibly the EFI `ResetSystem` path through the firmware; `efi=noruntime` is a candidate test (it also
  disables EFI variables, so only as a test).
- **Idle power from boot until the first sleep** (measured 2026-11-16): the clock controllers, RPMh power domains and
  interconnects keep the bootloader's maximum votes until `s15-sync-state` forces `sync_state()` before the first
  suspend (the video codec, the crypto engine and the GPU GMU never bind a driver): DDR at 4224 MHz all the time,
  5.29 W at the login screen. Forcing it at runtime for the interconnects, rpmhpd and the video clock controller only
  (not `gcc`/`gpucc`, which wait for the GMU) gave DDR 547 MHz and 4.52 W, with nothing breaking in that test.
  Candidate fix: do that early in the boot for the providers that wait only for driverless consumers, then check
  over many boots that the QUP serial engines stay intact (see the forced `sync_state` entry above). DDR residency:
  AOP's `ddr_stats` is refreshed only by a QMP `{class: ddr, action: freqsync}`, which the rpmh-stats node is not
  wired to send (no `qcom,qmp`).
- **Power:** standby (0.15 W) and idle are measured ([power](power.md)). Screen-off idle is still about 1.5 W,
  Windows reaches about 0.5 W.
- Headphone jack, DP alt mode, Iris video decode, face login with the IR camera: untested.
- NPU (an experimental llama.cpp path exists, not tried), ambient light sensor: no Linux support yet.

## Btrfs tree log

A crash or forced power-off within about 30 s of an fsync, before btrfs commits, leaves a tree log that the next
mount replays. The SteamOS partition of the first installation was made from Valve's image and has **mixed block
groups** (`btrfs inspect-internal dump-super` lists `MIXED_GROUPS`; nodesize 4096); `install.sh` formats without
them. On such a file system the kernel cannot replay a log that holds two parts of one preallocated extent, and
journald writes exactly that (it preallocates its files and writes into them, so a regular and a prealloc item point
to the same extent). The mount then fails: `Transaction aborted (error -22)`, `WARNING ... tree-log.c ...
process_one_buffer`, `failed to recover log trees`. During the replay the kernel takes the logged data extents out
of the free space cache, on mixed block groups only (`btrfs_exclude_logged_extents`), and the second item of the
same extent finds its range already gone. Reproduced with kernels 6.8 and 7.2 on a small test file system (mixed
block groups, fragmented free space, a preallocated file half written, fsync, crash copy): the replay fails; the same
without preallocation, or on a file system without mixed block groups, replays.

It happened twice: on 2026-11-03 (forced power-off of a hung initramfs test) and on 2026-11-07 (the first boot after
Windows went down, above). Each time every later boot stopped before the root was mounted: a black screen (no display
driver yet on a TPM boot) with an invisible emergency shell. The committed file system was intact both times
(`btrfs check` clean); dropping the log (`btrfs rescue zero-log`) lost only the last seconds of the crashed boot.

Now:

- `notreelog` in `rootflags` on file systems with mixed block groups (`install-esp.sh`; `s15-os-update` keeps the
  flags of the current entry): fsync commits instead of writing a log, so a crash leaves nothing to replay. The
  kernel confirms it at boot: `BTRFS info (device dm-0): disabling tree log`.
- The initramfs hook `s15-btrfs-logcheck` runs before the root is mounted. If the root file system has a tree log, it
  mounts it once to replay it; only when the kernel reports that it cannot recover the log, it drops it (`btrfs
  rescue zero-log`). `journalctl -b -u s15-btrfs-logcheck` shows what it did; without a log it prints nothing.
  Tested on test file system images (replayable log replayed and kept, unreplayable log dropped, then the mount
  works) and on the laptop (no log).
- By hand from a live system ([encryption.md](encryption.md)): look first without writing (`cryptsetup open
  --readonly ...`, `btrfs inspect-internal dump-super` shows `log_root` other than 0, `mount -o ro,rescue=nologreplay`,
  `btrfs check --readonly`), then open it normally and `btrfs rescue zero-log /dev/mapper/<name>`.
- Not done: a kernel fix (the exclusion would have to skip ranges it already took out) and a file system without
  mixed block groups (needs the ~30 GB of data copied somewhere else and back).

## Resolved (for reference)

| Problem | Cause | Fix |
|---|---|---|
| Hard reset in the first long standby after a restore from hibernation (2026-11-17, after 6 minutes; the firmware started SteamOS again through BootNext) | The power-off resets the AOSS; `aoss_cxsd_only` sends its "AOSD off" message only when it loads, so the restored system slept in AOSS deep sleep (AOSD), which resets this laptop (`aosd` equal to `cxsd` in every sleep after a restore) | `s15-hibernate` loads `aoss_cxsd_only` again after a restore ([power](power.md#hibernation)) |
| Hibernation restore: DDR stuck at 3686 MHz, no CX collapse in standby (350 instead of 180 mW), power button, keys and lid no longer waking it from standby | RPMh votes of the kernel that loaded the image stayed in force; the PMIC interrupt setup (arbiter channel enables, PON `EN_SET`/`POLARITY_HIGH`) was lost in the power-off | Kernel patches `0036`-`0040` send the votes and set the PMIC interrupts up again ([kernel](kernel.md)) |
| Left USB-C port (port 0, `a600000.usb`): a USB-C dock did not enumerate (descriptor read `-110`, "Enable Slot" timeout, "Abort failed to stop command ring ... HC died"), hard lockups of several seconds, every suspend failing afterwards; unbinding `dwc3-qcom` for the dead controller hung the machine (seen up to 2026-11-02) | Not found; not an unused power domain (also before the forced `sync_state` and with `pd_ignore_unused`) | Not reproducible since: on 2026-11-05 the same kind of dock ran on port 0 for hours across several boots (Ethernet, hub, card reader), after the kernel and boot changes since (`sync_state` moved, x1e-sleep patches) |
| No sound at all on SteamOS | Frame WirePlumber spatializer needs SteamVR | `node.stream.enable-spatial-audio = false` |
| Speakers silent with our first kernel | `RESET_GPIO`/`GPIO_SHARED_PROXY` dropped by localmodconfig | Full Debian module set ([kernel](kernel.md)) |
| Banding in gradients | msm DP picked 6 bpc | Our 8 bpc patch |
| No Wi-Fi networks listed | `iwd.service` masked, NetworkManager's Wi-Fi backend is iwd | Do not mask iwd |
| UI sounds start loud and fade within ~100 ms | LPASS WSA macro compander (`WSA_COMP1/2`), enabled by the image's `Wsa1SpeakerEnableSeq.conf` | Speaker profile switches it off (measured flat with the built-in mics) |
| 90 s waits during boot ("compressed...") | zram missing in the trimmed kernel | Full Debian module set |
| Desktop Mode bounced back to Game Mode | Frame `plasma.desktop` starts the VR session | `steamos-s15-desktop.sh` |
| Desktop Mode black screen with cursor | Display variables unset inside the Plasma start | `--switch` only from `steamos-session-select` |
| Switching to Game Mode takes about a minute (black screen, text cursor) | Desktop autostart ran `steam -deckard` (branch `linux_arm64_beta_*`), Game Mode `-steamdeck` (`steamdeck_stable`): Steam downloaded the other client build on every switch | Desktop Steam starts with `-steamdeck -steamos3` too (user autostart/menu overrides) |
| Screen flickering on and off every few seconds after plugging in the charger during standby | The USB-C xHCI on the left port had died (left USB-C port, above), so every suspend failed at once with `-EINVAL`, and the dark-wake hook suspended again every few seconds | The dark-wake hook no longer retries a failed suspend and backs off after three wakes in two minutes; the xHCI death itself is open |
| No Wi-Fi/Bluetooth applet or settings in Desktop Mode | The Frame image has no `plasma-nm`/`bluedevil` | `desktop-net/` builds and installs them |
| Services enabled at runtime (e.g. the Wi-Fi watchdog timer) not started after a reboot | Our initramfs lacked Valve's `etc_overlay` hook, so systemd's `etc.mount` mounted the `/etc` overlay only after the unit graph was loaded | initramfs hook `sd-s15-etc-overlay` (earlier `s15_etc_overlay`) mounts it before systemd starts |
| Awake for 7 hours in the bag after an EC dark wake | The dark-wake hook counted touchpad interrupts after the resume as "input" and stayed awake; then Steam blocked Plasma's idle timer | With the lid closed the hook always suspends again; `s15-input-wait` (real key presses) for the lid-open case; `s15-lid-watchdog` |
| Shutdown menu on every wake by the power key | The PMIC power key delivers the waking press after resume; Plasma's power-button action is "show the logout screen" | `s15-power-key`: short press = sleep in Desktop Mode, waking press ignored; Plasma's action set to "do nothing" |
| Wi-Fi not reconnecting after a wake until the applet was opened | iwd's own autoconnect scans fail after resume (`scan start failure`) and back off | `s15-wifi-resume` asks NetworkManager for a scan 5/15/30 s after a wake |
| Black screen with cursor after login to Desktop Mode (sometimes) | `gamescope-cleanup` blanked DISPLAY/WAYLAND_DISPLAY during Plasma start | run it only when switching from Game Mode |
| FlatOut 2 shader error | Wine d3dx9 effects | Native d3dx9_30 |
| FlatOut 2 lag after 10-15 s | Wine dsound mixer under FEX | DSOAL |
| `efibootmgr` failed right after boot | EFI variables register ~30 s into boot | remount efivarfs before use |
| Steam tools slow/broken on the NTFS library | ntfs3 | `steam-move-tools.sh` |
