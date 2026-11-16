# Power

## Current figures

SteamOS 0.5.7 (build 20261103.6153824), kernel 7.3.0-s15+ with patches `0001`-`0035` ([kernel.md](kernel.md)),
battery 56.5 Wh full (70.0 Wh design). On battery, Wi-Fi connected, nothing on USB, keyboard light off, Desktop Mode
idle on the plain desktop, no Steam client; `s15-powerlog`, 3.5-4.5 min per step, the first 40 s dropped.

| State | Power | Runtime from full | Measured |
|---|---|---|---|
| Screen on, 25 % brightness, 60 Hz | 3.98 W (3.94-4.06 over 6 runs) | 14 h | 2026-11-15 |
| Screen on, 25 %, 120 Hz (the rate on AC) | 4.30 W | 13 h | 2026-11-15 |
| Screen on, 1 % / 5 %, 60 Hz | 3.71 / 3.75 W | 15 h | 2026-11-15 |
| Screen on, windows open, 25 %, 60 Hz | 5.1 W | 11 h | 2026-11-05 |
| Screen off (DPMS), idle | 1.34 W | 42 h | 2026-11-15 |
| Standby (`deep`, CX collapse) | 0.15-0.19 W | 12-16 days | nights 2026-11-08 to 11-14, `/var/log/s15-sleep.log` |
| Hibernated | 0 W (off) | | back in 17.5 s from the power button |

Cross-check with the system power meter (`s15-adsp-power`, 2026-11-16, 2 min per step): plain desktop at 20 %
brightness 4.10 W, a black full-screen window 3.7 W, display off 1.46 W.

From the evening of 2026-11-14 to a reboot on 11-15 the sleep log showed no CX collapse (`cxsd 0%`) and 0.22 W over
the night: a prototype driver of the wake-timer tests (`rtc-qcom-tad`, loaded by hand, not part of the install) was
loaded during those sleeps. Without it CX collapse is back (99 % and 98 % of the first sleeps after the reboot).

Where it goes (2026-11-15 unless noted):

