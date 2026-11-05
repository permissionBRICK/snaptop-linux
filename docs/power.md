# Power: measuring idle draw and sleep drain

Tools in `power/` (install on the laptop as root):

| Tool | Purpose |
|---|---|
| `s15-powerlog.py` → `/usr/local/bin/s15-powerlog` | CSV every N s: battery power, energy, brightness, screen DPMS, CPU load and clocks, GPU clock, share of time the SoC-wide power domain spent idle, Wi-Fi state, USB device count. Run detached: `systemd-run --unit=s15-powerlog --collect -p Nice=10 /usr/local/bin/s15-powerlog --interval 5 --duration 14400` |
| `s15-powerreport.py` | Averages per (screen, brightness, USB devices) segment of a CSV, with the runtime that would give on a full battery. |
| `s15-sleep-hook` → `/usr/lib/systemd/system-sleep/` | Logs battery energy before/after every suspend to `/var/log/s15-sleep.log`, with average drain in mW, SoC idle entries during the sleep and the wake IRQ. |

Notes:
- `qcom-battmgr-ac/online` stays 0 when charging over USB-C PD; use the battery `status` (Discharging) to tell
  battery operation apart.
- Measure on battery with nothing on USB (a USB Ethernet adapter alone draws a measurable amount) and with
  Wi-Fi connected, as in normal use.
- The SoC-wide idle state (`domain_ss3` on `power-domain-system`, PSCI 0x0200c354) and GPIO wakeups through the
  PDC are in mainline 7.3. Check `/sys/kernel/debug/pm_genpd/power-domain-system/idle_states`. For reference:
  in February 2026, upstream developers measured about 2.5 W screen-off idle on Linux without those patches,
  against about 0.5 W on Windows.

## Results (2026-11-01, kernel 7.3.0-s15+, SteamOS Desktop Mode idle, on battery, Wi-Fi connected, no USB devices)

Measured with `s15-powerlog` (5 s samples, 4 min per step, first 30 s of each step dropped). Battery 56.4 Wh.

| State | Power | Runtime on a full battery |
|---|---|---|
| 100% brightness, 120 Hz | 6.9 W | 8.1 h |
| 35%, 120 Hz | 6.4 W | 8.9 h |
| 10%, 120 Hz | 6.0 W | 9.3 h |
| 1%, 120 Hz | 5.9 W | 9.5 h |
| 35%, 60 Hz | 5.7 W | 9.9 h |
| screen off (DPMS) | 4.05 W | 13.9 h |

CPU load 0.1 %, clocks at the minimum (710 MHz on two clusters, 998 MHz on one), GPU at 300 MHz, the SoC-wide
power domain idle about 82 % of the time, fans at 0 RPM, Wi-Fi power save on. So the CPU side works; the
~4 W floor with the screen off comes from outside the cores. Panel brightness costs about 1 W from 1 % to 100 %,
and 120 Hz about 0.7 W more than 60 Hz.

Screen-off idle A/B (2026-11-01, 75-150 s per step):

| Change | Power |
|---|---|
| keyboard backlight level 1 → off | 4.08 → 3.25 W (**-0.8 W**) |
| PCIe ASPM `default` → `powersupersave` | no change |
| USB runtime PM on all four dwc3 controllers *and* their `xhci-hcd.N.auto` children | 3.42 → 3.10 W (-0.3 W); no shutdown here, unlike the upstream report. **Not used while awake any more:** a runtime-suspended controller does not wake when a device is plugged in, so hot-plugging did not work. Now only around a suspend (`s15-usb-sleep`); getting the plug-in wakeup to work would bring the 0.3 W back. |

Checked and fine: NVMe APST is on and the drive idles in PS4 (4 mW) with L1.2; USB4 and PCIe tunnel power
domains are off; fans stop at idle. Still powered without a user: `gcc_ufs_phy_gdsc`/`gcc_ufs_mem_phy_gdsc` (no
UFS on this laptop) and `gcc_usb30_tert_gdsc`, kept on by `pd_ignore_unused`.

Open leads for the floor:
- USB runtime PM while awake (-0.3 W screen-off, see the table) needs a working wakeup on plug-in first; the dwc3
  controllers report `wakeup=enabled`, the xHCI hosts `disabled`, and no plug event reaches a suspended controller.
- Wi-Fi and NVMe have runtime PM off (NVMe relies on APST, `default_ps_max_latency_us` = 100000); check which
  APST state the drive reaches.
- Keyboard backlight was at level 1 during the test.
- Windows reaches about 0.5 W screen-off idle on this platform.

## Screen-on idle on SteamOS 0.5.7 (2026-11-05)

In use (Desktop Mode, Steam client, Firefox, Obsidian open; 25 % brightness, 60 Hz, keyboard light at level 1,
Wi-Fi power save on) the battery reported 6.3 W, and Plasma estimated about 9 hours. The CPU side is idle: 0.7 % busy,
nearly all CPU time in the deepest core idle state, clusters entering their idle states, GPU at 300 MHz. Found:

