#!/bin/bash
# Add old Windows games from a game drive as non-Steam shortcuts that run with Proton 11 (ARM64), each with its own
# Proton prefix cloned (reflink) from a TEMPLATE prefix that already works (DSOAL + d3dx9_30, see docs/games.md).
# Usage (root, on the laptop, Steam is stopped and stays stopped until the next reboot or `systemctl --user start steam`):
#   GAME_DRIVE_LABEL=<label> TEMPLATE_APPID=<compatdata id> add-games.sh <games.tsv>
# games.tsv: one game per line, tab separated: name, exe path relative to the drive, launch options, d3dx9 version
# (both optional). See games.example.tsv.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); LIST=$(realpath "${1:?games.tsv}")
U=steamos; X=/run/user/$(id -u $U); S=/home/steamos/.local/share/Steam; C=$S/steamapps/compatdata
E=/run/media/steamos/${GAME_DRIVE_LABEL:?set GAME_DRIVE_LABEL to the drive label}
TEMPLATE=${TEMPLATE_APPID:?set TEMPLATE_APPID to a working prefix (compatdata id)}
[ -d "$C/$TEMPLATE/pfx" ] || { echo "no prefix $C/$TEMPLATE"; exit 1; }
UD=$(ls -dt $S/userdata/*/ | head -1); UD=${UD%/}
asu() { sudo -u $U XDG_RUNTIME_DIR=$X DBUS_SESSION_BUS_ADDRESS=unix:path=$X/bus "$@"; }
pgrep -u $U -f "compatdata/[0-9]+/pfx" >/dev/null && { echo "a Proton game is running - abort"; exit 1; }
asu systemctl --user stop steam.service || true
for i in $(seq 1 40); do pgrep -u $U -x steam >/dev/null || break; sleep 1; done
pgrep -u $U -x steam >/dev/null && { echo "Steam still running - abort"; exit 1; }
echo "steam stopped"
while IFS=$'\t' read -r name exe opts dx; do
  case $name in ''|'#'*) continue;; esac
  [ -f "$E/$exe" ] || { echo "skip $name: $E/$exe not found"; continue; }
  if [ "$dx" = auto ]; then  # the d3dx9 version a renderer DLL next to the exe links against
    dx=$(strings -n 5 "$(dirname "$E/$exe")"/Rend*.dll 2>/dev/null | grep -i -o -E "^d3dx9_[0-9]+\.dll" | head -1 | tr A-Z a-z | tr -dc 0-9)
  fi
  out=$(asu python3 "$HERE/steam-add-shortcut.py" "$UD" "$name" "$E/$exe" "${opts:-}" proton_11-arm64)
  id=$(echo "$out" | grep -o "appid [0-9]*" | cut -d" " -f2)
  [ -d "$C/$id" ] || cp -a --reflink=auto "$C/$TEMPLATE" "$C/$id"
  [ -n "${dx:-}" ] && bash "$HERE/proton-prefix-tweaks.sh" "$id" --d3dx9 "$dx" >/dev/null
  echo "$name -> $id ${dx:+(d3dx9_$dx)}"
done < "$LIST"
chown -R $U:$U "$C"
echo "done"
