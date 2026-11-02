#!/bin/bash
# Download DSOAL (DirectSound on OpenAL Soft, github.com/kcat/dsoal) and keep its Win32 DLLs in games/dsoal/
# for proton-prefix-tweaks.sh --dsoal. Tested with build r697; "latest-master" moves, so other builds only warn.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); D=${DSOAL_DIR:-$HERE/dsoal}
T=$(mktemp -d); trap 'rm -r "$T"' EXIT
curl -sfL -o "$T/DSOAL.zip" https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip
unz() { python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$T"; }
unz "$T/DSOAL.zip"
for z in "$T"/DSOAL_r*.zip; do [ -f "$z" ] && unz "$z"; done
W=$(find "$T" -path '*/DSOAL/Win32' -type d | head -1)
[ -n "$W" ] || { echo "no DSOAL/Win32 folder in the archive"; exit 1; }
mkdir -p "$D"; install -m 0644 "$W/dsound.dll" "$W/dsoal-aldrv.dll" "$D/"
(cd "$D" && sha256sum -c --quiet 2>/dev/null <<'SUMS') && echo "DSOAL r697 (tested build) in $D" || echo "DSOAL in $D (newer than the tested r697 build)"
f35305dbc60ea6f619151dfe7ed1de9f656af6d6d1e8e314b8bbafe7002d04bc  dsound.dll
59eca45b443b6c9f9f44c143b62ae36fd7e42ddf468ce533f9a2803b44c3829e  dsoal-aldrv.dll
SUMS
