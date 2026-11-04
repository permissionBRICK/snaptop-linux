#!/bin/bash
# Login password for SteamOS on the Vivobook S15 (docs/login.md). Run as root in the installed SteamOS, from a checkout
# of this repository, after setting a password for the desktop user (passwd):
#   sudo steamos/login-lock.sh enable|disable|status
# enable:
#   - boot, logout and every other new session: SDDM's login screen instead of the automatic login. The automatic
#     login stays only for switches between Game Mode and Desktop Mode (s15-login-gate). The login screen runs in
#     KWin and gets the keyboard layout of the Plasma desktop.
#   - Desktop Mode locks the screen on suspend and after 5 minutes without input.
#   - 10 wrong passwords within 15 minutes lock the account for 10 minutes (pam_faillock, also across restarts).
#   - encrypted install (docs/encryption.md): boot entries and TPM tokens so that only the normal boot path unlocks
#     with the TPM (PCR 0+2+4+9+15). Needs a kernel with kernel/patches/0012 and 0013.
# disable: automatic login, SteamOS's screen lock and password settings again. The boot hardening stays.
# apply-root <dir>: the login parts of enable for a SteamOS root that is not running (s15-os-update puts them into a new
#   SteamOS version before its first boot; the password itself comes with /etc/shadow).
# Nothing here restarts the running session; the login screen appears at the next boot or logout.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
grep -q '^ID=steamos' /etc/os-release || die "not SteamOS"
model=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || true)
case $model in *"Vivobook S 15"*|*S5507Q*) ;; *) die "not the Vivobook S15 (model: $model)";; esac

U=$(cat /usr/lib/sddm/sddm.conf.d/*.conf /etc/sddm.conf.d/*.conf 2>/dev/null | sed -n 's/^User=//p' | tail -1 || true)
U=${U:-steamos}
id "$U" >/dev/null 2>&1 || die "autologin user $U does not exist"
PAMF=/etc/pam.d/sddm-autologin
PAM_LINE='auth       requisite   pam_exec.so quiet /usr/local/sbin/s15-login-gate check'
# login PIN (s15-pin, docs/login.md): in front of the password check of the login screen and the lock screen
PIN_AUTH='auth       sufficient  pam_exec.so quiet expose_authtok /usr/local/sbin/s15-pin pam'
PIN_ACCT='account    optional    pam_exec.so quiet /usr/local/sbin/s15-pin pam-reset'
GREETER=/etc/sddm.conf.d/s15-greeter.conf
KSL=/etc/xdg/kscreenlockerrc
FL=/etc/security/faillock.conf
KG=/etc/xdg/kdeglobals
# the login screen's user (SDDM) gets no audio stack: see install_login
GREETER_AUDIO="pipewire.socket pipewire.service pipewire-pulse.socket pipewire-pulse.service wireplumber.service"
FL_BEGIN='# s15-login-lock begin (docs/login.md)'
FL_END='# s15-login-lock end'
LUKS=no
[ -f /var/lib/s15-luks/reseal.key ] && [ "$(findmnt -no SOURCE /)" = /dev/mapper/root ] && LUKS=yes

kernel_fixes() {  # the S15 kernel patches 0012 (EFI stub) and 0013 (efivarfs) in the installed kernel and module
  local kv k mod ok=0
  kv=$(ls /usr/lib/modules | grep -E -- '-s15\+?$' | sort -V | tail -1)
  k=/boot/vmlinuz-$kv
  if grep -qa 'Ignoring the initrd named by the devicetree' "$k"; then echo "  $k: devicetree initrd fix (0012)"
  else echo "  $k: devicetree initrd fix (kernel/patches/0012) MISSING"; ok=1; fi
  mod=$(modinfo -k "$kv" -n efivarfs 2>/dev/null || true)
  if [ -n "$mod" ] && python3 - "$mod" <<'EOF'
import gzip, lzma, subprocess, sys
p = sys.argv[1]
d = open(p, "rb").read()
if p.endswith(".xz"):
    d = lzma.decompress(d)
elif p.endswith(".gz"):
    d = gzip.decompress(d)
elif p.endswith(".zst"):
    d = subprocess.run(["zstd", "-dc", p], capture_output=True, check=True).stdout
sys.exit(0 if "SystemdOptions".encode("utf-16-le") in d else 1)
EOF
  then echo "  $mod: SystemdOptions fix (0013)"
  else echo "  efivarfs module ${mod:-?}: SystemdOptions fix (kernel/patches/0013) MISSING"; ok=1; fi
  return $ok
}

harden_boot() {
  local uuid M f
  uuid=$(sed -n 's/^uuid=//p' /var/lib/s15-luks/info)
  [ -n "$uuid" ] || die "no uuid in /var/lib/s15-luks/info"
  M=$(mktemp -d); mount /dev/disk/by-partlabel/S15BOOT "$M"; trap 'umount "$M"; rmdir "$M"' EXIT
  for f in "$M"/loader/entries/*.conf; do
    grep -q "^options.*rd.luks.name=$uuid=" "$f" || continue
    grep -q "rd.luks.options=$uuid=[^ ]*tpm2-measure-pcr=yes" "$f" ||
      sed -i "s#\(rd.luks.options=$uuid=[^ ]*\)#\1,tpm2-measure-pcr=yes#" "$f"
    grep -q '^options.* systemd.gpt_auto=0' "$f" || sed -i 's/^options .*/& systemd.gpt_auto=0/' "$f"
    echo "  $(basename "$f"): $(grep -o 'rd.luks.options=[^ ]*' "$f") systemd.gpt_auto=0"
  done
  sync; umount "$M"; rmdir "$M"; trap - EXIT
  install -m 0755 "$HERE/s15-luks-reseal" /usr/local/sbin/s15-luks-reseal
  /usr/local/sbin/s15-luks-reseal
}

