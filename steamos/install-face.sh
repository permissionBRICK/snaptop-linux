#!/bin/bash
# Face unlock with Biopass (docs/login.md#face-unlock): Biopass's arm64 release for the app, with its auth part
# (helper, PAM module, libraries, libcamera) built on the laptop with our patches for the IR camera (face/build.sh),
# and the PAM lines through login-lock.sh. Run as root in the installed SteamOS, from a checkout of this repository:
#   sudo steamos/install-face.sh install [--rebuild]  install or update (idempotent). Face unlock works once the
#                                                     login password is on (login-lock.sh enable), from the next login
#   sudo steamos/install-face.sh status
#   sudo steamos/install-face.sh uninstall            PAM files as before; enrolled faces stay with the user
#   sudo steamos/install-face.sh admin on|off         also for sudo and polkit dialogs (off by default, see the docs)
#   steamos/install-face.sh apply-root <dir>          (s15-os-update) into a new SteamOS version before its first boot
# Packages only from the image's own repository (pacman -S --needed, no system upgrade): the app's webkit2gtk-4.1.
# The build (about 10 minutes) is kept in /var/lib/s15-face/cache and reused while face/ is unchanged.
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
DEPS="webkit2gtk-4.1"            # the app; the rest Biopass needs is in the image (not fprintd: no fingerprints)
ID=$(face_build_id)

# The patched build for root $1: from the cache, else built against $1 in a chroot (overlay on a tmpfs).
build() {
  local R=${1:-/} pkg=$CACHE/s15-face-$ID.tar.zst w
  if [ -f "$pkg" ] && [ "${REBUILD:-0}" != 1 ]; then echo "$pkg"; return; fi
  w=$(mktemp -d /var/tmp/s15-face-build.XXXXXX)
  mount -t tmpfs -o size=6G tmpfs "$w"
  # shellcheck disable=SC2064  # $w expanded now: it is local
  trap "umount -R '$w' 2>/dev/null; rmdir '$w'" EXIT
  echo "building Biopass's auth part with our patches (about 10 minutes)..." >&2
  bash "$REPO/face/build.sh" "$R" "$w" > "$w.log" 2>&1 ||
    { tail -30 "$w.log" >&2; die "face build failed (log: $w.log)"; }
  grep -E '^  |==' "$w.log" | grep -E 'tests|needs|passed|ALL' >&2 || true
  install -d -m0700 "$CACHE"
  rm -f "$CACHE"/s15-face-*.tar.zst
  cp "$w/s15-face-$ID.tar.zst" "$pkg"
  umount -R "$w"; rmdir "$w"; rm -f "$w.log"; trap - EXIT
  echo "$pkg"
}

deb() {
  local d=$CACHE/$BIOPASS_DEB
  install -d -m0700 "$CACHE"
  if ! { [ -f "$d" ] && echo "$BIOPASS_DEB_SHA256  $d" | sha256sum -c --quiet 2>/dev/null; }; then
    curl -fsSL --retry 3 -o "$d.part" "$BIOPASS_DEB_URL"
    echo "$BIOPASS_DEB_SHA256  $d.part" | sha256sum -c --quiet || die "$BIOPASS_DEB: checksum mismatch"
    mv -f "$d.part" "$d"
  fi
  echo "$d"
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

# Biopass into root $1: the app and its assets from the release, everything the app runs (biopass-helper and below)
# from our build. Only usr/ is unpacked (the release's lib/security goes to usr/lib/security: /lib is a link).
put() {
  local R=$1 d pkg s
  d=$(deb); pkg=$(build "${R:-/}")
  s=$(mktemp -d /var/tmp/s15-face-stage.XXXXXX)
  mkdir -p "$s/deb" "$s/root"
  (cd "$s/deb" && bsdtar -xf "$d" && tar -xf data.tar.*)
  for f in usr/bin/biopass usr/share/applications/biopass.desktop \
           usr/share/polkit-1/actions/com.ticklab.biopass.policy; do
    install -D -m"$(stat -c %a "$s/deb/$f")" "$s/deb/$f" "$s/root/$f"
  done
  (cd "$s/deb" && find usr/share/icons -name biopass.png -exec install -D -m0644 {} "$s/root/{}" \;)
  zstd -dc "$pkg" | tar -xf - -C "$s/root"
  remove_files "$R"
  (cd "$s/root" && find . \( -type f -o -type l \) | sed 's#^\.##') > "$s/files"
  tar -C "$s/root" --owner=0 --group=0 -cf - usr | tar -C "$R/" -xpf - --no-overwrite-dir
  install -D -m0755 "$HERE/s15-face" "$R/usr/local/sbin/s15-face"
  install -d -m0700 "$R$STATE"
  { cat "$s/files"; echo /usr/local/sbin/s15-face; } > "$R$STATE/files"
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

install_() {
  echo "== packages from the image's repository: $DEPS"
  pacman_deps ""
  echo "== Biopass $BIOPASS_VERSION (app from the release, auth part built here: $ID)"
  put ""
  echo "  $(wc -l < "$STATE/files") files (list: $STATE/files)"
  echo "== PAM (login-lock.sh)"
  bash "$HERE/login-lock.sh" face-pam
  cat <<EOF

Done. Next (docs/login.md#face-unlock):
  1. Open "Biopass" from the application menu, let it download its models, and add your face (Face > enrol).
  2. Recommended for this laptop, IR camera only (works in the dark): close the app, then
       sudo s15-face camera ir      (s15-face camera rgb: colour camera with an IR presence check)
     and enrol again in the app.
  3. Log out or restart once: the first login after a boot always takes the password or the PIN.
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
  remove_files ""
  rm -f /usr/local/sbin/s15-face
  rm -rf "$STATE"
  echo "Biopass removed; PAM files as before. Kept: webkit2gtk-4.1 (pacman -Rs webkit2gtk-4.1 removes it), and"
  echo "each user's enrolled faces and settings in ~/.local/share/com.ticklab.biopass and ~/.config/com.ticklab.biopass."
}

status() {
  if [ -f "$STATE/build" ]; then
    echo "installed: $(cat "$STATE/build") (this checkout: $ID)$([ -f "$STATE/admin" ] && echo ', sudo/polkit on')"
    local missing=0
    while read -r f; do [ -e "$f" ] || { echo "  missing $f"; missing=1; }; done < "$STATE/files"
    [ $missing = 0 ] && echo "  all $(wc -l < "$STATE/files") files present"
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
