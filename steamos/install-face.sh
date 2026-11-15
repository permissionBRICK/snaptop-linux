#!/bin/bash
# Face unlock with Biopass (docs/login.md#face-unlock): Biopass built on the laptop with our patches (face/build.sh):
# its auth part (helper, libraries, libcamera) for the IR camera and its app, which sets face unlock up (cameras,
# faces, test scans, the lockout through pkexec s15-face-lockout and its polkit action); s15-face and s15-face-run
# (gate and runs), s15-face.socket (root's count of false faces, for the lock screen's runs
# that run as the user), s15-face-wake.service (starts face on the lock screen by itself), and the PAM lines
# through login-lock.sh. The count (/var/lib/s15-face/lockout) and the lockout numbers (root's /etc/s15-face.conf,
# s15-face lockout) stay across restarts and SteamOS updates. Run as root in the installed SteamOS, from a checkout of this repository:
#   sudo steamos/install-face.sh install [--rebuild]  install or update (idempotent). Face unlock works once the
#                                                     login password is on (login-lock.sh enable), from the next login
#   sudo steamos/install-face.sh status
#   sudo steamos/install-face.sh uninstall            PAM files as before; enrolled faces stay with the user
#   sudo steamos/install-face.sh admin on|off         also for sudo and polkit dialogs (off by default, see the docs)
#   steamos/install-face.sh apply-root <dir>          (s15-os-update) into a new SteamOS version before its first boot
# Packages only from the image's own repository (pacman -S --needed, no system upgrade): the app's webkit2gtk-4.1.
# The build (about 10 minutes; Rust and Node.js only in its overlay) is kept in /var/lib/s15-face/cache with its
# downloads, and reused while face/ is unchanged.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ "$(uname -m)" = aarch64 ] || die "needs ARM64"
grep -q '^ID=steamos' /etc/os-release || die "not SteamOS"
model=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || true)
case $model in *"Vivobook S 15"*|*S5507Q*) ;; *) die "not the Vivobook S15 (model: $model)";; esac
# shellcheck source=face/sources.sh
. "$REPO/face/sources.sh"
STATE=/var/lib/s15-face          # build id (= installed), file list, admin flag, cache; root only
CACHE=$STATE/cache
WAKE=/etc/systemd/system/s15-face-wake.service
WAKE_LINK=/etc/systemd/system/multi-user.target.wants/s15-face-wake.service
SOCK_UNITS="/etc/systemd/system/s15-face.socket /etc/systemd/system/s15-face@.service"
SOCK_LINK=/etc/systemd/system/sockets.target.wants/s15-face.socket
KEEP=/etc/atomic-update.conf.d/s15-face.conf   # s15-os-update carries these /etc files into a new version
DEPS="webkit2gtk-4.1"            # the app; the rest Biopass needs is in the image (not fprintd: no fingerprints)
ID=$(face_build_id)

# The patched build for root $1: from the cache, else built against $1 in a chroot (an overlay with its upper layer in
# a work directory under /var/tmp, about 4 GB while it runs; build.sh keeps its mounts in a mount namespace of its
# own, so none stays behind). Downloads are kept in the cache (their checksums are checked on every use).
build() {
  local R=${1:-/} pkg=$CACHE/s15-face-$ID.tar.zst w
  if [ -f "$pkg" ] && [ "${REBUILD:-0}" != 1 ]; then echo "$pkg"; return; fi
  w=$(mktemp -d /var/tmp/s15-face-build.XXXXXX)
  install -d -m0700 "$CACHE" "$CACHE/src"
  echo "building Biopass and its app with our patches (about 10 minutes)..." >&2
  if ! S15_FACE_SRC=$CACHE/src bash "$REPO/face/build.sh" "$R" "$w" > "$w.log" 2>&1 ||
     ! cp "$w/s15-face-$ID.tar.zst" "$pkg.new"; then
    tail -30 "$w.log" >&2; rm -rf "$w"; die "face build failed (log: $w.log)"
  fi
  grep -E '^  |==' "$w.log" | grep -E 'tests|needs|pass|ALL' >&2 || true
  rm -f "$CACHE"/s15-face-*.tar.zst "$CACHE"/biopass_*.deb
  mv "$pkg.new" "$pkg"
  rm -rf "$w"; rm -f "$w.log"
  echo "$pkg"
}

