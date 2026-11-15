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

An optional module: the login screen and Desktop Mode's lock screen also recognise your face with the IR camera (or
with both cameras), as Windows Hello does. It uses [Biopass](https://github.com/phucvinh57/biopass) 1.5.1 (face and
fingerprint unlock for Linux PAM, MIT license), built on the laptop with our patches (`face/patches/`): its
authentication part for this IR camera, a minimum face size, a mode that needs both cameras and a helper that keeps
looking while it sees no face (0001-0008, to be offered upstream), and its app, which sets all of it up: the
cameras, your faces, test scans, the thresholds and the lockout (0009-0011). When to look, what counts and when a
match unlocks is ours: `s15-face` and `s15-face-run`. `s15-face` is also the command line for everything the app
does.

> **State 2026-11-15:** in use on the laptop in `both` mode. Checked on the laptop without a person at the keyboard:
> the PAM stacks end to end (lock screen and login screen, with the user's face), the display-off stop (with the
> real camera, the display simulated), the lockout service, pam_setcred for PIN, password and face on every stack.
> Tried by hand: the lock screen (Meta+L, Enter, no face then a face, a false face, Escape, the lid). Changed after
> that and not yet tried by hand: the lock screen starting by itself only after a wake from sleep, the login screen
> without Enter (checked with copies of the PAM stacks and a fake SDDM socket, not with the real greeter), across
> the room, in a dark room, with a photo on a phone.
> The app built from source (patches 0008-0011) is installed and checked on the laptop: the build with all its tests,
> the camera list (`hm1092` mono, `ov02c10` colour), the lockout through pkexec, a scan, and the app's page with the
> real settings and faces (on a virtual display). Not yet done by hand in the app: Add 5, Test, saving a mode change,
> Apply in the lockout card (the password dialog).

### Setting it up

