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
