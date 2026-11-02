#!/bin/bash
# Per-game Proton prefix fixes for old 32-bit Windows games on SteamOS (ARM64, Proton 11 ARM64 + FEX).
# Usage (as root on the laptop, game not running):
#   proton-prefix-tweaks.sh <appid> [--dsoal] [--d3dx9 <NN>]...
#   --dsoal      DirectSound -> DSOAL/OpenAL Soft (Wine's dsound mixer runs emulated for 32-bit games and
#                saturates a core; FlatOut 2 lagged hard until this). Needs games/dsoal/ from fetch-dsoal.sh
#                and games/alsoft-s15.ini.
#   --d3dx9 NN   Microsoft d3dx9_NN.dll from Steam's DirectX Jun2010 redistributable (Wine's builtin
#                effect support is incomplete; FlatOut 2: "Failed to create effect").
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); DSOAL=${DSOAL_DIR:-$HERE/dsoal}
id=$1; shift
P=/home/steamos/.local/share/Steam/steamapps/compatdata/$id/pfx
W=$P/drive_c/windows/syswow64; R=$P/user.reg
REDIST="/home/steamos/.local/share/Steam/steamapps/common/Steamworks Shared/_CommonRedist/DirectX/Jun2010"
[ -d "$W" ] || { echo "no 32-bit prefix for $id (start the game once first)"; exit 1; }
pgrep -u steamos -f "compatdata/$id" >/dev/null && { echo "game $id is running - quit it first"; exit 1; }
override() {  # add "<dll>"="native,builtin" under [Software\\Wine\\DllOverrides]
  grep -q "^\"$1\"=\"native,builtin\"" "$R" && return 0
  python3 - "$R" "$1" <<'PY'
import sys
p, dll = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8", errors="surrogateescape").read()
key = "[Software\\\\Wine\\\\DllOverrides]"
i = s.find(key)
line = f'"{dll}"="native,builtin"\n'
if i < 0:
    s += f"\n{key} 1793500000\n#time=1dc4b5b5b5b5b5b\n{line}"
else:
    j = s.index("\n", s.index("\n", i) + 1) + 1   # after the "#time=" line
    s = s[:j] + line + s[j:]
open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
PY
}
while [ $# -gt 0 ]; do
  case $1 in
    --dsoal)
      [ -f "$W/dsound.dll.wine" ] || cp -a "$W/dsound.dll" "$W/dsound.dll.wine"
      [ -f "$DSOAL/dsound.dll" ] || { echo "run fetch-dsoal.sh first"; exit 1; }
      install -o steamos -g steamos -m 0644 "$DSOAL/dsound.dll" "$W/dsound.dll"
      install -o steamos -g steamos -m 0644 "$DSOAL/dsoal-aldrv.dll" "$W/dsoal-aldrv.dll"
      A=$P/drive_c/users/steamuser/AppData/Roaming; install -d -o steamos -g steamos "$A"
      install -o steamos -g steamos -m 0644 "$HERE/alsoft-s15.ini" "$A/alsoft.ini"
      override dsound; echo "$id: DSOAL installed"; shift ;;
    --d3dx9)
      v=$2; cab=$(ls "$REDIST"/*_d3dx9_${v}_x86.cab 2>/dev/null | head -1)
      [ -n "$cab" ] || { echo "no d3dx9_$v x86 cab in the redistributable"; exit 1; }
      t=$(mktemp -d); bsdtar -xf "$cab" -C "$t"
      install -o steamos -g steamos -m 0644 "$t/d3dx9_$v.dll" "$W/d3dx9_$v.dll"; rm -rf "$t"
      override "d3dx9_$v"; echo "$id: native d3dx9_$v installed"; shift 2 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