layout() {  # the login screen's keyboard layout (systemd-localed, read by KWin) from the Plasma desktop's
  local cur k l v
  cur=$(localectl status | sed -n 's/^ *X11 Layout: *//p')
  if [ -n "$cur" ] && [ "$cur" != "(unset)" ]; then echo "  login screen keyboard layout: $cur"; return; fi
  k=/home/$U/.config/kxkbrc
  l=$(sed -n 's/^LayoutList=//p' "$k" 2>/dev/null | head -1); v=$(sed -n 's/^VariantList=//p' "$k" 2>/dev/null | head -1)
  if [ -z "$l" ]; then echo "  login screen keyboard layout: us (the Plasma desktop has no layout set)"; return; fi
  # --no-convert: the console keymap (/etc/vconsole.conf, also used for the disk passphrase) stays as it is
  if [ -n "${v//,/}" ]; then localectl set-x11-keymap --no-convert "$l" pc105 "$v"
  else localectl set-x11-keymap --no-convert "$l" pc105; fi
  echo "  login screen keyboard layout: $l (from the Plasma desktop)"
}

install_login() {  # $1: root directory, "" for the running system
  local R=$1
  install -D -m 0755 "$HERE/s15-login-gate" "$R/usr/local/sbin/s15-login-gate"
  install -m 0644 "$HERE/s15-login-gate.path" "$HERE/s15-login-gate.service" "$R/etc/systemd/system/"
  install -d "$R/etc/systemd/system/paths.target.wants"
  ln -sfn ../s15-login-gate.path "$R/etc/systemd/system/paths.target.wants/s15-login-gate.path"
  # login PIN: the check service and the PAM lines; without a PIN set (s15-pin set) they change nothing
  install -D -m 0755 "$HERE/s15-pin" "$R/usr/local/sbin/s15-pin"
  install -m 0644 "$HERE/s15-pin.socket" "$HERE/s15-pin@.service" "$R/etc/systemd/system/"
  install -d "$R/etc/systemd/system/sockets.target.wants"
  ln -sfn ../s15-pin.socket "$R/etc/systemd/system/sockets.target.wants/s15-pin.socket"
  # Plasma's lock screen: SteamOS 0.5.3 has /etc/pam.d/kde, 0.5.7 only /usr/lib/pam.d/kde
  [ -f "$R/etc/pam.d/kde" ] || install -m 0644 "$R/usr/lib/pam.d/kde" "$R/etc/pam.d/kde"
  for f in "$R/etc/pam.d/sddm" "$R/etc/pam.d/kde"; do
    grep -q 's15-pin pam$' "$f" || sed -i "0,/^auth/s#^auth#$PIN_AUTH\n&#" "$f"
    grep -q 's15-pin pam$' "$f" || die "$f not changed"
  done
  grep -q 's15-pin pam-reset' "$R/etc/pam.d/sddm" || sed -i "/^account .*include/a $PIN_ACCT" "$R/etc/pam.d/sddm"
  grep -q 's15-pin pam-reset' "$R/etc/pam.d/sddm" || die "$R/etc/pam.d/sddm: account line not added"
  grep -q 's15-login-gate check' "$R$PAMF" || sed -i "0,/^auth/s#^auth#$PAM_LINE\n&#" "$R$PAMF"
  grep -q 's15-login-gate check' "$R$PAMF" || die "$R$PAMF not changed"
  # SteamOS sets DisplayServer=wayland but leaves the login screen's compositor at SDDM's default, weston, which it
  # does not ship. KWin as in Plasma's own SDDM setup.
  install -d "$R/etc/sddm.conf.d"
  printf '%s\n' '# docs/login.md: the login screen runs in KWin (SDDM default weston is not installed)' '[General]' \
    'GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell' '' '[Wayland]' \
    'CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1' > "$R$GREETER"
  [ -f "$R$KSL.s15-orig" ] || cp -a "$R$KSL" "$R$KSL.s15-orig" 2>/dev/null || : > "$R$KSL.s15-orig"
  printf '[Daemon]\nAutolock=true\nLockOnResume=true\n' > "$R$KSL"
  # No PipeWire/WirePlumber for the login screen's user. Otherwise two audio stacks hold the sound card for the ~10 s
  # between a login and the end of the greeter's user session, and the greeter's teardown left the speaker
  # amplifiers (WSA884x on SoundWire) in a state where they dropped off the bus at the next mode switch ("SWR bus
  # clsh detected", no speaker sound until a restart). With the automatic login there was only one stack.
  for u in $GREETER_AUDIO; do
    install -d "$R/etc/systemd/user/$u.d"
    printf '[Unit]\n# docs/login.md: no audio for the login screen\nConditionUser=!sddm\n' > "$R/etc/systemd/user/$u.d/s15-no-greeter.conf"
  done
  # SteamOS forbids locking the session on demand (kiosk restriction action/lock_screen=false in an immutable [$i]
  # group, so a user setting cannot lift it): no Meta+L and no "Lock" entry. With a password it is allowed.
  [ ! -f "$R$KG" ] || sed -i 's#^action/lock_screen=false$#action/lock_screen=true#' "$R$KG"
  install -d -m 0755 "$R/var/lib/faillock"
  # polkit's password helper (polkit-agent-helper@.service) runs with ProtectSystem=strict: pam_faillock cannot write
  # its tally file there, "Error opening the tally file: Read-only file system", and every password in a polkit
  # dialog (Plasma's settings) fails with "System error" once the file exists
  install -d "$R/etc/systemd/system/polkit-agent-helper@.service.d"
  printf '[Service]\n# docs/login.md: pam_faillock keeps its tally files here\nReadWritePaths=-/var/lib/faillock -/run/faillock\n' \
    > "$R/etc/systemd/system/polkit-agent-helper@.service.d/s15-faillock.conf"
  sed -i "\%^$FL_BEGIN\$%,\%^$FL_END\$%d" "$R$FL"
  printf '%s\n' "$FL_BEGIN" 'deny = 10' 'unlock_time = 600' 'dir = /var/lib/faillock' "$FL_END" >> "$R$FL"
}