remove_files() {  # $1: root
  local R=$1 f
  [ -f "$R$STATE/files" ] || return 0
  while read -r f; do
    case $f in /usr/*) rm -f "$R$f" ;; esac
  done < "$R$STATE/files"
  rm -rf "$R/usr/lib/biopass" "$R/usr/share/biopass" "$R/usr/libexec/biopass" "$R/usr/lib/s15-face"
  rm -f "$R$STATE/files"
}

# Biopass into root $1, all from our build (the app with its menu entry, icons and polkit policy, the auth part), with
# the lockout tool the app runs through pkexec and its polkit action.
put() {
  local R=$1 pkg s pol
  pkg=$(build "${R:-/}")
  s=$(mktemp -d /var/tmp/s15-face-stage.XXXXXX)
  mkdir -p "$s/root"
  zstd -dc "$pkg" | tar -xf - -C "$s/root"
  # WebKitGTK's DMA-BUF renderer ends the app at once on this GPU under Wayland ("Error 71 (Protocol error)").
  grep -q '^Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 biopass$' "$s/root/usr/share/applications/biopass.desktop" ||
    die "biopass.desktop: unexpected Exec line"
  install -D -m0755 "$HERE/s15-face-lockout" "$s/root/usr/lib/s15-face/s15-face-lockout"
  install -D -m0644 "$HERE/org.snaptop-linux.s15-face.policy" \
    "$s/root/usr/share/polkit-1/actions/org.snaptop-linux.s15-face.policy"
  remove_files "$R"
  (cd "$s/root" && find . \( -type f -o -type l \) | sed 's#^\.##') > "$s/files"
  # polkit re-reads all its actions as soon as a .policy file appears; reading one that tar was still writing left it
  # with none (every time). The policy files therefore come last and complete, each renamed into place.
  tar -C "$s/root" --owner=0 --group=0 --exclude='usr/share/polkit-1/actions/*.policy' -cf - usr |
    tar -C "$R/" -xpf - --no-overwrite-dir
  install -d "$R/usr/share/polkit-1/actions"
  for pol in "$s/root"/usr/share/polkit-1/actions/*.policy; do
    pol=usr/share/polkit-1/actions/${pol##*/}
    install -m0644 "$s/root/$pol" "$R/${pol%/*}/.${pol##*/}.new"
    mv -f "$R/${pol%/*}/.${pol##*/}.new" "$R/$pol"
  done
  # A build from the cache links the libraries of the version it was built for; one this version lacks: build again.
  local missing
  missing=$(chroot "${R:-/}" /bin/sh -c 'for f in /usr/bin/biopass /usr/bin/biopass-helper /usr/lib/security/libbiopass_pam.so \
    /usr/libexec/biopass/biopass-keyring /usr/lib/biopass/*.so* /usr/lib/biopass/libcamera/*/*.so \
    /usr/lib/biopass/libcamera/softisp_ipa_proxy; do ldd "$f"; done' 2>&1 | grep 'not found' | sort -u || true)
  if [ -n "$missing" ]; then
    rm -rf "$s"
    [ "${REBUILD:-0}" != 1 ] || die "libraries missing in ${R:-/}: $missing"
    echo "libraries missing in ${R:-/} ($(echo "$missing" | awk '{print $1}' | tr '\n' ' ')): building again" >&2
    REBUILD=1 put "$R"; return
  fi
  install -D -m0755 "$HERE/s15-face" "$R/usr/local/sbin/s15-face"
  install -D -m0755 "$HERE/s15-face-run" "$R/usr/local/sbin/s15-face-run"
  install -D -m0644 "$HERE/s15-face-wake.service" "$R$WAKE"
  install -d "$R${WAKE_LINK%/*}" "$R${SOCK_LINK%/*}"
  ln -sfn "$WAKE" "$R$WAKE_LINK"
  install -m0644 "$HERE/s15-face.socket" "$HERE/s15-face@.service" "$R/etc/systemd/system/"
  ln -sfn /etc/systemd/system/s15-face.socket "$R$SOCK_LINK"
  install -d "$R${KEEP%/*}"
  printf '%s\n' '# snaptop-linux face unlock (steamos/install-face.sh): the lockout numbers (s15-face lockout)' \
    /etc/s15-face.conf > "$R$KEEP"
  install -d -m0700 "$R$STATE"
  { cat "$s/files"; echo /usr/local/sbin/s15-face; echo /usr/local/sbin/s15-face-run; } > "$R$STATE/files"
  echo "$ID" > "$R$STATE/build"
  rm -rf "$s"
}

pacman_deps() {  # $1: root ("" = running system)
  local R=$1
  if [ -z "$R" ]; then pacman -S --needed --noconfirm $DEPS >/dev/null; return; fi
  local m ok=1
  for m in proc sys dev run; do
    mountpoint -q "$R/$m" || { mount --rbind "/$m" "$R/$m"; mount --make-rslave "$R/$m"; }
  done
  # shellcheck disable=SC2086
  chroot "$R" pacman -S --needed --noconfirm $DEPS >/dev/null || ok=0
  for m in run dev sys proc; do umount -R -l "$R/$m"; done
  [ $ok = 1 ] || die "pacman -S $DEPS in $R failed"
}

# polkit re-reads its actions when /usr/share/polkit-1/actions changes. When it read the policy file half-written
# (put() now avoids that), it was left with none: Plasma then hid shutdown and sleep and ignored the lid and the
# power button. If that happens anyway, restart it and the Plasma parts that asked it.
polkit_check() {
  local n u
  n=$(pkaction 2>/dev/null | wc -l)
  [ "$n" -ge 50 ] && return 0
  echo "polkit lists $n actions: restarting it and Plasma's polkit agent and power management" >&2
  systemctl restart polkit
  for u in $(loginctl list-users --no-legend | awk '{print $2}'); do
    systemctl --user -M "$u@" try-restart plasma-polkit-agent.service plasma-powerdevil.service 2>/dev/null || true
  done
}

