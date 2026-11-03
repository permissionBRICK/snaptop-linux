# snaptop-linux

SteamOS on the **ASUS Vivobook S 15 (S5507QA, Snapdragon X Elite X1E-78-100)**, next to Windows.

Snapdragon X laptops are often called a dead end for Linux. On this machine, almost everything you use daily works
with a recent mainline kernel, community patches, firmware copied from your own Windows and a few fixes of ours.
Valve's ARM64 SteamOS from the Steam Frame headset then gives a native ARM64 Steam client with Proton 11 (ARM64) +
FEX for Windows games, a Plasma desktop and a Steam Deck-style Game Mode:

- display 2880x1620 @ 120 Hz, 8 bpc; Adreno GPU with Vulkan 1.4 (Turnip); HDMI
- CPU frequency scaling, EC fan control, battery/charging, standby at about 0.15-0.2 W (roughly two weeks)
- speakers and microphones, both cameras, keyboard with backlight and RGB colour, touchpad, Fn keys
- Wi-Fi and Bluetooth (with tray applets in Desktop Mode), USB-A, the right USB-C port with docks
- dual boot next to BitLocker-protected Windows, one-click reboot in both directions
- old 32-bit DirectX 9 games (FlatOut 2 tested) running smoothly under Proton ARM64

Not yet: NPU, USB4/Thunderbolt, USB devices on the left USB-C port, TPM, light sensor; Secure Boot must be off.
Details: [docs/status.md](docs/status.md), [docs/known-issues.md](docs/known-issues.md).

> **State 2026-11-02.** Tested on one laptop. Every step was tested there, but the combined one-shot flow below
> has not yet been run end-to-end on a fresh machine. It changes your disk layout: have the BitLocker recovery key
> at hand and a backup of what matters.

## Install

You need: the laptop with Windows, a USB stick (8 GB+), Wi-Fi (or USB Ethernet on the **right** USB-C port) and
about 1-1.5 hours, mostly unattended.

1. **Windows** — download this repository (ZIP), then in an **elevated** PowerShell in its folder:
   ```powershell
   powershell -ExecutionPolicy Bypass -File windows\Prepare-S15.ps1 -LinuxSizeGB 200
   ```
   It suspends BitLocker, shrinks C: by 201 GB, creates the 1 GB partition `S15BOOT` and copies the ASUS firmware
   Linux needs onto it (those files may not be redistributed, so they come from your Windows).
2. **BIOS** (F2 at power-on) — Secure Boot: Disabled, Fast Boot: Disabled.
3. **Live USB** — write an ARM64 live Linux to the stick, e.g. Ubuntu Desktop for ARM64 26.04 or newer
   ([docs/live-system.md](docs/live-system.md)). Plug it into the USB-A port, press ESC at power-on, boot it,
   connect to Wi-Fi.
