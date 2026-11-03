# Hardware status

Tested machine: ASUS Vivobook S 15 **S5507QA** (board S5507QAD, BIOS S5507QAD.368), Snapdragon X Elite
**X1E-78-100**, 16 GB, 1 TB NVMe, Samsung OLED 2880x1620 120 Hz. Kernel 7.3.0-s15+ from `kernel/build.sh`
(mainline v7.3 + community S15 patches + our patch), SteamOS userspace from Valve's Steam Frame image.
State as of 2026-11-01.

Legend: **works** = tested on the machine; **untested** = should work per upstream, not checked here;
**no** = no Linux driver or support yet.

| Component | Status | Notes |
|---|---|---|
| Boot | works | Devicetree boot (`x1e80100-asus-vivobook-s15.dtb`), not ACPI. Secure Boot must be off for now, see [known-issues](known-issues.md). |
| Internal display (eDP OLED, 2880x1620 @ 120 Hz) | works | 8 bpc only with our msm DP patch (mainline picks 6 bpc and shows banding). |
| Brightness | works | DP AUX backlight, 0-2047. |
| GPU Adreno X1-85 | works | Mesa Turnip (Vulkan 1.4) and freedreno (GL 4.5+/GLES 3.2). Needs `qcdxkmsuc8380.mbn` from Windows. One game hit a GPU fault, see known issues. |
| CPU frequency scaling | works | SCMI perf, 3 policies, 0.71-3.42 GHz, schedutil. `scmi-cpufreq` does not autoload: load it via `modules-load.d`. Debian's 7.2 kernel lacks `CONFIG_ARM_SCMI_CPUFREQ`. |
| Keyboard, touchpad | works | I2C HID. |
| Fn row, hotkeys | works | `hid-asus-ec` (community patch): volume, brightness, mic mute, emoji, Super+P, Fn-lock, PROG keys. |
| Keyboard backlight | works | Fn key cycles off/1/2/3 (confirmed in Desktop Mode), via the EC (`asus::kbd_backlight`). |
| Keyboard backlight colour | works | `s15-kbd-color <rrggbb> [solid\|breathe\|rainbow\|strobe] [speed]` sends the EC's keyboard-RGB command (0x51 on the EC's I2C address 0x76; format from github.com/justririll/x1e-sleep). Solid colours confirmed. Brightness stays on the Fn key. |
| Speakers (2x WSA8845) | works | Community patches + DT overlay + UCM profile. Left/right confirmed. We switch off the LPASS WSA macro compander (it made short sounds start loud and fade). No speaker protection (keep volume reasonable). |
| Internal microphones | works | Captured signal confirmed. |
| Headphone jack | untested | |
| RGB camera (OV02C10) | capture works | 1920x1080 @ 30 through the libcamera simple pipeline with software ISP; image is dark and noisy. Browser access also needs the [camera components](steamos.md#cameras-and-browser-access), now included in setup. |
| IR camera (HM1092) + IR illuminator | works | 560x360 raw; our build sets `rotation = <180>`. Face login (howdy) untested. |
| Wi-Fi (WCN7850, ath12k) | works | Wi-Fi 7, 160 MHz, 1.9 Gbit/s link to a WPA2/WPA3 router. NetworkManager with iwd; the firmware can get stuck (see known issues, `s15-wifi-reset`). |
| Bluetooth | works | Controller comes up with the correct public address. A Shokz OpenRun Pro 2 headset paired and plays over A2DP (SBC/SBC-XQ); its microphone works over HFP (mSBC, 16 kHz): WirePlumber switches to the headset profile while an app records and back to A2DP afterwards. |
| USB-A | works | 5 Gbps. |
| USB-C (USB 3, PD charging, dock) | partly | Right port: hub, Ethernet, card reader and USB drives on a USB-C dock. Left port: charging only; USB devices time out and can freeze the machine ([known issues](known-issues.md)). |
| USB-C DP alt mode | untested | The port advertises DP. |
| HDMI | works | Through the Parade PS185 DP-to-HDMI converter (DP2): an Acer XF240H ran at 1920x1080@120 in Game Mode and next to the panel in Desktop Mode. Audio over HDMI not set up. |
| USB4 / Thunderbolt | no | No USB4 router driver for X1E. |
| Battery, charging | works | `qcom_battmgr` (cycle count, capacity, PD charging). |
| Lid switch | works | |
| Suspend (s2idle/"deep") | works | Lid close and resume tested. With `qcom_hamoa_ec.allow_suspend=1` the EC is told about standby and the power LED pulses like on Windows. Drain not measured yet. |
| Fans (EC) | works (experimental) | Community `qcom-hamoa-ec` S15 support + experimental EC overlay (the `-ec` DTB): fans follow the SoC temperature from 33 thermal zones; up to about 6600 RPM under full load. |
| Thermal zones | works | About 40 zones. |
| NVMe | works | |
| EFI variables / boot entries | works | Via qseecom/uefisecapp. They appear about 30 s into boot. |
| Reboot | mostly works | Twice hung at the final reset; see known issues. |
| Hexagon NPU | not yet tried | No QNN runtime for Linux and no upstream NPU accelerator driver, so normal AI apps cannot use it. A lower-level path exists: the mainline `fastrpc` driver plus the CDSP firmware (already boots here) runs llama.cpp's Hexagon backend on another X1E laptop (github.com/armbrusl/x1e-npu). Needs `fastrpc_shell_unsigned_3` from ASUS's Windows NPU driver package. |
| TPM | works | Qualcomm firmware TPM 2.0 in TrustZone through our driver `tpm_qcom_crb` (kernel patch 0011): `/dev/tpmrm0`, boot event log, PCRs match the log, survives suspend. Windows owns its state; see [tpm](tpm.md) before using it. |
| Ambient light / presence sensors | no | |
| Video decode (Iris) | untested | In mainline since 7.0. |

## Software on top

| Area | Status | Notes |
|---|---|---|
| SteamOS (Steam Frame image) | works | Game Mode (gamescope on DRM), Desktop Mode (Plasma Wayland), Steam login, audio, NTFS/exFAT USB drives automount. |
| Wi-Fi/Bluetooth in Desktop Mode | works | Tray applets and settings pages (plasma-nm, bluedevil) built for the image by `desktop-net/` show up in the tray. Joining a new password-protected network from the applet is not tested yet. |
| Native ARM64 Steam client | works | Valve's Frame build. |
| Old 32-bit Windows games | works | Proton 11 (ARM64) + FEX. FlatOut 2 runs smoothly with DSOAL and native d3dx9; see [games](games.md). |
| 64-bit Vulkan game (No Man's Sky) | partly | Ran well for a while, then a GPU fault. |
| Dual boot | works | Own EFI partition with systemd-boot + firmware boot entry; Windows Boot Manager stays default and untouched; one-click reboot in both directions. |