install_() {
  echo "== packages from the image's repository: $DEPS"
  pacman_deps ""
  echo "== Biopass $BIOPASS_VERSION with our patches, built here ($ID)"
  put ""
  echo "  $(wc -l < "$STATE/files") files (list: $STATE/files)"
  echo "== PAM (login-lock.sh)"
  bash "$HERE/login-lock.sh" face-pam
  systemctl daemon-reload
  systemctl restart s15-face.socket s15-face-wake.service
  echo "  s15-face.socket: $(systemctl is-active s15-face.socket) (the count of false faces)"
  echo "  s15-face-wake: $(systemctl is-active s15-face-wake.service) (starts face unlock on the lock screen)"
  polkit_check
  cat <<EOF

Done. Next, in the Biopass app (application menu; docs/login.md#face-unlock):
  1. It downloads its models when it first starts (AI Models).
  2. Configuration > Face Recognition > Cameras: IR camera (recommended), or both cameras; Save.
  3. Enrolled faces: Start camera, Add 5 (sit as you usually do; with and without glasses).
  4. Test: one scan with each step and each face's score; replace faces that score low.
  5. Lock the screen (Meta+L): face unlock starts by itself; at the login screen press Enter on the empty field.
The same from a terminal: sudo s15-face camera ir; s15-face enrol; s15-face check (s15-face for the rest).
EOF
}

apply_root() {
  local R=${1:?root directory}
  [ -d "$R/etc" ] && [ "$(realpath "$R")" != / ] || die "$R is not another SteamOS root"
  grep -q '^ID=steamos' "$R/etc/os-release" || die "$R is not SteamOS"
  pacman_deps "$R"
  put "$R"
  [ -f "$STATE/admin" ] && touch "$R$STATE/admin"
  echo "face unlock (Biopass $ID) in $R"
}

uninstall() {
  rm -f "$STATE/build" "$STATE/admin"
  bash "$HERE/login-lock.sh" face-pam
  systemctl disable --now s15-face-wake.service s15-face.socket 2>/dev/null || true
  # shellcheck disable=SC2086
  rm -f "$WAKE_LINK" "$WAKE" "$SOCK_LINK" $SOCK_UNITS "$KEEP" /etc/s15-face.conf /run/s15-face.sock
  rm -rf /run/s15-face
  systemctl daemon-reload
  remove_files ""
  rm -f /usr/local/sbin/s15-face /usr/local/sbin/s15-face-run
  rm -rf "$STATE"
  polkit_check
  echo "Biopass removed; PAM files as before. Kept: webkit2gtk-4.1 (pacman -Rs webkit2gtk-4.1 removes it), and"
  echo "each user's enrolled faces and settings in ~/.local/share/com.ticklab.biopass and ~/.config/com.ticklab.biopass."
}

status() {
  if [ -f "$STATE/build" ]; then
    echo "installed: $(cat "$STATE/build") (this checkout: $ID)$([ -f "$STATE/admin" ] && echo ', sudo/polkit on')"
    local missing=0
    while read -r f; do [ -e "$f" ] || { echo "  missing $f"; missing=1; }; done < "$STATE/files"
    [ $missing = 0 ] && echo "  all $(wc -l < "$STATE/files") files present"
    echo "  s15-face.socket: $(systemctl is-active s15-face.socket 2>/dev/null)," \
      "s15-face-wake: $(systemctl is-active s15-face-wake.service 2>/dev/null)"
    echo "  lockout (s15-face lockout): $(/usr/local/sbin/s15-face lockout | tr '\n' ' ')"
  else
    echo "not installed"
  fi
  bash "$HERE/login-lock.sh" status | grep -A20 '^face unlock' || true
}

admin() {
  [ -f "$STATE/build" ] || die "not installed"
  case ${1:-} in
    on) touch "$STATE/admin" ;;
    off) rm -f "$STATE/admin" ;;
    *) die "usage: $0 admin on|off" ;;
  esac
  bash "$HERE/login-lock.sh" face-pam
  [ "$1" = off ] && return
  cat <<'EOF'
sudo and polkit dialogs now try your face first. Read docs/login.md#face-unlock first: any program running as you can
change your Biopass settings (threshold, enrolled faces), so this makes sudo about as strong as having no sudo password.
For polkit dialogs, also remove "polkit-1" and "pkexec" from Biopass's ignored services (app > Strategy).
EOF
}

case "${1:-}" in
  install) [ "${2:-}" = --rebuild ] && REBUILD=1; install_ ;;
  apply-root) apply_root "${2:-}" ;;
  uninstall) uninstall ;;
  status) status ;;
  admin) admin "${2:-}" ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac
