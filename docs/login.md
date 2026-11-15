# Login password

SteamOS logs in automatically: at boot, after a logout, and whenever a session ends. On an encrypted laptop
([encryption.md](encryption.md)) the TPM then unlocks the disk and logs straight into the desktop, so anyone holding
the laptop has the data. `steamos/login-lock.sh` puts a password in front of it, as Windows does after BitLocker's
TPM unlock.

> **State 2026-11-04:** tested on the laptop with SteamOS 0.5.3 and 0.5.7: login screen at boot, both mode switches
> without it, the lock screen (Meta+L; unlock with password or PIN), the PIN lockout, the boot hardening (TPM unlock
> on the normal path, PCR 15 measured, a second unseal refused), speaker sound across mode switches.

## Setting it up

In SteamOS, in Konsole (Desktop Mode):

```sh
passwd                                                   # the password of the desktop user (steamos)
sudo /opt/snaptop-linux/steamos/login-lock.sh enable
sudo /opt/snaptop-linux/steamos/login-lock.sh status     # what is in place
```

`enable` refuses to run without a password. On an encrypted install it also checks the kernel for the two boot
fixes ([kernel.md](kernel.md#our-patches-boot-fixes-for-the-tpm-unlock)) and hardens the boot entries (below);
install a kernel with them first (`steamos/install-kernel.sh`). Nothing restarts the running session; the login
screen appears at the next boot or logout. `disable` returns to automatic login, SteamOS's screen lock and password
settings; it keeps the login screen's compositor setting and the boot hardening.

## What changes

| When | Without `login-lock.sh` | With it |
|---|---|---|
| Boot, logout, a session that crashed or was ended | automatic login | SDDM's login screen |
| Game Mode → Desktop Mode, Desktop Mode → Game Mode | automatic login | automatic login (the switch was asked for in an unlocked session) |
| Suspend, 5 minutes without input, Meta+L in Desktop Mode | no lock (Meta+L disabled) | Plasma's lock screen |
| Wrong passwords | unlimited | 10 within 15 minutes lock the user for 10 minutes |
| PIN (optional, `s15-pin set`) | none | login screen and lock screen take a PIN too, with its own lockout ([below](#pin)) |
| Encrypted install, any boot path but the normal one | TPM unlock | passphrase prompt ([encryption.md](encryption.md)) |

Game Mode has its own lock, Steam's PIN: Steam > Settings > Security > Lock screen. Turn on at least "Waking from
sleep" and "Switching to Desktop": `login-lock.sh` cannot see the Steam UI, so without the PIN someone who opens the
lid of a sleeping laptop in Game Mode gets Game Mode and, through "Switch to Desktop", Desktop Mode.

## How the mode switch stays automatic

Switching modes ends the session and logs in again. steamos-manager starts a switch by writing a one-time SDDM
configuration (`/etc/sddm.conf.d/zzt-steamos-temp-login.conf`, or `zzt-holo-temp-login.conf`) with the target
session and then ending the current one; SDDM reads its configuration again for the new login and logs in
automatically. Every other automatic login comes from SteamOS's permanent `zz-steamos-autologin.conf`.

`s15-login-gate` tells the two apart:

1. `s15-login-gate.path` watches the two one-time files. When one is written, `s15-login-gate arm` checks that an
   active, unlocked graphical session of a user is running on seat0 (`loginctl`: `Active=yes`, `LockedHint=no`,
   `Class=user`, `Type=wayland` or `x11`) and records the switch in `/run/s15-login/switch` (root only, gone at the next
   boot).
2. `/etc/pam.d/sddm-autologin` gets a first line `auth requisite pam_exec.so quiet /usr/local/sbin/s15-login-gate
   check`. SDDM's automatic login goes through this PAM service. The check consumes the record and lets the login
   through if it is at most 2 minutes old; otherwise PAM fails, and SDDM shows its login screen instead.

So a switch from an unlocked session logs in without asking, and everything else asks: a boot, a logout, a crash, a
killed or restarted session or SDDM, a switch file written from a locked or missing session. Logs:
`journalctl -t s15-login-gate`.

## Login screen and lock

- SDDM's own default compositor for a Wayland login screen is weston, which the image does not ship.
  `/etc/sddm.conf.d/s15-greeter.conf` runs it in KWin, as Plasma's own SDDM setup does
  (`kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1`).
- Keyboard layout: KWin reads it from systemd-localed. `enable` copies the Plasma desktop's layout
  (`~/.config/kxkbrc`) with `localectl set-x11-keymap --no-convert`, which leaves the console keymap (also used for
  the disk passphrase) as it is.
- Screen lock: `/etc/xdg/kscreenlockerrc` (`Autolock=true`, `LockOnResume=true`; the previous file is kept as
  `kscreenlockerrc.s15-orig`). A user's own `~/.config/kscreenlockerrc` (System Settings) overrides it.
- No audio for the login screen: PipeWire and WirePlumber do not start for the `sddm` user (`ConditionUser=!sddm`
  drop-ins in `/etc/systemd/user/`). With them, two audio stacks held the sound card for the ~10 s between a login
  and the end of the login screen's user session, and the next switch to Game Mode lost the speaker amplifiers
  (`SWR bus clsh detected` on the WSA SoundWire bus, `UNATTACHED`, no speaker sound until a restart).
- Locking on demand (Meta+L, "Lock" in the launcher's power menu): SteamOS forbids it in `/etc/xdg/kdeglobals`
  (`[KDE Action Restrictions][$i]`, `action/lock_screen=false`; `$i` makes it immutable, so a user setting cannot
  lift it). `enable` sets it to `true`, `disable` back to `false`. KWin reads it when the session starts, so the
  shortcut works from the next login (a switch to Game Mode and back is enough).
- Failed passwords: `pam_faillock` (`deny = 10`, `unlock_time = 600`, `dir = /var/lib/faillock`, between marker
  lines in `/etc/security/faillock.conf`). The records are kept on disk, so a restart does not reset the count. It
  applies to every password prompt of the system's PAM stack (login screen, screen lock, `sudo`, polkit dialogs).
  Unlock early as root: `faillock --user steamos --reset`. polkit's password helper (`polkit-agent-helper@.service`,
  in 0.5.7) runs with `ProtectSystem=strict`; without a drop-in that allows writing `/var/lib/faillock`, pam_faillock
  failed with "Read-only file system" and every password in a polkit dialog (e.g. Plasma's battery settings) was
  rejected.

## PIN

The login screen and Desktop Mode's lock screen also take a PIN, typed into the same field as the password:

```sh
sudo s15-pin set       # 6-12 digits, typed twice; s15-pin clear removes it, s15-pin status shows the lockout
```

- `sudo`, administrator prompts and everything else keep taking only the password; the password keeps working on
  the login and lock screens too.
- Lockout: after 5 wrong PINs the PIN is refused for 1 minute, after each further wrong one twice as long (up to
  60 minutes; a PIN typed during the wait is not even checked); after 15 wrong PINs it is off until a login with the
  password at the login screen (or `sudo s15-pin reset`). A correct PIN or such a login resets the count. The state
  survives restarts. Wrong PINs also count for the password's own lockout (`pam_faillock`, above), because the
  password check behind the PIN sees them too.
- Only input of 6-12 digits counts as a PIN attempt, so typing the password does not use up PIN tries.
- How: the first auth line of `/etc/pam.d/sddm` and `/etc/pam.d/kde` (pam_exec, `sufficient`) passes the typed value
  to `s15-pin`, which asks a root service on `/run/s15-pin.sock` (socket activated, `s15-pin@.service`, sandboxed).
  The service keeps the PIN as an scrypt hash with the lockout state in `/var/lib/s15-pin` (root only). It answers a
  user process only about that user's own PIN (`SO_PEERCRED`, like `unix_chkpwd` for the password) and takes resets
  only from root: the account phase of the login screen's PAM stack (`s15-pin pam-reset`).
- Not in the TPM, unlike Windows Hello: the TPM's dictionary-attack counter is shared with Windows, so wrong PINs
  would count against BitLocker and Windows Hello. The hash lies on the encrypted partition.
- Game Mode has Steam's own PIN (Steam > Settings > Security); it is separate from this one.

## Face unlock

Optional: the login screen and Desktop Mode's lock screen also recognise your face with the IR camera, as Windows
Hello does. It uses [Biopass](https://github.com/phucvinh57/biopass) 1.5.1 (face and fingerprint unlock for Linux
PAM, MIT license): the app from Biopass's arm64 release, its authentication part built on the laptop with our patches
for this IR camera (`face/patches/`, to be offered upstream).

> **State 2026-11-14:** built for SteamOS 0.5.7 (aarch64, in the image under qemu) and checked offline: Biopass's
> unit tests, our IR path against frames captured on the laptop, the PAM edits on the image's files. **Not yet tested
> on the laptop** (enrolment, unlocking, spoofing).

### Setting it up

Needs the login password ([above](#setting-it-up)). In Konsole (Desktop Mode):

```sh
sudo /opt/snaptop-linux/steamos/install-face.sh install    # about 15 minutes the first time (it builds)
```

1. Start **Biopass** from the application menu once: it writes its settings and downloads its models. Close it.
2. Choose the cameras (recommended: the IR camera, below), then open Biopass again and add your face under Face
   (enrol a few times: straight, slightly turned, with and without glasses):
   ```sh
   sudo s15-face camera ir
   ```
3. Log out or restart once: the first login after a boot always takes the password or the PIN.

`sudo s15-face snapshot ir` saves one frame as Biopass sees it (`/tmp/s15-face-ir.png`); `sudo s15-face status`
shows the state; `sudo /opt/snaptop-linux/steamos/install-face.sh status` the installation.

### What it does

| Where | With face unlock |
|---|---|
| Login screen, first login after a boot | Password or PIN only. |
| Login screen later (logout, a session that ended) | Press Enter on the **empty** password field: Biopass looks for your face, the camera light is on for a few seconds. A typed password or PIN goes straight to its check, never waits for the camera. |
| Desktop Mode lock screen | Biopass starts when the lock screen appears (a key press or mouse move) and again after a wrong password; the password field works at the same time. The lock screen's hint says "(or scan your fingerprint on the reader)" meanwhile: Plasma has no face wording for this service. |
| `sudo`, administrator dialogs (polkit) | Password only. Opt-in: `install-face.sh admin on` (read the security notes first). |
| Game Mode | Steam's own PIN; no face. |
| 5 face scans in a row without success | Face is refused until a login with the password or PIN, or a password unlock of the lock screen (`sudo s15-face reset` clears it). |
| Account locked by wrong passwords (`pam_faillock`) | Face is refused too. Face failures do not count towards that lockout. |
| No IR camera in your Biopass settings | Face is refused (`s15-face camera ir` or `rgb` sets it). |

Cameras (`s15-face camera`, writes `camera` and `anti_spoofing.ir_camera` in Biopass's settings, as libcamera
camera ids: both cameras share their video nodes, so the app's device list cannot tell them apart):

- `ir` (recommended): the IR camera both recognises your face and checks that a face is there. The IR light makes it
  work in the dark and the same in any room light, and a photo on a phone or monitor shows nothing in infrared.
  Biopass's anti-spoofing models are switched off: they are trained on colour images and misjudge IR frames.
- `rgb`: the colour camera recognises (in the room light), the IR camera only checks that it also sees a face. A
  printed photo can pass that check. The anti-spoofing models can be turned on in the app (they also reject real
  faces in poor light).

Faces enrolled with one camera do not match the other: enrol again after switching. Only one camera streams at a
time, and the camera light is on while either does.

### How it works

- Biopass's PAM module (`libbiopass_pam.so`) starts `biopass-helper` as the PAM caller (root on the login screen,
  you on the lock screen); it reads your settings and faces as you, captures, detects (YOLOv8 face) and compares
  (EdgeFace) on the CPU, 5 attempts within a few seconds.
- Our patches: the IR camera delivers only raw 10-bit frames (`R10_CSI2P`, 560x360, far below full scale); they are
  unpacked and stretched to 8-bit grey from their own black level and brightest pixels, turned upright (the camera
  is mounted upside down and cannot flip), and the dark frames of the IR light (it flashes 50 ms every 100 ms on
  its own) are skipped. The two cameras are told apart by their libcamera ids, and only one streams at a time.
  libcamera 0.8.0 is built with its CPU software ISP (no GPU access needed), and marked as installed: Biopass's
  bundled copy otherwise takes its own RUNPATH for a build tree, looks for its IPA helper process there, and the
  colour camera's software ISP does not start (patch 0003, a bug in Biopass 1.5.1 found from the code).
- `s15-face` (pam_exec) gates Biopass: `pam-empty` (login screen: empty field only) and `pam-gate` (lock screen,
  sudo/polkit), each counting a scan, and both refusing unless your Biopass settings name an IR camera (without
  one, a photo on a phone could pass); `pam-ok` and the login screen's account phase (`pam-account`) reset the count;
  the account phase also records the first login since boot in `/run/s15-face/<user>` (gone at the next boot).
- PAM lines (`login-lock.sh face-pam`, only while face unlock is installed and the login password is on):
  `/etc/pam.d/sddm` gets four auth lines after the PIN line (gate, `pam_faillock preauth`, Biopass, `pam_deny`: a
  failed or impossible scan fails the attempt) and one account line; `/etc/pam.d/kde-fingerprint` (kscreenlocker's
  service next to the password) is Valve's file with Biopass in place of fprintd, followed by `pam_deny` (Biopass
  answers "nothing to try" with `PAM_IGNORE`, which must not unlock); `/etc/pam.d/kde` gets the reset line after a
  password unlock. Never `/etc/pam.d/sddm-autologin`. `admin on` adds lines to `/etc/pam.d/sudo`, an
  `/etc/pam.d/polkit-1`, and a drop-in that opens polkit's sandboxed password helper to the cameras, udev and
  `/home` (read-only).
- Logs: `journalctl -t s15-face` (refusals), Biopass's own in `~/.local/share/com.ticklab.biopass/logs/` when debug
  logging is on in the app.
- The app's menu entry starts it with `WEBKIT_DISABLE_DMABUF_RENDERER=1`: WebKitGTK's DMA-BUF renderer ends it at
  once on this GPU under Wayland ("Error 71 (Protocol error) dispatching to Wayland display"). From a terminal:
  `WEBKIT_DISABLE_DMABUF_RENDERER=1 biopass`.
- polkit re-reads its actions when the app's policy file comes or goes. After one install it was left with none,
  and Plasma hid shutdown and sleep and ignored the lid; `install-face.sh` checks for that afterwards and restarts
  polkit and Plasma's polkit agent and power management if needed.

Your data stays with your user: settings in `~/.config/com.ticklab.biopass/config.yaml`, enrolled faces (cropped
images) and models in `~/.local/share/com.ticklab.biopass/`, on the encrypted partition on an encrypted install.
Nothing leaves the laptop; the app downloads its models from Biopass's GitHub releases.

Updates: `s15-os-update` installs face unlock into each new SteamOS version (webkit2gtk-4.1 from the new image's
repository, the build kept in `/var/lib/s15-face/cache`, rebuilt only when `face/` changes) and applies the PAM lines
again. If Valve changed one of the PAM files the lines were checked against (`steamos/face-pam.sha256`), the update
stops with an error naming the file: review the lines for it, or uninstall face unlock, update, and install again.

Removing it: `sudo /opt/snaptop-linux/steamos/install-face.sh uninstall` removes Biopass and the PAM lines; the PAM
files are byte for byte as before (`login-lock.sh status` and `sha256sum /etc/pam.d/*` to compare). Your faces and
settings stay in your home until you delete the two `com.ticklab.biopass` directories; webkit2gtk-4.1 stays installed
until the next SteamOS update (or `pacman -Rs webkit2gtk-4.1`).

### Security compared with Windows Hello

Same camera, same IR light, much less behind it:

- Windows Hello uses a face model built for IR with liveness checks, published false-accept rates (below 1 in
  100,000 for face), keeps the face template isolated (VBS on newer machines), and a match only releases a key held by
  the TPM. Here Biopass's general-purpose models decide with a threshold you set, there is no measured false-accept
  rate for this camera, the enrolled faces are image files in your home, and a match simply tells PAM "yes".
- Any program running as you can read your enrolled faces, add a face or lower the threshold. On the login and lock
  screen that only matters to someone who already has your session; for `sudo` and polkit (opt-in) it means such a
  program gets administrator rights as easily as with a `sudo` without password. Keep `admin` off unless that is
  acceptable on this machine.
- Spoofs: a phone or monitor shows nothing in IR (to be confirmed on the laptop). With `rgb`, a printed photo that
  the colour camera recognises also passes the IR presence check. With `ir`, a photo has to look like you in
  infrared; an IR photo, a good mask, a twin or a look-alike can pass. Face unlock is a convenience, weaker than your
  password: the password (or PIN) stays required after every boot, for `sudo` and polkit by default, and after 5
  failed scans.
- Keyring: Biopass can store your login password sealed by the TPM, to unlock a keyring after a face login. Not used
  here: SteamOS has no keyring PAM module, and our lines do not hand a password on (no `authtok`). Its seal is bound
  at most to PCR 7 (the Secure Boot state), which says little with Secure Boot off as on this laptop: any system
  booted on it that can read the sealed file (`/var/lib/biopass`; on an encrypted install only with the disk
  passphrase) can unseal your password. The TPM is also Windows' ([tpm.md](tpm.md)). Do not save your password in
  the app.
- The disk encryption and its TPM unlock are not involved: face unlock never runs before the first password or PIN
  login after a boot.

## Boot hardening (encrypted install)

`enable` adds `tpm2-measure-pcr=yes` to `rd.luks.options` and `systemd.gpt_auto=0` to every boot entry on `S15BOOT`
that opens the partition, installs the current `s15-luks-reseal` and runs it. From then on only the boot entries
themselves unlock with the TPM (PCR 0+2+4+9+15, [encryption.md](encryption.md#what-it-protects-and-what-not)): the
boot menu, a changed command line (`init=/bin/sh`, `rd.break`, emergency mode), another kernel, an EFI shell or a
live system all still work, but ask for the disk passphrase.

## Forgotten password

From a live USB system ([live-system.md](live-system.md)):

```sh
sudo cryptsetup open /dev/disk/by-partlabel/SNAPSTEAM-NVME root    # asks for the disk passphrase
sudo mount /dev/mapper/root /mnt              # not encrypted: mount /dev/disk/by-partlabel/SNAPSTEAM-NVME
sudo mount -t overlay overlay -o lowerdir=/mnt/etc,upperdir=/mnt/var/lib/overlays/etc/upper,workdir=/mnt/var/lib/overlays/etc/work /mnt/etc
sudo chroot /mnt passwd steamos
sudo umount /mnt/etc /mnt && sudo cryptsetup close root
```

SteamOS's `/etc` is an overlay (as in the boot); without it `passwd` would change a file that SteamOS does not see.
The disk passphrase is the master key: whoever has it can reset the login password. Without encryption anyone with a
USB stick can, so a login password alone only keeps out someone without one.
