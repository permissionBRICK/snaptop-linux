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
   (`0011`, [tpm](tpm.md)) and two boot fixes for the TPM unlock (`0012`, `0013`, below).
4. **DT overlay** from the same community repo (`overlay/build-overlay.sh --dtbo-only`): audio (WSA8845 speakers,
   SoundWire, mics), RGB and IR cameras, and optionally the EC node. `build.sh` merges it into the mainline DTB
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