4. **Install** — in a terminal of the live system:
   ```sh
   git clone https://github.com/permissionBRICK/snaptop-linux.git   # or download and unpack the ZIP
   cd snaptop-linux && sudo ./install.sh
   ```
   It checks everything, shows what it will do and asks for `YES`. Then it partitions the free space, downloads
   SteamOS, builds the kernel, camera integration and tray applets on the laptop, adapts SteamOS and sets up the boot entry
   ([what exactly](docs/steamos.md#what-installsh-does)).
5. **Reboot** — SteamOS starts in Desktop Mode. Windows stays the default at power-on; "Reboot to Windows" is on the
   SteamOS desktop. In Windows, `windows\Install-RebootShortcut.ps1` (elevated) adds a "Reboot to SteamOS" icon.
   When you are done with BIOS changes: `Resume-BitLocker -MountPoint C:`.

Optional: `games/` adds Windows games to Steam with Proton ARM64 and the fixes old games need ([docs/games.md](docs/games.md)).

### Or let an AI agent do it

Steps 1-2 are yours (Windows admin rights and BIOS). For the rest, install a coding agent in the live system and
let it follow [AGENTS.md](AGENTS.md), which has the procedure, the safety rules and the known pitfalls. With Claude Code:

```sh
curl -fsSL https://claude.ai/install.sh | bash
cd snaptop-linux && claude "Read AGENTS.md and install SteamOS on this laptop."
```

## Docs

| Doc | Content |
|---|---|
| [docs/status.md](docs/status.md) | Per-component status |
| [docs/steamos.md](docs/steamos.md) | What the install does, the SteamOS adaptations, Desktop Mode, boot, dual boot |
| [docs/live-system.md](docs/live-system.md) | Live USB system, BIOS settings, booting pitfalls |
| [docs/kernel.md](docs/kernel.md) | Kernel sources, patches, config, boot parameters |
| [docs/firmware.md](docs/firmware.md) | Which firmware Linux needs and where it comes from |
| [docs/power.md](docs/power.md) | Idle and standby power, the standby setup, measuring |
| [docs/games.md](docs/games.md) | Windows games: Proton ARM64, FEX, DSOAL, native d3dx9 |
| [docs/known-issues.md](docs/known-issues.md) | Open problems and resolved ones |

## Repository layout

```
install.sh    one-shot installer (run in the live system)
windows/      Prepare-S15.ps1 (BitLocker, partition, firmware export), reboot-to-SteamOS shortcut
steamos/      image download, firmware/UCM fetch, SteamOS adaptations, boot partition, standby/Wi-Fi/input helpers
kernel/       build.sh (native or cross), config, our patches
desktop-net/  Plasma Wi-Fi/Bluetooth applets built against the image
games/        Steam shortcut writer, Proton prefix tweaks, DSOAL fetcher, tool mover
power/        power logger, report, sleep log hook
tools/        hardware diagnostics
docs/
```

Nothing here contains firmware or Valve/Microsoft binaries. Scripts download upstream sources at pinned revisions
and checksums (kernel tag, community patches, linux-firmware, alsa-ucm-conf, KDE releases, the Steam Frame image
build) or take files you export from your own Windows.

## Credits

This builds on other people's work:

- [BurninChrome/vivobook-s15-fedora](https://github.com/BurninChrome/vivobook-s15-fedora): the S15 kernel patch
  series (HM1092, ASUS EC hotkeys/backlight, Hamoa EC fan and suspend support, retimer and LPASS fixes), the DT
  overlay for audio/cameras/EC and the UCM profile. Their patches keep their authors' Signed-off-by.
- The mainline Linux X1E80100 maintainers and the Linaro/Qualcomm upstream work, and Mesa's Turnip/freedreno.
- [justririll/x1e-sleep](https://github.com/justririll/x1e-sleep): suspend work for this exact laptop: the panel supply,
  LPASS clock release, PCIe/NVMe/syscon votes, the ADSP Modern Standby message and the CX-collapse-only module,
  which took standby from 1.8 W to CX collapse.
- [hashtagbasit/SteamOS-ARM-Port](https://github.com/hashtagbasit/SteamOS-ARM-Port): the casync rootfs extractor
  and the Desktop Mode approach for the Frame image on non-headset hardware.
- Valve: SteamOS for the Steam Frame, the ARM64 Steam client, Proton 11 (ARM64) and FEX integration.
- [FEX-Emu](https://github.com/FEX-Emu/FEX), [Wine](https://www.winehq.org/), [kcat/dsoal](https://github.com/kcat/dsoal)
  and OpenAL Soft, KDE (Plasma, plasma-nm, bluedevil).

## License

[GPL-2.0-only](LICENSE), the license of the Linux kernel. The kernel patches by other authors keep their
authorship and Signed-off-by lines; `steamos/steamos-s15-desktop.sh` is adapted from SteamOS-ARM-Port (GPL-2.0).
Everything the scripts download (kernel, community patches and modules, firmware, UCM files, SteamOS, KDE sources,
DSOAL) keeps its own license and is not part of this repository.