apply_root() {
  local R=${1:?root directory}
  [ -d "$R/etc" ] && [ "$(realpath "$R")" != / ] || die "$R is not another SteamOS root"
  grep -q '^ID=steamos' "$R/etc/os-release" || die "$R is not SteamOS"
  install_login "$R"
  echo "login gate, login screen, screen lock, PIN check and failed-password lockout in $R"
}

enable() {
  local st
  st=$(passwd -S "$U" | awk '{print $2}')
  [ "$st" = P ] || die "$U has no usable password (passwd -S: $st). Set one first: passwd (as $U, e.g. in Konsole)"
  for t in kwin_wayland sddm-greeter-qt6; do command -v $t >/dev/null || die "$t missing (login screen)"; done
  [ -d /usr/share/sddm/themes/breeze ] || die "SDDM theme breeze missing"
  if [ "$LUKS" = yes ]; then
    echo "== kernel"
    kernel_fixes || die "build and install a kernel with these patches first (docs/kernel.md, steamos/install-kernel.sh)"
    echo "== boot entries and TPM (docs/encryption.md)"
    harden_boot
  else
    echo "== the SteamOS partition is not encrypted: anyone can read it with another system (docs/encryption.md)"
  fi
  echo "== login screen, screen lock, failed passwords"
  install_login ""
  systemctl daemon-reload
  systemctl restart s15-login-gate.path
  systemctl start s15-pin.socket
  layout
  [ -f "/home/$U/.config/kscreenlockerrc" ] && echo "  note: /home/$U/.config/kscreenlockerrc overrides the screen lock (System Settings)"
  echo "  Desktop Mode locks on suspend, after 5 minutes without input and with Meta+L (from the next login)"
  echo "  10 wrong passwords within 15 minutes lock $U for 10 minutes (faillock --user $U --reset unlocks)"
  echo
  echo "Done. The login screen appears at the next boot or logout; switching modes logs in without it."
  echo "Game Mode has its own lock: Steam > Settings > Security > Lock screen, 'Waking from sleep' (docs/login.md)."
}

