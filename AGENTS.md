# Instructions for AI agents

You are helping a user install SteamOS on an **ASUS Vivobook S 15 S5507QA** (Snapdragon X Elite X1E80100) next to
Windows, using this repository. Read README.md first; docs/ has the background. Work step by step, show the user
what you are about to do before anything that writes to disk, and report results plainly.

## Never

- Write to any partition other than the two this project owns: `S15BOOT` (FAT32, 1 GB) and `SNAPSTEAM-NVME`
  (created by `install.sh`). Never touch the Windows partitions, the Windows EFI partition, or the Qualcomm firmware
  partitions at the start of the NVMe (partition entries 1-11: ToolsFv, LogFs, NHLOS, ...; damaging them can brick
  the laptop). Resolve disks by label or partlabel, never by `sdX` names; check `lsblk -o NAME,SIZE,LABEL,PARTLABEL,PARTTYPE`.
- Change BitLocker, Secure Boot or other BIOS settings yourself, or resume BitLocker without the user.
- Commit, upload or share the ASUS firmware files (they are not redistributable).
- Put a boot loader in front of Windows Boot Manager or chainload Windows (BitLocker would ask for the recovery key).
- Clear the TPM, change its authorizations or evict its persistent keys, or guess TPM PINs: Windows (BitLocker,
  Windows Hello) owns its state (docs/tpm.md).

## Where you are

- **In Windows** (the user runs an agent there, or does it by hand): only step 1 of the README,
  `windows\Prepare-S15.ps1` in an elevated PowerShell. Check the result: `Get-Volume -FileSystemLabel S15BOOT`, and
  `(Get-Disk -Number <n>).LargestFreeExtent` shows the free space (at least 64 GB). Then the user changes the BIOS
  (Secure Boot off, Fast Boot off) and boots a live ARM64 Linux from USB (docs/live-system.md).
- **In the live Linux** (normal case): `uname -m` is `aarch64`, `/sys/firmware/devicetree/base/model` names the
  Vivobook S 15. You need network (`nmcli device wifi connect <ssid> --ask`, or USB Ethernet on the *right* USB-C
  port) and root (`sudo`; on Ubuntu's live session it needs no password).
- **In the installed SteamOS**: user `steamos`, Desktop Mode by default; for later kernels see docs/steamos.md.

## Procedure in the live system

1. `lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL` — find `S15BOOT` on `nvme0n1` and check the free space
   (`sudo sgdisk -p /dev/nvme0n1` shows "Total free space"). If `S15BOOT` or the free space is missing, stop: the
   Windows step was not done.
2. Ask the user for the time zone (e.g. `Europe/Berlin`).
3. `sudo ./install.sh --timezone <TZ>` from the repository root. It asks for `YES`; let the user confirm (or pass
   `--yes` after the user agreed to the plan it printed). It runs 10 steps and logs to `/tmp/s15-install.log`.
   Expect 1-1.5 hours: the SteamOS download (3 GB), the native kernel build (30-40 min), the applet build.
   Run it so its output stays visible and check on it; do not start it twice.
4. On success, tell the user to reboot (the laptop starts SteamOS once via BootNext) and what is next (README step 5).
5. On failure: read the end of `/tmp/s15-install.log`, fix the cause, then rerun with `--reinstall` (it reformats
   the SteamOS partition it created; it never recreates S15BOOT). A kernel that the failed run already built is
   kept automatically, so the 30-40 minute build is not repeated.

## Known pitfalls

| Symptom | Cause / fix |
|---|---|
| `efibootmgr` fails or the entry is missing after install | EFI variables on X1E go through the TrustZone app uefisecapp and register a few seconds after boot. `install-esp.sh` remounts efivarfs; if it still fails it prints the `efibootmgr -c ...` command to run later from SteamOS. Until then: ESC at power-on, or boot the stick and rerun only `steamos/install-esp.sh /mnt/steam <S15BOOT dev>` with the SteamOS partition mounted at `/mnt/steam`. |
| Overlay mount error in the applet build | The build overlay cannot sit on another overlay; `install.sh` gives it a tmpfs. Keep that when running `desktop-net/build.sh` by hand. |
| Live system freezes when a USB-C dock/adapter is plugged into the **left** USB-C port | Known xHCI problem on that port. Unplug; use the right port. |
| Wi-Fi scans fail (`ath12k ... scan start failure`) or connects time out | Firmware stalls; in SteamOS `s15-wifi-reset` (driver reload) and the watchdog handle it. In the live system: `modprobe -r ath12k_wifi7 && modprobe ath12k_wifi7`, or a reboot. |
| Disconnects every ~30 s on some access points (`DISASSOC_LOW_ACK`) | Wi-Fi power save; SteamOS turns it off per network automatically (`s15-wifi-powersave`). |
| `C: can shrink by at most ...` in Prepare-S15.ps1 | Unmovable files; free space in Windows or pass a smaller `-LinuxSizeGB` (min 64). |
| Windows asks for the BitLocker recovery key | BitLocker was not suspended before a BIOS change. The user enters the key; afterwards suspend it before further BIOS changes. |

## Checking the installed system (in SteamOS, as root)

- `uname -r` ends in `-s15+`; `cat /proc/cmdline` has `root=PARTLABEL=SNAPSTEAM-NVME`, or on an encrypted install
  `root=/dev/mapper/root rd.luks.name=<UUID>=root`, `tpm2-measure-pcr=yes` in `rd.luks.options` and
  `systemd.gpt_auto=0` (docs/encryption.md; `journalctl -u s15-luks-reseal` shows the TPM re-sealing, bound to
  PCR 0+2+4+9+15). Never remove the passphrase key slot or the re-seal key; the TPM tokens are managed by
  `s15-luks-reseal`. Never seal the running boot or other PCR sets by hand: only the boot entries may unlock.
- SteamOS updates (docs/updates.md): `s15-os-update status`. `steamos-update` (what Steam runs) is ours and calls
  `s15-os-update`. Never run Valve's updater (`atomupd-manager update`, `rauc install`, `steamos-update.valve`) on
  this install, and never delete a subvolume in `.s15-os/` or the top level's files by hand;
  `s15-os-update discard`/`rollback` do that.
- Login password (docs/login.md): `sudo /opt/snaptop-linux/steamos/login-lock.sh status`. Never set or ask for the
  user's password or the disk passphrase; the user types them. Never remove the `s15-login-gate check` line from
  `/etc/pam.d/sddm-autologin` or add automatic logins except through `login-lock.sh disable`.
- Audio: `aplay -l` lists the X1E80100 card; Wi-Fi: `nmcli device wifi list`; GPU: `vulkaninfo --summary` (Turnip).
- Standby: after one suspend, `cat /sys/kernel/debug/qcom_stats/cxsd` shows a rising count (needs debugfs);
  `/var/log/s15-sleep.log` logs every sleep with drain and residency.
- Boot entries: `efibootmgr` shows Windows Boot Manager first, then "SteamOS (S15)".
- TPM: `/dev/tpmrm0` exists; `tools/s15-tpm-check.py` (read-only) prints QCOM "xCGfTPM" and `OK` for PCR 0-7.

## Changing this repository

Keep it generic: no personal data (names, addresses, networks, accounts), no firmware, no binaries. Scripts must stay
idempotent where possible and refuse to run on anything but this laptop. Document behaviour changes in docs/.