- The keyboard light was on (0.8 W at level 1 in the screen-off A/B above). Windows (ASUS's software) turns it off
  after a few seconds without typing on battery; `s15-kbd-idle` now does the same (30 s, [steamos.md](steamos.md#keyboard-colour)).
- The memory bus vote is about 4.9 GB/s average (`interconnect_summary`, `ebi`), 3.2 GB/s of it from the four USB
  controllers (1 GB/s each on three of them), which hold their votes because runtime PM is off while awake
  (`s15-usb-sleep`, above). The display needs about 1.6 GB/s. A lower vote lets the DDR clock drop.
- The panel supports Panel Self Refresh (DPCD `0x070` = `01`, PSR1, on `drm_dp_aux` of `aea0000`, the eDP
  controller). msm has PSR behind `msm.psr_enabled=1` (off by default, read at module load). Not tried yet; with a
  static image it lets the display controller and the eDP link idle, as Windows does.
- CPU clocks: at idle a cap changes nothing (the cores sleep); under light load it might. Not measured yet.

## Battery charge limit

Plasma's power settings ("Charge limit") write `charge_control_start_threshold` and `charge_control_end_threshold`
of `qcom-battmgr-bat`; the driver accepts a start of 50-95 % and a stop of 55-100 %, and the start has to be at
least 1 % below the stop. Plasma lets both be equal (e.g. 80/80), but the firmware rejects a gap of 0 and the driver
still reports success, so the start silently stays at its old value; 79/80 works. The battery is managed by the
ADSP firmware, which forgets a limit set from Linux at every boot: `qcom_battmgr` only reads a persistent limit from
PMIC nvmem cells (`charge_limit_*`), which this laptop's DT does not have, so after a restart the thresholds read 0
(no limit). `s15-charge-limit.service` keeps it: a udev rule starts it when the battery appears (about 20 s into the
boot, once the ADSP runs) and it sets the saved limit; when it stops at shutdown it saves the current one to
`/var/lib/s15-charge-limit`. A stop threshold of 100 % (no limit) removes the saved limit. A limit changed shortly
before a hard reset is lost (it is saved at shutdown only).

With the limit reached on AC the battery reports "Not charging"; Plasma's battery applet would then move into the
tray's hidden items, so the desktop setup sets it to "Always shown" ([steamos.md](steamos.md#desktop-mode)).

## Standby policy

Standby is meant to be plain suspend-to-RAM, not Modern Standby: nothing runs, nothing radio-related stays on, and
only the user or the battery wakes the machine.

| Piece | What it does |
|---|---|
| ath12k (driver) | shuts the Wi-Fi half of the WCN7850 down on suspend and reloads its firmware on resume |
| `s15-sleep-radios` (sleep hook) | Bluetooth off during suspend (`/etc/s15-sleep-keep-bt` keeps it on) |
| `92-s15-wakeup.rules` | no wakeup from battery/charger reports, Wi-Fi (MHI, its PCIe root port) or the compute DSP |
| `s15-ec-darkwake` (sleep hook) | a wake without a wakeup IRQ (the EC, roughly hourly) goes back to sleep after 2 s; with the lid open only if no key or button is pressed within 3 s (`s15-input-wait`) and the lid was not opened; at or below 5 % battery it powers off instead; a failed suspend is not retried |
| `s15-lid-watchdog` (timer) | awake with the lid closed and no external display for two minutes: suspend, whatever an application requested (`/run/s15-keepawake` disables it) |
| `s15-lid-wake` (sleep hook) | no lid wakeup when suspended with the lid open (the EC pulses the lid GPIO) |

Still able to wake the machine: lid, keyboard, touchpad, power key, USB devices, the EC, the ADSP (battery
management) and the thermal sensors. The RTC cannot (the firmware owns its alarm), so there are no timed wakes and
no suspend-then-hibernate. Hibernation is compiled in but has no disk swap to write to (only zram) and is untested
on this platform.

## Standby: CX collapse (2026-11-01)

The SoC counters in `/sys/kernel/debug/qcom_stats/` (`cxsd` = CX collapse, `aosd` = AOSS deep sleep, `ddr`,
`apss`) were 0 at idle and in standby: the main rail never collapsed, standby drew 1.5-1.8 W. The fixes, mostly
from [justririll/x1e-sleep](https://github.com/justririll/x1e-sleep) (made for this laptop), in the order applied:

| Step | Standby (≈5 min samples) |
|---|---|
| start (EC standby message only) | 1.78 W |
| `fw_devlink.sync_state=timeout`, no `*_ignore_unused` | 1.57 W |
| panel 3.3 V not always-on (DT), `nvme.quirks=...simple_suspend`, `pcie_port_pm=force`, lid-wake hook | 0.88 W (s2idle) |
| kernel: LPASS macro clocks released in runtime suspend (rx/tx from x1e-sleep, wsa/va ours), syscon XO vote, PCIe Gen1 bandwidth vote, SoundWire IRQ sync, SS1 idle state + DRIPS system-sleep-only; modules `qcom_adsp_pwr_lmts` (ADSP Modern Standby message) and `aoss_cxsd_only` | 0.67 W (s2idle, `apss` 0) |
| same, sleep mode `deep` | `cxsd`/`ddr` for 325 of 327 s; drain below the gauge's resolution in 5 min |

x1e-sleep measured about 0.17 W overnight in this CX-collapse-only mode on the same laptop (Windows Modern
Standby there: about 0.23 W). AOSD (XO shutdown) is disabled by `aoss_cxsd_only` because it caused hard resets
about every 61 minutes in their tests.

Long test (2026-11-01, lid closed 2 h 41 min, battery at 23 %, `deep`): **0.15 W** on average (0.14 W for the
first 65 min, 0.16 W for the remaining 96 min; the gauge resolves 10 mWh). That is about 6.5 % of the 56.4 Wh
battery per day, roughly two weeks from full. One dark wake after 65 min (no wake IRQ recorded); `s15-ec-darkwake`
put the machine back to sleep after 4 s. `cxsd`/`ddr` residency covered the whole sleep.

Second long test (2026-11-01/02 night, battery 87 %, `sync_state()` forced right before suspend instead of at boot,
systemd-boot, Bluetooth off during sleep, wakeup disabled for Wi-Fi/MHI, its PCIe root port and the CDSP): **0.21 W**
for 80 min and **0.20 W** for 87 min, `cxsd`/`ddr` for the whole sleep. About 50 mW more than the first test,
cause not known yet (the DTB the kernel gets is identical with systemd-boot and GRUB). A/B night with Bluetooth left
on during sleep (battery 84 %): 0.21 W for 100 min, 0.20 W for 15 min, so Bluetooth makes no difference; it stays
off during sleep. Next A/B: the wakeup changes (MHI, PCIe root port, CDSP), and runs at a similar charge level.
AOSD (XO shutdown) test (2026-11-02, `aoss_cxsd_only` unloaded): the SoC does reach it (`cxsd`/`aosd`/`ddr` 78 % of
a 15 s sleep, i.e. the whole sleep after the entry delay), but the next long sleep ended in a hard reset; the laptop
was found off and the firmware had started Windows. Same as x1e-sleep's hourly AOSD resets (they measured 0.25 W in
AOSD, 0.17 W CXSD-only), so `aoss_cxsd_only` stays. The drain in AOSD could not be measured.
Caveat: these figures come from the battery gauge (`energy_now` in 10 mWh steps, model-based, possibly corrected after
a long rest), not from a power meter; compare only long runs at similar charge levels. A false "input activity" after the hourly EC
wake kept the laptop awake for 14 min in this test (fixed: the input baseline is now taken 2 s after the wake).

## Idle on the new kernel (2026-11-01, keyboard backlight off, Wi-Fi on)

| State | Morning (old setup) | New kernel + boot parameters |
|---|---|---|
| screen on, 35 %, 120 Hz | 6.36 W | 4.54 W |
| screen on, 10 %, 60 Hz | ~5.7 W | 3.84 W |
| screen off | 2.77 W | 1.50 W |
| screen off, Bluetooth off | 2.72 W | 1.49 W |
| screen off, Wi-Fi + Bluetooth off | 2.47 W | 1.31 W |

These were measured with Wi-Fi power save on. It is off now (some access points dropped the connection with power
save on, see [known issues](known-issues.md)); its cost at screen-on idle is still to be measured.

Tried without a measurable effect on screen-off idle:
- EC SoC-Tj report every 2 s instead of 125 ms (`qcom_hamoa_ec.tj_period_ms`, patch 0009): the EC accepts it, I2C
  interrupts drop from 14/s to 1/s, power unchanged (1.52 W both).
- HDMI hot-plug via GPIO: the HDMI DP controller (DP2, `ae9a000`) uses its internal HPD block, so msm keeps it
  runtime-active and the display subsystem (`mdss_gdsc`, `mmcx`) never powers down. Muxing gpio126 as a GPIO and
  adding `hpd-gpios = <&tlmm 126 GPIO_ACTIVE_HIGH>` to the hdmi-connector lets DP2 and MDSS suspend, but
  screen-off idle stayed at ~1.53 W. Not adopted (HDMI hot-plug would be untested).

Windows uses the deepest platform state (DRIPS) only in Modern Standby, never at runtime idle (x1e-sleep WPR
trace); the equivalent here is suspend, which now reaches CX collapse.