disable() {
  sed -i '/s15-login-gate check/d' "$PAMF"
  systemctl disable --now s15-login-gate.path 2>/dev/null || true
  sed -i '/s15-pin pam/d' /etc/pam.d/sddm /etc/pam.d/kde 2>/dev/null || true
  for u in $GREETER_AUDIO; do rm -f "/etc/systemd/user/$u.d/s15-no-greeter.conf"; rmdir "/etc/systemd/user/$u.d" 2>/dev/null || true; done
  systemctl disable --now s15-pin.socket 2>/dev/null || true
  rm -f /run/s15-login/switch
  if [ -f "$KSL.s15-orig" ]; then
    if [ -s "$KSL.s15-orig" ]; then mv -f "$KSL.s15-orig" "$KSL"; else rm -f "$KSL" "$KSL.s15-orig"; fi
  fi
  sed -i "\%^$FL_BEGIN\$%,\%^$FL_END\$%d" "$FL"
  rm -f /etc/systemd/system/polkit-agent-helper@.service.d/s15-faillock.conf
  [ ! -f "$KG" ] || sed -i 's#^action/lock_screen=true$#action/lock_screen=false#' "$KG"
  echo "automatic login, screen lock and password settings as SteamOS has them again (login screen compositor kept)"
}

status() {
  echo "user: $U, password: $(passwd -S "$U" | awk '{print $2}') (P = set, NP = none)"
  /usr/local/sbin/s15-login-gate status 2>/dev/null || echo "gate: not installed"
  echo "switch watcher: $(systemctl is-enabled s15-login-gate.path 2>/dev/null || echo not installed)"
  echo "login screen compositor: $(sed -n 's/^CompositorCommand=//p' "$GREETER" 2>/dev/null || echo 'SDDM default (weston, missing)')"
  echo "screen lock: $(grep -E '^(Autolock|LockOnResume)=' "$KSL" 2>/dev/null | tr '\n' ' ')$(grep -h '^action/lock_screen=' "$KG" 2>/dev/null)"
  echo "faillock: $(grep -E '^(deny|unlock_time|dir) *=' "$FL" | tr -s ' ' | tr '\n' ' ')"
  echo "PIN: $(grep -c 's15-pin pam$' /etc/pam.d/sddm /etc/pam.d/kde 2>/dev/null | tr '\n' ' ')socket $(systemctl is-active s15-pin.socket 2>/dev/null); $(/usr/local/sbin/s15-pin status "$U" 2>&1)"
  echo "encrypted: $LUKS"
  if [ "$LUKS" = yes ]; then
    kernel_fixes || true
    echo "boot command line: $(grep -o 'rd.luks.options=[^ ]*\|systemd.gpt_auto=[^ ]*' /proc/cmdline | tr '\n' ' ')"
    /usr/local/sbin/s15-luks-reseal --dry-run 2>&1 | sed 's/^/  /'
  fi
}

case "${1:-}" in
  enable) enable ;; disable) disable ;; status) status ;; apply-root) apply_root "${2:-}" ;;
  *) echo "usage: $0 enable|disable|status|apply-root <dir>"; exit 2 ;;
esac