| Part | Cost |
|---|---|
| Screen on at all, 1 % brightness | +2.4 W over screen off: panel electronics, the eDP link (HBR3, 4 lanes) and the display engine reading the frame from memory 60 times a second (1.4-1.6 GB/s requested; the frame is 10-bit and UBWC-compressed). KWin does not repaint at idle (1 frame and 2 vblank events in 20 s). Panel Self Refresh could remove part of it, but the panel does not enter PSR, and Windows does not use it either ([below](#compared-with-windows-same-meter)). |
| Brightness 1 % → 25 % | +0.27 W (1 % → 100 %: about +1 W, 2026-11-01) |
| 120 Hz instead of 60 Hz | +0.35 W at 25 % |
| Keyboard light, level 1, white | +1.9 W with the screen on, +0.8 W with it off (2026-11-05); `s15-kbd-idle` turns it off after 30 s without input on battery ([steamos.md](steamos.md#keyboard-colour)) |
| Screen content (OLED): windows open instead of the plain desktop | about +1 W (2026-11-05) |
| Steam client in the background | no difference in a 3.5 min step, but about 180 CPU wakeups/s and 7 % of one core, and bursts to 7-9 W (CPU at 3.4 GHz, GPU at 1.25 GHz) from a client running since login; it no longer starts with the desktop ([steamos.md](steamos.md#desktop-mode)) |

Wakeups at screen-on idle without Steam (per second): the EC temperature feed 15 (patch `0009` can slow it, no
measurable gain), rcu_sched 11, PowerDevil's `display_recheck` thread 8.5 (libddcutil looking for external
monitors; `POWERDEVIL_NO_DDCUTIL=1` would stop it, and external monitors' brightness control with it), dbus-broker
4, KWin 3. CPU load 0.1-0.2 %, the SoC-wide idle state 71-76 % of the time (34 % with the Steam client).

### Compared with Windows (same meter)

Windows' "Energy Meter" counter `SYS` reads the same ADSP meter as `s15-adsp-power` ([Measuring](#measuring)), so
both systems can be compared directly (2026-11-15/16: on battery, 60 Hz, a black full-screen window, no input,
keyboard light off; black makes the two systems' different brightness scales irrelevant on the OLED):

| State | Linux | Windows |
|---|---|---|
| Black screen, still | 3.7 W | 3.3 W (3.17-3.35) |
| The pointer moving 60 times a second (every frame new) | +0.1 W | +0.1-0.2 W |
| An 8x8 square redrawn about 64 times a second (Windows) | | +0.25 W |
| Display off, awake | 1.46 W | not possible: Windows turns the display off only into Modern Standby |

Windows does not use Panel Self Refresh on this panel (2026-11-16, [below](#what-is-in-place)), which fits the
pointer costing about the same on both systems: the ~0.4 W gap at screen-on idle is elsewhere. Older figures without the meter: Windows about 0.5 W screen-off idle and 0.23 W in
Modern Standby ([x1e-sleep](https://github.com/justririll/x1e-sleep) measurements on the same model).

## What is in place

Awake:
- CPU idle works: clocks at the minimum at idle (710 MHz on two clusters, 998 MHz on one), the SoC-wide power domain
  (`domain_ss3` on `power-domain-system`) idle most of the time, fans at 0 RPM. A CPU clock cap changes nothing at
  idle.
- USB runtime PM (`s15-usb-pm`, udev rule `91-s15-usb-pm.rules`): the USB-A controllers suspend after 5 s without
  activity and wake on a plug-in (kernel patch `0021`, the sleep clock kept on as on Windows); the USB-C controllers
  suspend only while their port has no Type-C partner. About -0.1 W with the screen on, -0.06 to -0.3 W off.
- NVMe: APST on, the drive idles in PS4 (4 mW) with L1.2. USB4 and PCIe tunnel power domains are off.
- Wi-Fi power save on; `s15-wifi-powersave` turns it off only for networks that drop the connection with it
  ([known issues](known-issues.md)).
- Keyboard light off after 30 s without input on battery (`s15-kbd-idle`).
- Our services wait for events (input, logind, UPower) rather than polling; the two exceptions, the lid and Wi-Fi
  watchdog timers, run once a minute without journal lines (`LogLevelMax=notice`), so they do not keep btrfs
  committing. The Steam client does not start with the desktop.

Standby is plain suspend-to-RAM, not Modern Standby: nothing runs, nothing radio-related stays on, and only the user
or the battery wakes the machine.

| Piece | What it does |
|---|---|
| Sleep mode `deep` | PSCI SYSTEM_SUSPEND: the firmware puts the SoC into CX collapse (`cxsd`/`ddr` in `/sys/kernel/debug/qcom_stats/` for the whole sleep) |
| Kernel | LPASS macro clocks released in runtime suspend, syscon XO vote, PCIe Gen1 bandwidth vote, SoundWire IRQ sync, SS1 idle state and DRIPS for system sleep only ([kernel.md](kernel.md)); boot parameters `fw_devlink.sync_state=timeout`, `nvme.quirks=…simple_suspend`, `pcie_port_pm=force`; panel 3.3 V not always-on (DT) |
| `qcom_adsp_pwr_lmts`, `aoss_cxsd_only` (modules) | the ADSP's Modern Standby message; CX collapse only, no AOSS deep sleep (AOSD), which reset the machine about every hour |
| ath12k | shuts the Wi-Fi half of the WCN7850 down on suspend and reloads its firmware on resume |
| `s15-sleep-radios` (sleep hook) | Bluetooth off during suspend (`/etc/s15-sleep-keep-bt` keeps it on; it makes no measurable difference) |
| `92-s15-wakeup.rules` | no wakeup from battery/charger reports, Wi-Fi (MHI, its PCIe root port) or the compute DSP |
| `s15-ec-darkwake` (sleep hook) | a wake without a wakeup IRQ (the battery management at every 1 % step on battery, every 3-4 h; about every 60 s on AC) goes back to sleep after 2 s; with the lid open only if no key or button is pressed within 3 s (`s15-input-wait`) and the lid was not opened; at or below 5 % battery it powers off, or hibernates with [hibernate after hours](#hibernate-after-hours); a failed suspend is not retried |
| `s15-lid-watchdog` (timer) | awake with the lid closed and no external display for two minutes: suspend, whatever an application requested (`/run/s15-keepawake` disables it) |
| `s15-lid-wake` (sleep hook) | no lid wakeup when suspended with the lid open (the EC pulses the lid GPIO) |

Still able to wake the machine: lid, keyboard, touchpad, power key, USB devices, the EC, the ADSP (battery
management) and the thermal sensors. Not the RTC ([below](#no-wake-timer)): no timed wakes. `deep` resumes the whole
system on any interrupt that wakes the SoC, also one from a source without wakeup flag (the ADSP's glink messages):
that is what a dark wake is.

## Hibernation

Optional, off by default. `sudo /opt/snaptop-linux/steamos/hibernate.sh enable` (`status`, `disable`, `after
SECONDS`):
- a 16 GiB swap file in its own subvolume of the partition's top level, `.s15-swap` (outside the OS versions that
  updates swap; NOCOW, so not inheriting the top level's `compression=zstd`), switched on at boot by
  `s15-hibernate-swap.service` with a priority below zram;
- `resume=<root device> resume_offset=<page>` in every boot entry of this install (`s15-os-update` copies them into
  the entries it writes), a new initramfs and a TPM re-seal;
- Valve's `hibernate-prepare.service` masked: its swap helper finds the file offset with `filefrag`, which is wrong on
  btrfs, so the kernel would write the image over other data;
- `HIBERNATE_AFTER=18000` (5 h) in `/etc/s15-hibernate.conf` ([below](#hibernate-after-hours)).

What works (kernel patches `0016`-`0020`, `0022`-`0024`, `0026`-`0040`): with a real power-off the session is back
17.5 s after pressing the power button, as fast as a cold boot but with all apps open. GPU, EC, Wi-Fi, Bluetooth,
keyboard, touchpad, battery, all USB controllers, both DSPs, audio and both cameras work after the restore, also for
several hibernations in a row in one session. Standby after a restore did not until `0040`: the kernel that loaded
the image left its RPMh votes in force until the next reboot (DDR at 3686 MHz, no CX collapse, 350 mW in standby),
and the power key's interrupt setup was lost (no wake by the power button, a key or the lid). `0036`-`0039` send the
restored kernel's votes again, `0040` sets the PMIC interrupts up again (tested 2026-11-16, [kernel.md](kernel.md)).

Around a hibernation (sleep hook `s15-hibernate`, initcpio hook `s15-hibernate`):
- the image size limit is set to the memory in use, so the page cache is dropped instead of saved (about 4.5 GB);
- the location systemd-sleep configured is checked against `/etc/s15-hibernate.conf`; on a mismatch the swap file is
  switched off and the hibernation fails instead of writing elsewhere;
- BootNext is set to the running entry and systemd-boot's one-shot entry to the running kernel: the firmware would
  start Windows first, and BootNext survives a full power-off;
- the CDSP and ADSP are stopped (CDSP first: the other DSP's state notifications to it time out after 5 s each).
  Their driver has no hibernation callbacks, and the boot that restores the image starts its own ADSP in the
  initramfs; `s15-hibernate-initrd` stops it again right before the hand-over (after loading msm, which quiesces the
  firmware's live scanout; without that the restore crashed), and the restored system starts it. Stopping the ADSP
  removes the sound card, which waits until PipeWire closed it, so user sessions are not frozen during the hooks
  (`SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false` on `systemd-hibernate.service`; otherwise the stop waits forever and
  the kernel aborts the hibernation after systemd's 90 s hook timeout);
- Bluetooth is unbound from its driver before and bound again after the resume: the controller loses power and
  firmware, the driver has no restore, and unbinding it only after the resume hung in `hci_unregister_dev()`;
- `s15-ec-darkwake` and `s15-sleep-radios` treat a resume from hibernation as a real wake.

The kernel that loads the image has to set up the USB PHYs itself: the eUSB2 PHY and PTN3222 repeater drivers are
in `drivers/phy/`, not `drivers/phy/qualcomm/`, so the initcpio hook `s15` adds them by name. Without them that
kernel's `clk_disable_unused` gated the QMP PHY clocks, and every SuperSpeed xHCI restore spun for 21 s with
interrupts off, starving RPMh, I2C and Wi-Fi (freezes, hard lockups). Releasing the PHYs before the snapshot instead
(driver patches, or unbinding the USB controllers) made the machine reset silently in the late/noirq freeze phase.

Test aids: `echo platform > /sys/power/pm_test` runs a hibernation up to the late/noirq phase without writing an
image (`devices` stops before it); `/run/s15-hibernate-entry` sets the one-shot entry for the resume (e.g. one
without `quiet`); `s15.hibernate_report=1` on that entry makes the boot kernel write its log to
`S15BOOT/s15-hibernate-resume.log` before loading the image. `clk_ignore_unused` on the resume entry crashes the
restore.

### Hibernate after hours

As Windows does on this laptop: `s15-ec-darkwake` hibernates instead of suspending again at a dark wake on battery
once the standby has lasted `HIBERNATE_AFTER` seconds (`hibernate.sh after SECONDS`, 0 = off), and at low battery.
The standby starts at the first suspend after a real wake (`/run/s15-standby.since`); a wake with a wakeup IRQ, a
key press or the opened lid after a dark wake, and a resume from hibernation end it.

Without a wake timer the check runs at the next dark wake. On battery those come at every 1 % step of the gauge,
10 500-13 800 s apart in standby, so a 5 h setting hibernates after 5-9 h (night of 2026-11-14/15: after 6.5 h). On
AC there is no hibernation; unplugging the charger wakes the machine, and the next dark wake on battery counts.

### No wake timer

- The PMIC RTC alarm (PMK8550 `0x6200`) belongs to the ADSP: the SPMI arbiter gives it the write and interrupt
  permission, so `rtc-pm8xxx` runs with `qcom,no-alarm` (upstream commit 015b70bd6c75); without the property the
  alarm interrupt fails with `-EPERM`.
- Windows uses the ACPI Time and Alarm Device `\_SB.PRTC` instead, which ASUS's PMIC Apps driver passes to the ADSP
  over pmic_glink (owner 0x8010, opcodes 0x60-0x65 for `_GWS`/`_CWS`/`_STP`/`_STV`/`_TIP`/`_TIV`); its own RTC
  alarm support is off (`RtcAlarm\RtcAlarmSupport = 0`).
- Linux can send the same requests (prototype driver `rtc-qcom-tad`, not part of the build) and the ADSP accepts them,
  but ASUS's ADSP firmware (ADSP.HT.5.9-00806, January 2025) does not wake Linux when the timer expires (tested
  2026-11-15). Qualcomm added an "alarm expired" glink message to the ADSP firmware only in 2026, for their reference
  boards (`rtc-qcom-glink` under review); retail laptops need vendor-signed firmware. If an `rtc*/wakealarm` ever
  works, `s15-ec-darkwake` already sets it to the end of the standby period at every suspend.
- No alternative: the EC protocol has no timer command, the RPMh/PDC wake timer is not used on X1E, and PSCI
  SYSTEM_SUSPEND leaves the system sleep to the firmware.

## Battery charge limit

Plasma's power settings ("Charge limit") write `charge_control_start_threshold` and `charge_control_end_threshold`
of `qcom-battmgr-bat`; the driver accepts a start of 50-95 % and a stop of 55-100 %, and the start has to be at
least 1 % below the stop. Plasma lets both be equal (e.g. 80/80), but the firmware rejects a gap of 0 and the driver
still reports success, so the start silently stays at its old value; 79/80 works. The ADSP firmware forgets a limit
set from Linux at every boot (`qcom_battmgr` reads a persistent one only from PMIC nvmem cells this laptop's DT does
not have), so `s15-charge-limit.service` keeps it: a udev rule starts it when the battery appears (about 20 s into
the boot) and it sets the saved limit; at shutdown it saves the current one to `/var/lib/s15-charge-limit`. A stop
threshold of 100 % removes the saved limit; a limit changed shortly before a hard reset is lost.

With the limit reached on AC the battery reports "Not charging"; Plasma's battery applet would then move into the
tray's hidden items, so the desktop setup sets it to "Always shown" ([steamos.md](steamos.md#desktop-mode)).

## Measuring

Tools in `power/`, installed by `steamos-s15-setup.sh` (run as root):

| Tool | Purpose |
|---|---|
| `s15-adsp-power.py` → `/usr/local/bin/s15-adsp-power` | The system power meter: the ADSP's power-limits firmware writes the system's power once per second (and every 100 ms) into firmware-reserved memory at `0x81F30000`, where Windows' Energy Meter reads it too. Read-only through `/dev/mem` (the range is `reserved` in `/proc/iomem`). `s15-adsp-power` prints it every second, `--duration 120 -q` only the average over 120 s, `--all` the other channels (USB-C in/out; CPU and GPU read 0 or close to it under Linux). |
| `s15-powerlog.py` → `/usr/local/bin/s15-powerlog` | CSV every N s: battery power, energy, brightness, screen DPMS, CPU load and clocks, GPU clock, share of time the SoC-wide power domain spent idle, Wi-Fi state, USB device count, and the meter's average over the interval (`sys_w`). Run detached: `systemd-run --unit=s15-powerlog --collect -p Nice=10 /usr/local/bin/s15-powerlog --interval 5 --duration 14400` |
| `s15-powerreport.py` → `/usr/local/bin/s15-powerreport` | Averages per (screen, brightness, USB devices) segment of a CSV, with the runtime that would give on a full battery (from the meter when the CSV has it). |
| `s15-sleep-hook` → `/usr/lib/systemd/system-sleep/` | Logs battery energy before/after every suspend to `/var/log/s15-sleep.log`, with average drain, CX collapse/AOSD/DDR residency (`qcom_stats`) during the sleep and the wake IRQ. |

- Measure on battery: `qcom-battmgr-ac/online` stays 0 when charging over USB-C PD, so check that the battery
  `status` is Discharging. Nothing on USB (a USB Ethernet adapter alone draws a measurable amount), Wi-Fi connected.
- Drop the first 30-45 s after each change; with the meter 2 min per step is enough at idle, with the gauge 4-5 min.
- The meter (`sys_w`, `s15-adsp-power`) measures where the charger feeds the system: on battery it agrees with the
  gauge's energy within ~5 %, while charging it includes the charging path (7-29 W), so it is only usable on
  battery. The gauge's `power_now` is smoothed and lags by tens of seconds; `energy_now` moves in 10 mWh steps,
  model-based and sometimes corrected after a long rest. The figures above before 2026-11-16 come from the gauge.
  For standby compare only sleeps of hours at similar charge levels (the meter does not run in standby); short
  sleeps and the first sleep after charging show nonsense (negative or several watts).
- Keep the session awake and unlocked through a test (`kde-inhibit --power --screenSaver <command>`): Plasma locks
  the screen 5 min after the last input once an inhibit ends, and a locked screen is a different state (the lock
  screen redraws on input). KDE still dims the backlight under the inhibit; brightness changes themselves cost nothing.

## Milestones

| Date | Change | Screen-off idle | Standby |
|---|---|---|---|
| 2026-11-01 morning | first install (kernel 7.3 with the SoC-wide idle state and PDC wakeups) | 2.77 W | 1.78 W, no CX collapse |
| 2026-11-01 | `fw_devlink.sync_state=timeout`, panel rail, NVMe and PCIe port PM, LPASS/XO/PCIe votes, `deep` with CX collapse only | 1.50 W | 0.15-0.21 W |
| 2026-11-05 | SteamOS 0.5.7, keyboard light off on idle | 1.37-1.43 W | |
| 2026-11-14 | USB runtime PM with plug-in wakeup (`0021`) | 1.40 W (1.46 W without) | 0.15-0.19 W |
| 2026-11-14/15 | hibernation, hibernate after 5 h | | CX collapse again after a test driver was gone (see the top) |
| 2026-11-15 | measured again (screen on 25 %: 3.98 W) | 1.34 W | |

## Tried, parked or not adopted

- AOSS deep sleep (AOSD, XO shutdown): the SoC reaches it, but the next long sleep ended in a hard reset and the
  firmware started Windows; x1e-sleep saw the same hourly resets (0.25 W in AOSD against 0.17 W CX-only there).
  `aoss_cxsd_only` stays.
- PCIe ASPM `powersupersave`: no change.
- EC SoC-Tj report every 2 s instead of 125 ms (`qcom_hamoa_ec.tj_period_ms`, patch `0009`): I2C interrupts 14/s →
  1/s, power unchanged.
- HDMI hot-plug through gpio126 (`hpd-gpios`) lets the HDMI DP controller and MDSS runtime-suspend, but screen-off
  idle stayed at ~1.53 W; not adopted (HDMI hot-plug would be untested).
- Panel Self Refresh (`msm.psr_enabled=1`): the screen goes black, and PSR is parked for good. The panel (Samsung
  ATNA56AC03) offers PSR1 only, needs link training on PSR exit (DPCD `0x071` = `0x3a`), and has no Panel Replay or
  ALPM. The eDP controller is newer (v1.4.1, `0x10040001`) than the sc7280 controller msm's PSR code was written for.
  - Source side: `PSR_CONFIG` (link + 0x100) and `PSR_CMD` (link + 0x110) hold garbage at reset (`0x67438600`) that
    msm's single-bit updates keep. The PSR VSC SDP header (HB2/HB3) is at link + 0x150, not in the colorimetry/stereo
    VSC slot at link + 0x170/0x174, and its reset value `0x5dce0802` has a header and a parity byte swapped (the
    layout is header, parity, header, parity: `0x5d08ce02` for revision 2 with 8 bytes). With exact values the
    source side works: PSR entry raises its update and capture interrupts and turns the link off, PSR exit raises its
    exit interrupt and the picture comes back.
  - The panel never enters PSR: its PSR status (`0x2008`) and "last received PSR SDP" (`0x200A`) stay 0 with no error
    (`0x2006`/`0x2007`), and the screen is black while the link is off. That holds for sink settings `0x170` = 1, 3,
    9 and `0x0B`, at 60 and 120 Hz, with a PSR SDP built by hand in the generic packet slot (GENERIC0), and with
    Windows' own sequence (2026-11-16, from ASUS's Windows display driver `qcdxkm8380.sys`):
    - configure: DPCD `0x170` = 0, `PSR_CMD` = 0, `PSR_CONFIG` = (old & ~0x1f) | 1, link + 0x114 = exit training
      (pattern code 1, 2.5 ms in 19.2 MHz ticks), link + 0x48 |= `0x1000`, `SDP_CFG2` |= `0x07000000`,
      `CONFIGURATION_CTRL` |= `SEND_VSC`, then DPCD `0x170` = 1;
    - enter: acknowledge the PSR interrupts, `PSR_CMD` = 1, poll for the update interrupt;
    - exit: a training pattern 1 burst through `STATE_CTRL`, `PSR_CMD` = 2, poll for the exit interrupt.

    During PSR the panel reads DPCD `0x102` (TRAINING_PATTERN_SET) = `0x23`, written by the controller on entry
    whether exit training is set or not.
  - Windows does not use PSR on this laptop either. Its driver configures PSR after every mode change (the steps
    above), but the idle path that would enter it is gated by a per-display flag that nothing in the driver sets.
    Only a test command enters it. The deepest level would turn the main link, the link clocks and the eDP PHY off.
    ASUS's panel config (ACPI, "Panel_Generic_Amoled") has no PSR settings. This comes from static analysis
    (medium confidence), and matches the measurements: the pointer costs about the same on both systems
    ([Compared with Windows](#compared-with-windows-same-meter)).
- Display engine clock at 325 MHz instead of 575 MHz (the wide plane split across both mixers; the multimedia rail one
  level lower, no underruns in 40 min at 60 and 120 Hz): +0.01 / -0.04 W, within the noise. With the link at HBR2
  as well (the rail two levels lower) about -0.05 W, but HBR2 x4 carries 17.19 Gbit/s against the 17.13 the 10-bit
  stream needs, and the panel offers nothing between HBR2 and HBR3; not adopted (kernel branch `s15-display-idle`).
- Still powered without a user: `gcc_ufs_phy_gdsc`/`gcc_ufs_mem_phy_gdsc` (no UFS on this laptop) and
  `gcc_usb30_tert_gdsc`, kept on by `pd_ignore_unused`.
- Windows uses the deepest platform state (DRIPS) only in Modern Standby, never at runtime idle; the equivalent here
  is suspend.
