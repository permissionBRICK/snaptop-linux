# SteamOS updates

`s15-os-update` installs Valve's next Steam Frame SteamOS build next to the running one, inside the same (encrypted)
partition, adapts it to the laptop and switches to it at the next restart. The external setup (Windows, BIOS,
partitions, encryption, `S15BOOT`, the firmware boot entry) stays as it is.

> **State 2026-11-04:** tested on the laptop: 0.5.3 -> 0.5.7 staged from Steam's hook (15 minutes, a full 4.3 GB
> download because the first update has no seed), restart into it, TPM unlock, confirm after 3 minutes; 0.5.3 stays
> as the previous system. Rollback was tested on a VM (boot-entry rotation), not yet on the laptop. Found and fixed
> on the way: the relay/VPN files and links to units enabled in the old image layer were not carried over (now:
> `/etc/openvpn` on the keep list, enabled units kept, own files via `/etc/atomic-update.conf.d/`), and 0.5.7's
> hibernation swap file fails on btrfs (masked).

## Why not Valve's updater

Valve's updater (`atomupd-daemon`, `steamos-atomupd-client`, RAUC) writes the new image raw into the other A/B
partition (`/dev/disk/by-partsets/B/rootfs`), with the Frame kernel and none of our adaptations, and switches the
Frame's own boot loader. This install has one partition, our kernel and its own boot partition. `s15-os-update` keeps
Valve's parts that fit: the update server and its branches, the signed bundles, the chunk store, the keys in the
installed image, and the rules for what an update keeps (`holo-sync-var`, `atomic-update-keep.conf`).

## Branches

Valve's update server offers one build per branch. On 2026-11-04:

| Branch | Build | Signed with |
|---|---|---|
| `stable` | 0.4.5 (20261022.6150929) | Valve's release key (`/etc/rauc/trusted_keys`) |
| `beta` | 0.5.7 (20261103.6153824) | Valve's development key (`/etc/rauc/development_keys`) |
| `preview` / `main` | 0.6.0 (20261103.6153902) | development key |

The installer uses 0.5.3 (20261002.6232440), a development build. Like Valve's daemon, the development key counts
only on a branch other than stable. A build is offered only if it is newer **and** not an older version: on `stable`
there is no update until stable reaches 0.5.3, so pick `beta` to follow the line the installer used. The branch is
read from Valve's own setting (`/etc/steamos-atomupd/preferences.conf`, set by Steam's channel selector or
`steamos-select-branch beta`); `--branch` overrides it.

## Using it

On an install made before this tool, install it once (the setup script does it for new installs and every version):

```sh
sudo /opt/snaptop-linux/steamos/install-os-update.sh
```

Then either in Steam (Game Mode: Settings > System, "OS Update Channel" and "Check for updates" / "Apply"), or:

```sh
steamos-select-branch beta               # Valve's tool: the branch Steam's channel selector sets too
s15-os-update check                      # what the branch offers (exit 0: newer, 7: nothing new)
sudo s15-os-update stage                 # 30-60 minutes, SteamOS keeps running; log: /var/log/s15-os-update.log
# restart: SteamOS starts the new version once
sudo s15-os-update status                # versions, boot entries
```

Steam runs `/usr/bin/steamos-polkit-helpers/steamos-update` (`--enable-duplicate-detection check` to check, without
`check` to apply), through pkexec; Valve's polkit action allows it without a password. `install-os-update.sh`
replaces it and `/usr/bin/steamos-update` with `steamos-update-s15` (Valve's scripts stay as `*.valve`): the check
asks `s15-os-update check` (exit 0 and the build id, 7, or 8 when a version is staged); "Apply" starts
`s15-os-update stage` as the systemd unit `s15-os-update-stage` (with a sleep inhibitor, so it continues if Steam
stops waiting) and passes its progress on as `NN%` lines.

A few minutes after the new version reached the login screen it becomes the default (`s15-os-confirm.timer`).
Other commands: `rollback` (the previous system becomes the default again), `discard` (remove a staged version that
was not confirmed), `try` (start a staged version once more after a failed start). The scripts that adapt the new
version come from `/opt/snaptop-linux`; for fixes from a newer checkout use `--repo <dir>`.

## What `stage` does

1. Asks Valve's update server for the branch's build, using the installed image's own update configuration
   (`/etc/steamos-atomupd/client.conf`, `manifest.json`).
2. Downloads the bundle (2 MB) and checks its signature with the keys of the installed image (`openssl cms`), and
   that it is for `steamos-aarch64`.
3. Assembles the 10 GiB image with `desync` from Valve's chunk store, using the current version's image as seed:
   only changed chunks are downloaded. Valve's builds change most of the image, so this saves only about a fifth:
   0.5.3 -> 0.5.7 downloaded 3.3 GB instead of about 4.3 GB (measured 2026-11-04). The first update after the
   install downloads everything, because the installer did not keep the image. Checks the image's sha256 against
   the signed manifest.
4. Copies it into a new btrfs subvolume `.s15-os/<build>` on the SteamOS partition.
5. Adapts it with `steamos-s15-setup.sh`: kernel, modules, DTBs, firmware and UCM come from the running system, so
   neither a kernel build nor the Windows firmware export is needed. Then the Plasma applets the new image lacks
   (`desktop-net`, at the image's KDE versions; 0.5.7 brings its own Wi-Fi applet, so only Bluetooth is built) and
   the camera libraries (`install-camera.sh`, inside setup).
6. Carries the system state over (next section), then re-applies the login password setup (`login-lock.sh
   apply-root`) so the new version never starts with the automatic login.
7. Builds the initramfs inside the new version with its `/etc` overlay mounted (it needs the kept console keymap
   for the disk passphrase), checks the adaptations that matter (modules, firmware, UCM, gamescope DRM backend,
   masked Frame units, LUKS in the initramfs, login gate, `/home` mount); a Valve change that broke one of the
   setup script's edits stops the update here.
8. Writes the boot entry "SteamOS (S15) - update <version>" (`s15-next.conf`, files in `S15BOOT/EFI/S15/next/`),
   re-seals the TPM for it ([encryption.md](encryption.md)) and sets systemd-boot's one-time entry
   (`LoaderEntryOneShot`) to it.

Any failure before the last step removes the new subvolume; the running version and its boot entries stay as they
were.

## What an update keeps

The same rules as Valve's updater (`/usr/lib/steamos/holo-sync-var` in the image):

- `/var`: everything, except what belongs to the image (`/var/lib/pacman`, `/var/lib/modules`, `/var/lib/dkms`,
  `/var/lib/NetworkManager`, `/var/boot`) and the `/etc` overlay. Valve's offload directories (`/var/log`,
  `/var/tmp`, `/var/lib/flatpak`, `/root`, ...) live in `/home/.steamos/offload` and are shared anyway.
- `/etc`: only the changed files on Valve's list (`/usr/lib/rauc/atomic-update-keep.conf`: network connections,
  passwords and users, hostname, time zone, machine id, SSH keys, SDDM configuration, systemd units and their
  enable links, ...), plus `/etc/atomic-update.conf.d/*.conf`. Ours (`s15.conf`) adds the console keymap
  (`vconsole.conf`), `locale.conf`, the login screen's keyboard layout (`X11/xorg.conf.d`), OpenVPN files that
  NetworkManager's VPN connections point to (`/etc/openvpn`) and the files our tools change at runtime
  (`s15-wifi-nopowersave`, `s15-kbd-mode.conf`, `s15-sleep-keep-bt`). Every other `/etc` edit is
  dropped, as on a Steam Deck, and kept for reference in `/etc/previous/`. To keep more, add a file with path
  patterns to `/etc/atomic-update.conf.d/`.
