# Kernel

`kernel/build.sh` builds the kernel natively on ARM64 (the laptop itself, about 30-40 minutes; `install.sh` does
this in the live system) or cross-compiles on x86_64 (about 15 minutes on 8 cores). It writes a payload directory:

```
$WORK/payload/
  kernel-version                                       e.g. 7.3.0-s15+
  vmlinuz-<rel>                                        arm64 Image
  modules-<rel>.cpio.zst                               usr/lib/modules/<rel>/..., stripped
  dtb/x1e80100-asus-vivobook-s15-<rel>.dtb             mainline DT + community overlay
  dtb/x1e80100-asus-vivobook-s15-<rel>-ec.dtb          the same + experimental EC (fan control) overlay
```

```sh
# Debian/Ubuntu: gcc (native) or gcc-aarch64-linux-gnu (x86) plus:
sudo apt-get install git bc flex bison libssl-dev libelf-dev device-tree-compiler cpio zstd
WORK=~/snaptop-build kernel/build.sh
```

Install a new payload in SteamOS: `sudo steamos/install-kernel.sh <payload>` (keeps the previous kernel as the
"previous kernel" boot entry).

## What goes into it

1. **Mainline v7.3** (stable tree tag).
2. **Community S15 series** from [BurninChrome/vivobook-s15-fedora](https://github.com/BurninChrome/vivobook-s15-fedora),
   pinned to commit `c35ad9447dcc0883127de50edab1fb3e54f05334` (`COMMUNITY_REV`). The patches are applied with
   `git am`, so their authorship and Signed-off-by lines are kept:
   - `i2c: qcom-cci` power-on fix (camera bus)
   - our CCI runtime-resume reset and timeout retry fix, for camera reopen and resolution changes
   - Himax HM1092 IR sensor driver, binding, IR illuminator strobe
   - `HID: asus-ec` - EC hotkeys and keyboard backlight
   - `qcom-hamoa-ec` - S15 support: SoC junction temperature feed, fan profiles, RPM query, I2C retries, suspend
     notification (`allow_suspend`)
   - `ps883x` USB-C retimer DP pin F fix
   - reverts of the LPASS macro PM-clock conversion (audio)
3. **Our patches** in `kernel/patches/`, among them 8 bpc on the panel (`0001`, below), the firmware TPM driver
   (`0011`, [tpm](tpm.md)), two boot fixes for the TPM unlock (`0012`, `0013`, below), the SoundWire resume
   fix (`0014`, below), the display memory clock at boot (`0015`, below; halves the boot time), restore fixes for
   hibernation (`0016`-`0020`, `0022`-`0024`, below), the USB wakeup for runtime PM (`0021`, below) and the shared
   camera LED (`0025`, below).
4. **DT overlay** from the same community repo (`overlay/build-overlay.sh --dtbo-only`): audio (WSA8845 speakers,
   SoundWire, mics), RGB and IR cameras, and optionally the EC node; plus our fragments from `kernel/overlay/`
   (camera activity LED). `build.sh` merges it into the mainline DTB
   with `fdtoverlay`, and also sets `rotation = <180>` on the HM1092 node (`camera@24`), which the overlay misses.
5. **Config** `kernel/config-7.3.0-s15`, run through `olddefconfig`.

## Our patch: 8 bpc on the internal panel

Mainline drove the OLED at 18 bpp (6 bpc) although its EDID reports 10 bpc and the link is HBR3 x4. Gradients
showed visible banding. `msm_dp_panel_get_supported_bpp()` is called while the link rate is still 0 during the
modeset, so the bandwidth check fails for every depth and falls through to the minimum. The patch returns 24 bpp
(8 bpc) when the rate is unknown:

```c
if (!data_rate_khz)
        return min(bpp, 24U);
```

Check: `cat /sys/kernel/debug/dri/0/eDP-1/dp_debug` shows `bpp = 24`. A proper upstream fix would compute the
bpp after link training; this patch is the minimal workaround.

## Our patch: SoundWire resume (speakers silent after login)

`0014` (`soundwire: qcom`): the speaker amplifiers (WSA884x) dropped off their SoundWire bus at random right after
login ("SWR bus clsh detected", amplifiers `UNATTACHED`, the speaker PCM running silently) and came back seconds to
many minutes later. The LPASS macros release their clock votes in runtime suspend (`0002`, `0008`, needed for CX
collapse in standby), so the controller's clock is gone while the bus sits in clock stop, and the clock-stop exit on
runtime resume fails at random; a burst of short streams at session start (PipeWire, the Steam client; more of them
since SteamOS 0.5.7) hits it. Fedora's kernel for this laptop reverts the 7.3 macro clock change for the same
symptom; the Omarchy kernel fixes the same failure on Glymur's speaker controllers by re-enumerating. `0014` does the
latter on X1E80100 buses with WSA amplifiers (only `swr0`, `6b10000` here): no clock stop, and runtime resume resets
the controller and re-enumerates the amplifiers, as probe does (a few ms before the first sound after idle).

Not on the WCD938x buses (`swr1`/`swr2`): a first version did it on all four controllers, and the internal
microphones then recorded pure zeros. The bus reset also loses the codec's setup, its driver does not restore it, and
the microphones get their bias from the WCD938x. `soundwire_qcom.reenumerate_on_resume=0` (never) or `=1` (every
bus) overrides the automatic choice for comparison.

Tested 2026-11-05 (module built against the running kernel): click on the first volume key press after login, no
bus clash, microphones recording; the speaker bus re-enumerates both amplifiers on each wake, the microphone bus does
not.

## Our patch: the display's memory clock at boot (boot twice as fast)

`0015` (`clk: qcom: gcc-x1e80100`): the firmware hands over with the display engine still scanning out its boot
framebuffer (the ASUS logo). The kernel's unused-clock pass at about 0.25 s switched `gcc_disp_hf_axi_clk`, the
display's path to memory, off under that scanout, long before the display clock controller and `msm` (modules) load.
From then on the whole machine ran several times slower until `msm` reset the display engine about 20 s into the
boot: the rest of the initramfs unpacking, every module load, the NVMe bring-up, the TPM unlock, userspace. The
screen also went black at that moment. Most likely mechanism: the display engine is a real-time client of the memory
controller and, with its memory path cut, keeps signalling underflow ("danger"), which throttles every other client.

| 2026-11-14, same kernel otherwise | Kernel | Initramfs | Userspace | Boot (`systemd-analyze`) |
|---|---|---|---|---|
| before | 1.0 s | 7.6-9.4 s | 12.6-13.0 s | 29-31 s |
| `clk_ignore_unused` | 0.38 s | (passphrase test) | 3.5 s | - |
| `pd_ignore_unused` | 1.0 s | 8.8 s | 13.6 s | 31.2 s |
| DT simple-framebuffer holding only this clock | 0.38 s | 2.0 s | 3.5 s | 13.7 s |
| `0015` (kernel #7) | 0.38 s | 2.0 s | 3.9 s | 13.9 s |

`0015` marks the clock `CLK_IGNORE_UNUSED`; `msm` takes it over at probe and switches it off in runtime suspend, so
idle and standby are unchanged. The simple-framebuffer node would have worked without a kernel change but hardcodes
the firmware framebuffer (`0xe4800000`, 2880x1615); after a firmware change the console would draw into RAM.

With it, `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y`: the text console takes the EFI framebuffer only when text
is printed, so with `quiet` the firmware's logo stays on screen until `msm` takes over (about 4 s after the kernel
starts).

## Our patches: restore from hibernation (`0016`-`0020`, `0022`-`0024`)

Hibernation powers the SoC off; drivers that only know suspend find their hardware reset after the restore, set up
by the kernel that loaded the image only as far as its own drivers needed it ([power.md](power.md#hibernation)).
Experimental, like hibernation itself; suspend to RAM is unchanged by all of them.

- `0016` + `0022` (`drm/msm/a6xx`): the GPU's CX domain keeps its registers across GPU power collapses, so msm sets
  some things up once (RSC/PDC sequences, zap shader, SCM fuse setup, AOSS ACD state) and tracks other state only in
  software. After the power-off the RSC is awake and the GMU's memory empty, but msm asked the RSC to wake up
  ("Unable to power on the GPU RSC") and then took a warm boot without loading the GMU firmware (GMU context faults,
  init timeouts, hangchecks). On the first GMU resume after a restore it now checks whether a GMU ran since the
  power-on (TCM retention) and if not starts from the cold-boot state; a failed start always forces a cold boot.
- `0017` (`qcom-hamoa-ec`): the EC's SCI events (enabled at probe) were off after the restore and its interrupt kept
  firing with event 0; the restore enables them and restores the fan state.
- `0018` (`serial: qcom-geni`): the port setup (serial engine firmware) ran once per boot; the Bluetooth UART stayed
  dead. The restore marks it undone, so the port is set up again when it is opened.
- `0019` (`pinctrl: qcom`) and `0020` (`irqchip/qcom-pdc`): pin configuration and the PDC's interrupt configuration
  are saved before the snapshot and written back right after the jump (the EC interrupt line had lost its pull-up and
  fired without end).
- `0023` (`ath12k`): when the Wi-Fi firmware did not come back after a restore, unloading the driver later oopsed in
  `hwmon_device_unregister`; the thermal devices are no longer unregistered twice.
- `0024` (`iommu/arm-smmu-qcom`): the Adreno SMMU's PRR setup (sparse mappings) is written again after a reset.

## Our patch: shared camera privacy LED (`0025`)

The camera activity LED (TLMM gpio110, `kernel/overlay/35-camera-privacy-led.dtsi`, see
[steamos.md](steamos.md#cameras-and-browser-access)) serves both the RGB and the IR sensor, as on Windows. The v4l2
core switched a privacy LED off whenever one of its sensors stopped; `0025` keeps it lit until the last one stops.

## Our patch: USB wakeup from runtime suspend (`0021`)

A runtime-suspended dwc3 controller did not notice a device plugged in: no PHY interrupt arrived at all, so the
USB-A ports could not use runtime PM while awake ([power.md](power.md)). Windows keeps the controller's 32 kHz sleep
clock running in D1/D2; `0021` does the same in runtime suspend (`dwc3_qcom.runtime_sleep_clk`, on by default; off
again for system suspend). With it a plug-in into either USB-A port raises `dp_hs_phy_N` and the device enumerates.
It also keeps the xHCI host running 500 ms after a wakeup interrupt (`wake_hold_ms`) and arms the eUSB2 wakeup
lines like the pending upstream series. Further switches from the Windows driver are there for tests and off
(`runtime_pwr_event`, `runtime_alt_irq`, `icc_windows_bw`, all in `/sys/module/dwc3_qcom/parameters/`).

## Our patches: boot fixes for the TPM unlock

The TPM unlocks the encrypted SteamOS partition only for the measured boot path ([encryption](encryption.md)). Two
things in a stock kernel would let someone change the boot without changing a measurement:

- `0012` (EFI stub): the stub measures the initrd it loads into PCR 9, but if the devicetree already names an initrd
  (`linux,initrd-start`/`-end` in `/chosen`), the kernel uses that one. The devicetree on `S15BOOT` is not
  measured, so an initrd added through it would run with the TPM-released key. The stub now deletes both properties
  and logs `Ignoring the initrd named by the devicetree`.
- `0013` (efivarfs): systemd reads the EFI variable `SystemdOptions` as extra kernel command line options when
  Secure Boot is off (it is off on this install). Anyone at the boot menu's shell, or with any OS, can set EFI
  variables, and the variable is not measured. Reading it now fails with `EPERM`, so systemd ignores it.

`s15-luks-reseal` and `steamos/login-lock.sh` look for both (the stub's message in the kernel image, the variable
name in the efivarfs module) and do not seal a kernel without them.

## Config: how it was made and what we learned

The config started from Debian's 7.2 arm64 config. A `localmodconfig` pass (modules seen in `lsmod` on the live
system) produced a small build, but the board is devicetree-driven: many required drivers are only probed when
their DT node matches, so `lsmod` on an incomplete boot misses them. Missing pieces we found the hard way:

| Missing option | Symptom |
|---|---|
| `CLK_X1E80100_CAMCC` | no cameras |
| `RESET_GPIO`, `GPIO_SHARED_PROXY` | silent speakers: the shared WSA shutdown GPIO stayed low, amps stayed UNATTACHED on SoundWire |
| `ARM_SCMI_CPUFREQ` (unset in Debian) | CPUs stay at the firmware clock, no idle downclocking |
| zram | 90 s boot waits on SteamOS |
| loop, vfat | no loop mounts, no EFI partition access |
| nf_tables | firewall/containers fail |

The final config therefore restores **every Debian `=m` option** (`kernel/restore-all-debian-modules.py <debian
config> <tree>`), about 4000 modules, plus the S15 extras. Build time and size grow, but nothing is silently
missing anymore. Lesson: on DT platforms, do not trim with `localmodconfig`.

Other build gotchas:
- Build the DTB with `-j1`: building the base DTB and its `-el2` variant in parallel races.
- The modules cpio must contain directory entries; the kernel's initramfs unpacker drops files whose parent
  directory is missing.

## Boot parameters

```
qcom_hamoa_ec.allow_suspend=1 nvme.quirks=1344:5413:simple_suspend
pcie_port_pm=force pcie_aspm.policy=powersupersave
```

- `allow_suspend=1`: the EC driver sends "modern standby enter/exit" around suspend (pulsing power LED, fans off).
- No `fw_devlink.sync_state=timeout` any more; the `s15-sync-state` sleep hook does its job. The GPU GMU, the video
  codec and the crypto engine never bind a driver, so the clock controllers, RPMh power domains and interconnects
  never reach `sync_state()` and keep everything the bootloader left on at maximum (rails, bus bandwidth, unused
  clocks/domains); then DDR and CX never collapse in standby (measured: 0.9 W instead of 0.15 W). The boot parameter
  forces `sync_state()` ~30 s into boot, but in about 1 of 5 boots that broke the QUP serial engines at the same
  instant (I2C bus 7 with the EC and keyboard: `geni_i2c ... Timeout cancel_m_cmd`, EC Tj feed `-110`; the
  Bluetooth UART timing out); the EC then runs the fan at full speed and cuts the power after about a minute. The
  hook writes 1 to `/sys/bus/platform/devices/*/state_synced` right before the first suspend instead. Check after a
  suspend: `state_synced` all 1, `qcom_stats/cxsd` count rising.
- `nvme.quirks=1344:5413:simple_suspend`: this Micron SSD otherwise stays in D0 with APST in standby and its PCIe
  controller keeps a DDR vote, so DDR and CX never collapse.
- `pcie_port_pm=force`: the root ports claim hot-plug and stay in D0, keeping the link and the DDR vote.
- No `clk_ignore_unused pd_ignore_unused` (the early setup had them for a seamless display handover; not needed,
  and they keep unused clocks/domains on, e.g. the UFS controller this laptop doesn't have).
- Sleep mode stays `deep` (the default). With `s2idle` the system domain entered DRIPS, but AOSS never saw the
  CPU subsystem asleep (`apss` 0), so CX did not collapse.

## The two DTBs

- `...-<rel>.dtb`: everything except the EC node. The EC then keeps its own fan curve.
- `...-<rel>-ec.dtb`: adds the experimental EC overlay. The driver feeds the SoC temperature to the EC and
  controls the fan profile. If the feed stops, the EC hard-resets the machine after a while (watchdog), so this
  is opt-in in the community repo. We use it by default on SteamOS; no resets seen so far.

## Rebuilding after upstream changes

- New community revision: set `COMMUNITY_REV`, delete `$WORK/linux` (or reset it to the tag) and rebuild.
- New kernel tag: set `KTAG`; patches may need rebasing.
- Install on the laptop: `steamos/install-kernel.sh <payload>` in SteamOS (see [steamos](steamos.md)).
