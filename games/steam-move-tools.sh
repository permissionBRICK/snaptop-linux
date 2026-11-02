#!/bin/bash
# Move the Linux-only Steam tools (FEX, Proton ARM64, Steam Linux Runtimes, Steamworks Shared) that Steam installed
# into a library on an NTFS game drive back to the internal library. On ntfs3 they run slowly and symlinks/
# permissions are fragile. Copies are verified file by file (sha256 + symlink targets) before the original goes.
# Usage (root, on the laptop): GAME_DRIVE_LABEL=<label> steam-move-tools.sh
set -euo pipefail
U=steamos; X=/run/user/$(id -u $U)
S=/home/steamos/.local/share/Steam; A=/run/media/steamos/${GAME_DRIVE_LABEL:?set GAME_DRIVE_LABEL}/SteamLibrary/steamapps
asu() { sudo -u $U XDG_RUNTIME_DIR=$X DBUS_SESSION_BUS_ADDRESS=unix:path=$X/bus "$@"; }

asu systemctl --user stop steam.service || true
for i in $(seq 1 40); do pgrep -u $U -x steam >/dev/null || break; sleep 1; done
pgrep -u $U -x steam >/dev/null && { echo "Steam still running - abort"; exit 1; }
echo "steam stopped"

manifest() {  # sorted list: type, path, sha256 or symlink target
  (cd "$1" && find . \( -type f -o -type l \) -print0 | sort -z | while IFS= read -r -d '' f; do
     if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")"; else printf 'F %s %s\n' "$f" "$(sha256sum < "$f" | cut -c1-64)"; fi
   done)
}
declare -A TOOLS=( [3127680]="FEX-Emu" [1070560]="SteamLinuxRuntime" [1391110]="SteamLinuxRuntime_soldier"
                   [4185400]="SteamLinuxRuntime_4-arm64" [4628740]="Proton 11.0 (ARM64)" [228980]="Steamworks Shared" )
for id in "${!TOOLS[@]}"; do
  d=${TOOLS[$id]}
  [ -d "$A/common/$d" ] || { echo "skip $d (not on the drive)"; continue; }
  [ -e "$S/steamapps/common/$d" ] && { echo "skip $d (already internal)"; continue; }
  asu mkdir -p "$S/steamapps/common"
  asu cp -a "$A/common/$d" "$S/steamapps/common/"
  if [ "$(manifest "$A/common/$d" | sha256sum)" = "$(manifest "$S/steamapps/common/$d" | sha256sum)" ]; then
    rm -rf "$A/common/$d"; mv "$A/appmanifest_$id.acf" "$S/steamapps/"; chown $U:$U "$S/steamapps/appmanifest_$id.acf"
    echo "moved $d (all file checksums and symlink targets identical)"
  else
    echo "DIFFERENT $d - original kept"; diff <(manifest "$A/common/$d") <(manifest "$S/steamapps/common/$d") | head -6
    asu rm -rf "$S/steamapps/common/$d"
  fi
done
echo "== Proton tool names known to this Steam client:"
grep -a -o -E "proton_[0-9a-z_-]+arm64" $S/appcache/appinfo.vdf 2>/dev/null | sort -u | head -8 || true
asu systemctl --user start steam.service && echo "steam started"