- `/usr/local`: files the new version does not have (tools installed after the setup) are copied.
- `/home`: not copied; all versions mount the same `/home`.

The state is copied while staging and once more at shutdown before the restart (`s15-os-catchup.service`, like
Valve's `holo-post-update-shutdown`), so changes made in between are not lost. If the laptop is switched off hard
instead, the new version starts with the state from staging.

## Layout

The SteamOS partition's btrfs top level (subvolume 5) holds:

- `home/`: shared by all versions.
- `.s15-os/<build>/`: one subvolume per installed version (its `/usr`, `/etc`, `/var`, ...).
- `.s15-os/images/<build>.img` (+ `.caibx`): the current version's image, the seed for the next delta download.
- `.s15-os/state.json`: current, previous and staged version.
- On an install made before this tool: the first SteamOS itself ("legacy"). It stays as the previous system after the
  first update; its files (about 10 GB) remain until they are removed by hand.

A version in a subvolume boots with `rootflags=...,subvol=.s15-os/<build>` and mounts the top level from the root
device itself (on an encrypted install `/dev/mapper/root`, the volume the initramfs opened, never a device found by
label or UUID) at `/run/s15-os/top`, and `/home` from there (two lines in its `/etc/fstab`). Valve's offload mounts
(`/var/log` etc., bound from `/home/.steamos/offload`) depend on `home.mount`, so that unit is not masked there.

## Boot entries and fallback

| Entry | Files on `S15BOOT` | Root |
|---|---|---|
| SteamOS (S15) | `EFI/S15/*` | current version |
| SteamOS (S15) - previous kernel | `EFI/S15/*.old` | current version, kernel before the last `install-kernel.sh` |
| SteamOS (S15) - previous system \<version\> | `EFI/S15/prev-os/*` | the version before the last update |
| SteamOS (S15) - update \<version\> | `EFI/S15/next/*` | a staged version, until it is confirmed |

- A restart after staging boots the new version once. Windows stays first at power-on; a restart (not a power-off)
  sets BootNext to SteamOS so it comes back.
- If the new version does not reach the login screen for 3 minutes (crash, hang, power cut), the next start is the
  old default again; `status` shows it as "did not confirm".
- After a confirmed update that misbehaves later: hold Space at power-on, choose "previous system", then
  `sudo s15-os-update rollback`.
- Two versions are kept; confirming a third deletes the oldest subvolume (the legacy top level is never deleted).
- Kernel updates (`install-kernel.sh`, `s15-update-esp`) work inside the current version as before.

The TPM is re-sealed for every entry ([encryption.md](encryption.md)); all of them unlock without the passphrase,
including the staged one before its first start.

## Disk use

About 20 GB during staging (the 10 GiB image while it is assembled, the new subvolume), then per version its own
files (an image has 4.2 GB in use, plus kernel modules, firmware and the camera build) and the current version's
image as seed (about 4 GB with its empty space punched out). With two versions plus the legacy install, about
25-30 GB.

## Open

- Removing the legacy install's files after the second update.
- Checked for 0.5.7 against the 0.5.3 install (2026-11-04, on the images): the files the setup scripts edit are
  unchanged except the WirePlumber microphone tracker, whose fix still applies; SDDM 0.21.0, steamos-manager 26.4.1
  and systemd 257.7 are the same; Plasma goes from 6.2.5 to 6.6.2 (KF6 6.14 -> 6.23, Qt 6.8 -> 6.10), which
  Desktop Mode (`steamos-s15-desktop.sh`) has not met yet.
