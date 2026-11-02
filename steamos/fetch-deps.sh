#!/bin/bash
# Assemble the firmware tree and the ALSA UCM tree that steamos-s15-setup.sh copies into the SteamOS image.
# Usage: fetch-deps.sh <outdir> <asus firmware dir>
#   <asus firmware dir>  output of windows/Export-S15Firmware.ps1 (contains usr/lib/firmware/qcom/x1e80100/ASUSTeK/...)
# Result: <outdir>/firmware (FW for the setup) and <outdir>/ucm2 (UCM for the setup).
# Everything is pinned and checked: linux-firmware 20260916 (the files this laptop uses that the Steam Frame image
# lacks), alsa-ucm-conf 1.2.16 and the community S15 UCM profile.
set -euo pipefail
OUT=$(realpath -m "${1:?outdir}"); ASUS=$(realpath "${2:?ASUS firmware dir from Windows}")
LF_TAG=20260916; LF=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain
UCM_VER=1.2.16; UCM_SHA=acbc972d6e71edfa345e76afdf10c399fd0f1f3cf90d84afdb4cf51bfc4a6548
COMMUNITY=https://raw.githubusercontent.com/BurninChrome/vivobook-s15-fedora/c35ad9447dcc0883127de50edab1fb3e54f05334
get() {  # url dest sha256
  mkdir -p "$(dirname "$2")"
  [ -s "$2" ] && echo "$3  $2" | sha256sum -c --quiet 2>/dev/null && return 0
  curl -fsSL --retry 3 -o "$2" "$1"
  echo "$3  $2" | sha256sum -c --quiet || { echo "checksum mismatch: $1"; rm -f "$2"; exit 1; }
}

A=$(find "$ASUS" -type d -path '*qcom/x1e80100/ASUSTeK/vivobook-s15' | head -1)
[ -n "$A" ] && [ -f "$A/qcadsp8380.mbn" ] || { echo "no ASUS firmware (qcadsp8380.mbn) under $ASUS - run windows/Prepare-S15.ps1"; exit 1; }

F=$OUT/firmware
while read -r sha f; do get "$LF/$f?h=$LF_TAG" "$F/$f" "$sha"; done <<'EOF'
43aadfd3df887f27de74020273aee484bac6a31dd53068f91baf2a9b094d6a68 ath12k/WCN7850/hw2.0/amss.bin
0e72f44df7defc269fe92dcea25d4d409046c04b77d41c510c52879b3dfc1055 ath12k/WCN7850/hw2.0/m3.bin
1abee7132dbccb523cca44a8de4e8968aa7bf5a5fcc032c338f687f94ea5bf4e ath12k/WCN7850/hw2.0/board-2.bin
f1c00f4640a5c4e5dc36a2574d3d1d0afcfd1ab58a84f217dce4b1bb73cba981 qca/hmtbtfw20.tlv
c26b340bbc8b617304610c774627ac4879194705eea7a7c7b13e3593903befd9 qca/hmtnv20.bin
f8d027c5f0ea54456d23b903c55e1a87b06df97ff26b83e3fd02ac6b265b5264 qca/hmtnv20.b10f
f8d027c5f0ea54456d23b903c55e1a87b06df97ff26b83e3fd02ac6b265b5264 qca/hmtnv20.b112
eefc6129b92ed191ada72357520d5e6c329508d95c12cc7edde9c52f5a04eec5 qca/hmtnv20.b201
fac87e4e413ef28f4f8a74360429ba8c0c689a993bc0e75af61a55fc32d8f3e7 qca/hmtnv20.b202
5dfba247d548cabcb892ffa716e8dc82a345fd54b5dbae46ba523230e7ae37dd qcom/gen70500_gmu.bin
05ae89e6dea62268cec3f4abb5d7d6db2c95270ff105fd056f77262e39d2e527 qcom/gen70500_sqe.fw
aa303397750f883ecaeed874d7547da658500596247676a6d405bf1ec43290b5 qcom/x1e80100/ASUSTeK/vivobook-s15/X1E80100-ASUS-Vivobook-S15-tplg.bin
EOF
cp -a "$A/." "$F/qcom/x1e80100/ASUSTeK/vivobook-s15/"
echo "firmware: $(find "$F" -type f | wc -l) files in $F"

W=$OUT/ucm-src; mkdir -p "$W"
get "https://www.alsa-project.org/files/pub/lib/alsa-ucm-conf-$UCM_VER.tar.bz2" "$W/alsa-ucm-conf-$UCM_VER.tar.bz2" "$UCM_SHA"
rm -rf "$OUT/ucm2"; tar -xjf "$W/alsa-ucm-conf-$UCM_VER.tar.bz2" -C "$W"; mv "$W/alsa-ucm-conf-$UCM_VER/ucm2" "$OUT/ucm2"
U=$OUT/ucm2/Qualcomm/x1e80100
while read -r sha f; do get "$COMMUNITY/ucm/Qualcomm/x1e80100/$f" "$U/$f" "$sha"; done <<'EOF'
7937bfa866adf338be507fe9cb8d0d650e9d3d22ab88035b41062207dc34a447 ASUS-Vivobook-S15.conf
3f042816de63bf3bea8e33aea7590d287f469c6809b1877809a2fb04ce297898 ASUS-Vivobook-S15-Speaker.conf
0f7bc5919b0f05bbf0b39cf156473a89308f76770ed5b9d42f8332a8f04728d2 ASUS-Vivobook-S15-Headphones.conf
EOF
# Point the S15 (by DMI) at its own profile; alsa-ucm-conf 1.2.16 still sends it to the T14s branch.
python3 - "$U/x1e80100.conf" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if "ASUSVivobookS15" not in s:
    block = ('If.ASUSVivobookS15 {\n\tCondition {\n\t\tType RegexMatch\n\t\tString "${var:DMI_info}"\n'
             '\t\tRegex "ASUSTeK COMPUTER.*ASUS Vivobook S 15"\n\t}\n'
             '\tTrue.Include.vivobook.File "/Qualcomm/x1e80100/ASUS-Vivobook-S15.conf"\n}\n\n')
    i = s.index("If.LENOVOT14s")
    i = s.rfind("\n#", 0, i) + 1 if s.rfind("\n#", 0, i) > s.rfind("}", 0, i) else i
    s = s[:i] + block + s[i:]
    s = s.replace("|Vivobook S 15", "", 1)
    open(p, "w").write(s)
PY
rm -rf "$W"
echo "ucm2: $OUT/ucm2 (S15 profile added)"