Needs the login password ([above](#setting-it-up)). In Konsole (Desktop Mode):

```sh
sudo /opt/snaptop-linux/steamos/install-face.sh install    # about 10 minutes the first time (it builds)
```

Then open **Biopass** from the application menu (as yourself). It downloads its models when it first starts (AI
Models page). On the Configuration page, under Face Recognition:

1. **Cameras**: choose the mode (recommended: IR camera; strictest: both cameras, [below](#cameras)) and press
   **Save** (top right). The camera pickers name the sensors (`hm1092` is the IR camera, `ov02c10` the colour
   camera).
2. **Enrolled faces**: **Start camera**, then **Add 5**: five pictures two seconds apart (in both cameras' mode a
   colour and an IR picture each). Look at the screen as you usually sit, turn your head a little between them, and
   add some with and without glasses.
3. **Test**: one scan as the lock screen runs it, with each step (the face's size, scores) and each compared face's
   score on its picture, red when it is not above the threshold. A face that stays red when you test is worth
   deleting (its bin) and adding again; **Delete all** and **Add 5** enrol a camera anew.
4. Lock the screen (Meta+L) and press a key: face unlock looks for you. After a wake from sleep, and at the login
   screen, it starts by itself.

The same from a terminal, as yourself (camera and antispoof need sudo; close the app first):

```sh
sudo s15-face camera ir     # or: sudo s15-face camera both
s15-face enrol              # 5 pictures (pairs in both)
s15-face check              # one scan, each step shown: face size and scores
```

`sudo s15-face snapshot ir` saves one frame as Biopass sees it (`/tmp/s15-face-ir.png`); `s15-face status`
shows the state (display, lid, the count of false faces, whether face is allowed now); `sudo
/opt/snaptop-linux/steamos/install-face.sh status` the installation.

#### The app

Our build of Biopass's app (patches 0009-0011) knows this laptop's setup:

- **Cameras** lists the cameras by libcamera id (`biopass-helper list-cameras`, patch 0008): both cameras share all
  their `/dev/video` nodes, so Biopass's own list of video devices could not tell them apart. A mode sets the same
  settings as `s15-face camera` (including the minimum face size and threshold where they are missing or looser),
  and **Minimum face size** has its own slider. The app never writes camera profiles (face unlock refuses them);
  profiles from an earlier save of the unpatched app are read as the camera settings and replaced on Save.
- **Saving keeps every setting the app has no field for**: it writes its values into `config.yaml` as it is at that
  moment; Biopass's app used to drop everything it did not know.
- **Enrolled faces** shows every camera's faces (`faces/`, `faces-ir/`, `faces-rgb/`), labelled by camera and by
  whether the mode uses them; a save that switches between the IR and the colour camera as the main camera moves
  them, as `s15-face camera` does. **Add faces** and **Test** use the saved settings: save the cameras first.
- **Recognition threshold** warns below 0.6; **Anti-Spoofing** is off and locked in IR mode (the models are trained
  on colour pictures).
- **Face Unlock Lockout** shows the [lockout settings](#lockout-settings) and your count of false faces, and
  changes them through `pkexec /usr/lib/s15-face/s15-face-lockout` (polkit action
  `org.snaptop-linux.s15-face.lockout`): it asks for the administrator password, as `sudo s15-face lockout set`
  does. They are not part of the Save button.

### What it does

| Where | With face unlock |
|---|---|
| Login screen (also the first login after a boot) | Face unlock looks by itself while the login screen is up with the display on, as on the lock screen (runs of up to 60 s without a face, 3 false faces, the same lockout), and logs you in when it recognises you: no key needed. Right after a logout (you are still in front) it waits for Enter or the display going off and on. Enter on the **empty** password field starts a new run when one ended. A typed password or PIN works at the same time and goes straight to its check; logging in another way stops the scan. |
| Desktop Mode lock screen | Face unlock starts by itself when the lock screen shows after a wake from sleep or hibernation, as Windows Hello does; after Meta+L or an automatic lock (you are usually still in front then) at the first key press or mouse move. It keeps looking while it sees no face, stops when the display goes off, the lid closes or the laptop sleeps, and starts again by itself when the display is on again. A run ends after 3 false faces (about a second apart) or 60 s without a face; then Enter on the empty password field starts the next one (the lock screen shows "Unlocking failed": it treats every Enter as a password attempt, but an empty field is never checked as a password and never counts for `pam_faillock`). The password field works at the same time. While face unlock runs, the hint under the field says "(or scan your fingerprint on the reader)": Plasma has no face wording for this service. |
| Display off (Escape on the lock screen, the screen timeout), lid closed, asleep | Never looks, never unlocks: a run that is looking stops within 0.2 s, and a match counts only if the display is still on and the lid open 0.4 s after it (Escape turns the display off a moment after the key, so a match from just before is dropped). |
| `sudo`, administrator dialogs (polkit) | Password only. Opt-in: `install-face.sh admin on` (read the security notes first): one run as at the login screen, then the password. |
| Game Mode | Steam's own PIN; no face. |
| False faces (a face that did not match, or that anti-spoofing flagged) | Counted since the last success, as the PIN counts wrong PINs: the first 6 are free, then face waits 1 minute, after each further one twice as long (up to 60 minutes); after 15 it is off until a login or unlock with the password or PIN. Any success (face, password, PIN, login) starts the count again. The count is kept across restarts and SteamOS updates, so restarting gives no new tries. No face (nobody there, too small, cut off) never counts. The numbers are settings: [below](#lockout-settings). `sudo s15-face reset` clears the count. |
| Account locked by wrong passwords (`pam_faillock`) | Face is refused too (checked before each run). Face failures do not count towards that lockout. |
| A face across the room, or cut off at the edge of the picture | Not matched (and not counted): the face must fill at least a fifth of the picture's height (sitting in front of the screen, within about 1 m) and lie wholly inside it. |
| `both`: too little light for the colour camera, or one lens covered | Not matched, never the IR camera alone: the password or PIN. |
| No IR camera or no minimum face size in your Biopass settings | Face is refused (`sudo s15-face camera ir`, `rgb` or `both` sets them). |

#### Lockout settings

The lockout's numbers are root's, in `/etc/s15-face.conf` (not in Biopass's `config.yaml`: any program running as
you can rewrite that). Missing file, a missing, invalid or out-of-range value, or a file that is not root's or is
writable by others: the defaults. The file is kept across SteamOS updates.

| Key | Default | Range | Meaning |
|---|---|---|---|
| `run_false_faces` | 3 | 1-10 | false faces after which a run ends (on the lock screen the next starts on Enter or when the display comes on again) |
| `free_false_faces` | 6 | 0-100 | false faces since the last success before the first wait |
| `first_wait` | 60 | 0-86400 s | the first wait; doubled with every further false face; 0: no waits |
| `max_wait` | 3600 | 0-86400 s | the longest wait |
| `off_after` | 15 | 1-100 | false faces since the last success after which face is off until a password or PIN login or unlock |

```sh
s15-face lockout                          # the values in effect, KEY=VALUE per line
s15-face lockout keys                     # KEY DEFAULT MIN MAX UNIT MEANING per line
sudo s15-face lockout set first_wait 120  # a whole number within its range; several KEY VALUE pairs at once are
                                          # checked first and written together; prints the new values
sudo s15-face lockout reset-defaults      # all back to the defaults
```

Or in the Biopass app (Face Unlock Lockout, [above](#the-app)). `set` and `reset-defaults` need root (sudo, or the
app's pkexec) and exit 2 for an unknown key, a
value out of range or bad usage, 1 when not root or the file could not be written. Only values that differ from
the defaults are written, so a default changed in a later version applies then.

#### Cameras

The app's Cameras section, or `sudo s15-face camera ir|rgb|both`, writes `camera`, `anti_spoofing.ir_camera` and
`anti_spoofing.ir_recognition` in Biopass's settings, as libcamera camera ids (both cameras share their video nodes),
and the minimum face size and threshold [below](#how-it-works) where the settings have none or a looser one:

| Mode | Recognises | Needs | Against a photo |
|---|---|---|---|
| `ir` (recommended) | the IR camera | nothing: its own light, the same in any room light and in the dark | a phone or monitor shows nothing in IR; a printed photo has to look like you in infrared |
| `both` (strictest) | the colour camera **and** the IR camera, each against its own faces, on pictures at most 2.5 s apart | room light for the colour camera; about a second longer (one camera switch) | must fool both: a photo fails in IR, an IR-only fake in colour |
| `rgb` | the colour camera; the IR camera only checks that it sees some face | room light | a printed photo can pass the IR check |

In `ir` Biopass's AI anti-spoofing models are off: they are trained on colour images and misjudge IR frames. In `rgb`
and `both` the app's Anti-Spoofing model (or `sudo s15-face antispoof on`) turns one on for the colour picture: take
MiniFASNet V2 (Biopass's default, MobileNetV3, took the real face for a spoof in 2 of 3 scans on this camera's
pictures; MiniFASNet V2 passed 4 of 4). They may also reject real faces in poor light. In
`both` the IR recognition replaces the IR presence check. `both` never falls back to one camera: in a dark room, or
with the colour lens covered, face unlock fails and the password or PIN is needed (otherwise covering a lens would
weaken it).

Enrolled faces stay with their camera, so switching modes needs no new enrolment for a camera that has faces:
`faces/` holds the main camera's (the IR camera's in `ir`, the colour camera's in `rgb` and `both`), `faces-ir/` the
IR camera's in `rgb` and `both`, `faces-rgb/` the colour camera's while in `ir`; the app's Save and `s15-face camera`
move them when the main camera changes. Faces from one camera do not match the other. Only one camera
streams at a time, and the camera light is on while either does.

### How it works

- `s15-face-run` (through `s15-face`'s PAM entry points) starts `biopass-helper auth --keep-looking <ms>` as the
  PAM caller (root on the login screen, you on the lock screen), with only `PATH` in its environment, as Biopass's
  own PAM module does (that module is not used); the helper reads your settings and faces as you, captures, detects
  (YOLOv8 face) and compares (EdgeFace) on the CPU. With `--keep-looking` (patch 0007) attempts that compare no
  face use up no try: it keeps looking, `retry_delay` apart, and the first face it compares decides (exit 0 match,
  1 a false face, 3 no face within the time, 2 nothing to try). Biopass's own `retries` are not used then. Each
  decision takes about 0.8 s from the helper's start; between false faces the helper starts again (about 1 s).
- One attempt: one picture (the IR camera: the brightest lit one of 4), the largest face in it, cropped as detected
  (not aligned) and scaled to 112x112; its EdgeFace embedding is compared with each enrolled face of that camera
  (cosine similarity, 1 = identical). It matches when one enrolled face scores **above** `recognition.threshold`:
  Biopass's default 0.5, `s15-face camera` sets 0.6 (measured on the laptop, sitting in front: the best of the 5
  enrolled IR faces scored 0.34-0.92, mostly above 0.7; strangers, below). The attempt fails without a face, and
  since our patch 0004 also when the face is lower than `detection.min_face_height` of the picture (`s15-face
  camera`: 0.2) or touches its edge; Biopass itself took any face that YOLO found, however small. Sitting in front
  of the laptop the face measured 0.29-0.47 of the picture's height in IR (560x360) and 0.44-0.60 in colour
  (1920x1092); 0.2 is about one and a half times that distance for the IR camera, a face across a room is about
  0.1.
- `both` (patch 0005, `anti_spoofing.ir_recognition`): the attempt starts on the camera that is open (at first the
  colour camera); once that picture has a face, the camera closes and the other one opens while the first face is
  compared; a match there too, on a picture at most 2.5 s after the first, unlocks. A miss on the second camera
  leaves it open, and the next attempt starts there. Measured: a scan that matches at once takes 1.3 s, the two
  pictures 0.5 s apart.
- `s15-face check` runs one scan (`biopass-helper auth --verbose`, patch 0006: Biopass's own 5 attempts), with each
  step on the terminal: the face's size and how it compares with the minimum, the best score and the threshold. The
  app's Test runs `biopass-helper auth --verbose --keep-looking 6000` (as the login screen looks: the first face
  compared decides) and also reads each enrolled face's score from the helper's log. Neither is counted, and
  neither checks the display.
- Our patches: the IR camera delivers only raw 10-bit frames (`R10_CSI2P`, 560x360, far below full scale); they are
  unpacked and stretched to 8-bit grey from their own black level and brightest pixels, turned upright (the camera
  is mounted upside down and cannot flip), and the dark frames of the IR light (it flashes 50 ms every 100 ms on
  its own) are skipped. The two cameras are told apart by their libcamera ids, and only one streams at a time.
  libcamera 0.8.0 is built with its CPU software ISP (no GPU access needed), and marked as installed: Biopass's
  bundled copy otherwise takes its own RUNPATH for a build tree, looks for its IPA helper process there, and the
  colour camera's software ISP does not start (patch 0003, a bug in Biopass 1.5.1 found from the code).
- The gate (`s15-face-run gate`, and before every helper start) refuses unless your Biopass settings name an IR
  camera (without one, a photo on a phone could pass) and a minimum face size, while `pam_faillock` locks the
  account (read from its tally file), during a wait and once face is off (the lockout above).
- The display rule: "on" is a DRM connector that is connected, enabled and has DPMS on
  (`/sys/class/drm/card0-eDP-1/{status,enabled,dpms}`; a disconnected port also says "On"), the lid is logind's
  `LidClosed` (closed when it cannot be read), a sleep is CLOCK_BOOTTIME running ahead of CLOCK_MONOTONIC. While a
  helper looks, the runner checks every 0.2 s and kills it; after a match it waits 0.4 s and checks again. A stopped
  helper is killed with everything it started: libcamera's IPA workers (`softisp_ipa_proxy`) run in process groups
  of their own and outlived a killed helper (four held a shutdown up for 90 s); the runner stops the helper, kills
  its descendants and the helper, and Biopass patch 0012 gives the workers a parent-death signal as well.
- The lock screen (kscreenlocker 6.6.2, read from its source): it runs two PAM services side by side, `kde` (the
  password field, interactive) and `kde-fingerprint` (non-interactive; also `kde-smartcard`). Both start only in
  `startAuthenticating()`, which Plasma's `LockScreenUi.qml` calls whenever its UI is shown **or hidden**
  (`onUiVisibleChanged`: a key, a mouse move or click, Escape, the 10 s fade-out, the mouse leaving) and 3 s after a
  failed password (`graceLockTimer`); it does nothing while a round is running, and a non-interactive failure does
  not end the round (only a failed password does). So: nothing starts on its own when the lock screen appears or
  after a wake; Escape hides the UI, which may start a round, and turns the display off on the key's release
  (`greeterapp.cpp`), so a scan could start, and match, while the screen goes dark: the bug that the display rule
  fixes; and a face scan that ended can only be started again by a failed password. Hence:
  - `kde-fingerprint` runs `s15-face pam-watch`: one long conversation (as fprintd's is), from the first round
    until a match (or face is off): it looks while the display is on, waits with the camera off while it is off,
    and starts a new run when it comes on again. It ends when the greeter does (it watches its parent; the greeter
    ends with `_exit` after an unlock and would otherwise leave it running).
  - `kde` gets `s15-face pam-rescan` in front of the PIN and the password: an empty field asks the watch for a new
    run and fails without a password check. kscreenlocker then starts its round again 3 s later, which is harmless.
  - `s15-face-wake.service` (root, `s15-face-run wake`, on logind's signals: `PrepareForSleep`,
    `PropertiesChanged`, `SessionNew`/`SessionRemoved`; no polling) taps F24, a key nothing uses, on a short-lived
    virtual keyboard (`/dev/uinput`) once after a wake from sleep or hibernation (`PrepareForSleep` false), when the
    lock screen shows within 60 s with the display on, the lid open and no watch running: the first key press,
    which starts the round. Not after Meta+L or an automatic lock. Never in kscreenlocker's grace time: after an
    automatic lock any input unlocks without a password for `LockGrace` seconds (the greeter then runs with
    `--graceTime <ms>` and without `--immediateLock`; it waits that long plus 3 s after the lock), never when the
    lock needs no password (`--nolock`). Until 2026-11-15 it never tapped: it runs with `ProtectSystem=strict`, and
    reading the count opened its file for writing, which failed there, so every lock screen was skipped silently.
- The login screen (SDDM 0.21, read from its source): SDDM runs PAM only when its greeter sends `Login` over the
  daemon's greeter socket (`/tmp/sddm-<display>-<random>`, `src/daemon/SocketServer.cpp`; found from the greeter's
  `--socket` argument: Qt binds it under a temporary name and renames it, so `/proc/net/unix` does not show it;
  QDataStream: quint32 1,
  QString user, QString password, the session as quint32 type and QString desktop file). While SDDM's greeter
  session is active on seat0, `s15-face-wake` runs `s15-face-run greeter <user>` (the last user from
  `/var/lib/sddm/state.conf`): the lock screen's loop as root, with the same display rule and lockout. A match
  leaves a token in `/run/s15-face/token` (root's, single use, 15 s, bound to the user) and sends SDDM the same
  `Login(user, empty password, last session)` its greeter would; SDDM runs its PAM stack, where `pam-scan` takes
  the token instead of looking: the face path, whose `pam_setcred` was checked. When the user's session ended less
  than 60 s before (a logout), the first run waits for Enter or the display going off and on. SDDM takes `Login` from any
  connection to that socket, but `Display::login` keeps the sender for its answer before it checks for a login in
  progress, and deletes the connection when it closes: so `Login` is sent only while no login is being checked (no
  `sddm-helper` without `--greeter`), and the connection stays open until SDDM answers. Enter on the empty field
  (the greeter's own `Login`) makes `pam-scan` ask the background scan for a run and take its token: one user of
  the camera. The scan stops when the greeter session ends (any login) or the wake service stops.
- The count of false faces: `/var/lib/s15-face/lockout/<user>` (root's, 0600; `fails`, `until` in wall-clock
  seconds). The lock screen's runs run as you and reach it only through `s15-face.socket` (`s15-face-run serve`,
  one request per connection, the caller identified by `SO_PEERCRED`): read it, count one false face (the service
  applies root's lockout numbers), reset it after a success, each only for the caller's own user. Root's paths (the
  login screen, the wake service, `s15-face reset`) use the file directly. A program running as you can reset its
  own count (as it can change your Biopass settings, see the security notes); the count protects against people at
  the keyboard, and a restart no longer resets it. `/run/s15-face/<user>` (yours) only holds the lock screen's
  watch and Enter presses.
- PAM lines (`login-lock.sh face-pam`, only while face unlock is installed and the login password is on):
  `/etc/pam.d/sddm` gets four auth lines **in front of** the PIN line (`pam-empty`: an empty field and the gate;
  `pam_faillock preauth`; `pam-scan`; `pam_deny`: a failed or impossible scan fails the attempt) and one account
  line (`pam-account`: a login resets the count). In front of the PIN line, not after it: `pam_setcred` replays
  the auth chain, and modules that did not run in it (after the PIN's `sufficient` success all of them) decide by
  their setcred result, which is `PAM_IGNORE` for `pam_exec`; `pam-empty`'s `default=3` jump then made the whole
  `pam_setcred` `PAM_IGNORE` and SDDM went back to the login screen after every PIN login (checked with copies of
  the stacks through `pam_start_confdir`: PIN, password and face now all give `PAM_SUCCESS` in sddm, kde,
  kde-fingerprint, sudo and polkit-1). `/etc/pam.d/kde-fingerprint` is Valve's file with `pam-watch` in place of
  fprintd, `pam_deny` after it and `pam-ok`; `/etc/pam.d/kde` gets `pam-rescan` and `pam_deny` in front of the PIN
  line and `pam-ok` after a password unlock. Never `/etc/pam.d/sddm-autologin`. `admin on` adds the gate,
  `pam_faillock preauth` and `pam-scan` to `/etc/pam.d/sudo` and an `/etc/pam.d/polkit-1`, and a drop-in that opens
  polkit's sandboxed password helper to the cameras, udev, `/home` (read-only) and the count.
- Logs: `journalctl -t s15-face` (refusals, false faces, run ends, matches, the wake service's taps), Biopass's own
  in `~/.local/share/com.ticklab.biopass/logs/` when debug logging is on in the app (it also keeps pictures of
  failed faces in `debugs/` then); `s15-face check` shows the same steps without it. `tools/test-s15-face-run.py`
  tests the runner without a camera (a fake helper and display).
- The build (`face/build.sh`, in a chroot of the running SteamOS under an overlay in `/var/tmp`, nothing installed
  on the system): the archives in `face/sources.sh` are pinned by sha256; the app's frontend packages come from
  Biopass's `app/bun.lock`, each checked against its sha512 (`face/bunlock.py`, as bun would lay them out: the
  image's repository has no bun), its crates from `app/src-tauri/Cargo.lock` (`cargo fetch --locked`, each checked
  against its sha256); Rust and Node.js from the SteamOS image's own repository into the overlay; then it builds
  offline and runs the tests our patches touch (the auth part's, the app's Rust tests, its frontend tests with Node
  in place of `bun test`). The image's Rust 1.93 is older than the 1.95 that one crate (`rusqlite_migration` 2.6)
  declares; it builds with it (`--ignore-rust-version`) and the app's database tests pass. Measured on the laptop
  (12 cores): 7.5 minutes (the auth part 2.5, the app 3, its tests 1), up to 4 GB in `/var/tmp` while it runs, and
  the first time about 0.4 GB of downloads. The result is kept in `/var/lib/s15-face/cache`, the downloads in
  `/var/lib/s15-face/cache/src`.
- The app's menu entry starts it with `WEBKIT_DISABLE_DMABUF_RENDERER=1`: WebKitGTK's DMA-BUF renderer ends it at
  once on this GPU under Wayland ("Error 71 (Protocol error) dispatching to Wayland display"). From a terminal:
  `WEBKIT_DISABLE_DMABUF_RENDERER=1 biopass`.
- polkit re-reads all its actions as soon as a policy file appears. When the install unpacked the app's policy file
  with everything else, polkit read it half-written and was left with no actions at all, every time: Plasma then
  hid shutdown and sleep and ignored the lid. `install-face.sh` now puts the policy files (Biopass's and the
  lockout's) last, complete, each with a rename, and still checks afterwards (restarting polkit and Plasma's polkit
  agent and power management if needed).

Your data stays with your user: settings in `~/.config/com.ticklab.biopass/config.yaml`, enrolled faces (cropped
images: `faces/`, `faces-ir/`, `faces-rgb/`) and models in `~/.local/share/com.ticklab.biopass/`, on the encrypted
partition on an encrypted install. Nothing leaves the laptop; the app downloads its models from Biopass's GitHub
releases.

Updates: `s15-os-update` installs face unlock into each new SteamOS version (webkit2gtk-4.1 from the new image's
repository, the build kept in `/var/lib/s15-face/cache`, rebuilt only when `face/` changes) and applies the PAM lines
again; the count of false faces (`/var/lib`) and the lockout settings (`/etc/s15-face.conf`, on the update's keep
list through `/etc/atomic-update.conf.d/s15-face.conf`) stay. If Valve changed one of the PAM files the lines were checked against (`steamos/face-pam.sha256`), the update
stops with an error naming the file: review the lines for it, or uninstall face unlock, update, and install again.

Removing it: `sudo /opt/snaptop-linux/steamos/install-face.sh uninstall` removes Biopass, the PAM lines, the
services, the count of false faces and the lockout settings; the PAM files are byte for byte as before (`login-lock.sh status` and `sha256sum /etc/pam.d/*` to compare). Your faces and
settings stay in your home until you delete the two `com.ticklab.biopass` directories; webkit2gtk-4.1 stays installed
until the next SteamOS update (or `pacman -Rs webkit2gtk-4.1`).

### Security compared with Windows Hello

Same camera, same IR light, much less behind it:

- Windows Hello uses a face model built for IR with liveness checks, published false-accept rates (below 1 in
  100,000 for face), keeps the face template isolated (VBS on newer machines), and a match only releases a key held by
  the TPM. Here Biopass's general-purpose models decide with a threshold you set, the enrolled faces are image files
  in your home, and a match simply tells PAM "yes".
- How often a stranger matches, measured with Biopass's own pipeline (the crop as detected, not aligned, and
  EdgeFace) on 1200 colour photos of 600 people from the public LFW set: two photos of different people scored above
  0.5 in 3 of 10,000 pairs, above 0.6 in 2 of 100,000 (the highest of 720,000 pairs: 0.76); a tiny face (a person
  across a room) scored no higher. Each false face is compared with each of 5 enrolled faces, and 15 false faces
  are allowed (with waits after the 6th) before the password or PIN is needed, also across restarts: at most 75
  tries, so a random stranger gets in with a chance of up to about 2 % at Biopass's default 0.5 and 0.15 % at 0.6,
  which `s15-face camera` sets (Windows Hello: 0.001 %); before 2026-11-15 it was 125 tries per boot, and every
  restart gave new ones. A relative or a look-alike scores higher than a random stranger. IR pictures have no such
  public set; `both` makes a stranger match on both cameras at once.
- Any program running as you can read your enrolled faces, add a face or lower the threshold. On the login and lock
  screen that only matters to someone who already has your session; for `sudo` and polkit (opt-in) it means such a
  program gets administrator rights as easily as with a `sudo` without password. Keep `admin` off unless that is
  acceptable on this machine.
- Spoofs: a phone or monitor shows nothing in IR (to be confirmed on the laptop). With `rgb`, a printed photo that
  the colour camera recognises also passes the IR presence check. With `ir`, a photo has to look like you in
  infrared; an IR photo, a good mask, a twin or a look-alike can pass. With `both`, a fake must pass as you in colour
  and in infrared within the same 2.5 seconds; a twin or a look-alike still can. Face unlock is a convenience, weaker
  than your password: the password (or PIN) stays required for `sudo` and polkit by default, and after 15 false
  faces.
- Keyring: Biopass can store your login password sealed by the TPM, to unlock a keyring after a face login. Not used
  here: SteamOS has no keyring PAM module, and our lines do not hand a password on (no `authtok`). Its seal is bound
  at most to PCR 7 (the Secure Boot state), which says little with Secure Boot off as on this laptop: any system
  booted on it that can read the sealed file (`/var/lib/biopass`; on an encrypted install only with the disk
  passphrase) can unseal your password. The TPM is also Windows' ([tpm.md](tpm.md)). Do not save your password in
  the app.
- At the login screen and after a wake, face starts by itself: whoever sits in front of the screen is scanned
  without pressing a key, and a match logs in. Their false faces count as any others (the same lockout).
- The first login after a boot takes a face too, as it takes the PIN: the count of false faces survives restarts,
  so a restart gives no new tries. The disk encryption and its TPM unlock are not involved:
  the login screen only appears after the disk is open (with the TPM on an encrypted install), and face, like the
  PIN, guards the session, not the disk. Someone who boots another system, or changes the boot to get a shell, is
  stopped by the disk passphrase, not by the login screen ([encryption.md](encryption.md)).

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
