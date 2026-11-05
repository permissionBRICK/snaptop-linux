# Known issues and open work

## Open

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
- **Boot time:** about 14.5 s from a restart to the login screen (23 s with the busybox initramfs, ~30 s with GRUB):
  firmware ~7 s, systemd-boot 0.8 s, kernel and initramfs ~4 s, userspace ~3 s ([steamos.md](steamos.md#initramfs)).
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
  the dock's network DMA ran on into the new kernel. Workaround: the shutdown hook `s15-reboot-usb-quiesce`
  (`steamos-s15-dualboot.sh`) unbinds the xHCI and DWC3 controllers before every restart; several restarts with
  the dock attached since then went through.
- **Reboot hang:** twice the machine stopped after "Reached target reboot.target" and needed a forced power-off.
  Possibly the EFI `ResetSystem` path through the firmware; `efi=noruntime` is a candidate test (it also
  disables EFI variables, so only as a test).
- **Power:** standby (0.15 W) and idle are measured ([power](power.md)). Screen-off idle is still about 1.5 W,
  Windows reaches about 0.5 W.
- Headphone jack, DP alt mode, Iris video decode, face login with the IR camera: untested.
- NPU (an experimental llama.cpp path exists, not tried), ambient light sensor: no Linux support yet.

## Resolved (for reference)

| Problem | Cause | Fix |
|---|---|---|
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
