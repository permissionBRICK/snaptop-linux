#!/bin/bash
# Build the Vivobook S 15 (X1E80100) kernel: mainline v7.3 + community S15 patches + our patches + DT overlay.
# Builds natively on ARM64 (the laptop itself, about 30-40 min) or cross-compiles on x86_64. Output in $WORK/payload/:
#   vmlinuz-<rel>, modules-<rel>.cpio.zst (usr/lib/modules/...), dtb/x1e80100-asus-vivobook-s15-<rel>{,-ec}.dtb
# Usage: WORK=~/snaptop-build kernel/build.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/snaptop-build}
KTAG=${KTAG:-v7.3}
COMMUNITY_URL=${COMMUNITY_URL:-https://github.com/BurninChrome/vivobook-s15-fedora.git}
COMMUNITY_REV=${COMMUNITY_REV:-c35ad9447dcc0883127de50edab1fb3e54f05334}
# Suspend/idle power work for this laptop (ADSP standby message, CX-collapse-only module; patches in patches/)
X1E_SLEEP_URL=${X1E_SLEEP_URL:-https://github.com/justririll/x1e-sleep.git}
X1E_SLEEP_REV=${X1E_SLEEP_REV:-4e84b60}
JOBS=${JOBS:-$(nproc)}
if [ "$(uname -m)" = aarch64 ]; then CC=gcc; M="make ARCH=arm64"
else CC=aarch64-linux-gnu-gcc; M="make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"; fi

for t in $CC git bc flex bison dtc fdtoverlay fdtput cpio zstd; do
  command -v $t >/dev/null || { echo "missing $t (Debian/Ubuntu: gcc (or gcc-aarch64-linux-gnu on x86) git bc flex bison libssl-dev libelf-dev device-tree-compiler cpio zstd)"; exit 1; }
done
mkdir -p "$WORK"; cd "$WORK"

# 1. Sources
[ -d linux ] || git clone --depth 1 --branch "$KTAG" https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux
if [ ! -d vivobook-s15-fedora ]; then git clone -q "$COMMUNITY_URL" vivobook-s15-fedora; fi
git -C vivobook-s15-fedora checkout -q "$COMMUNITY_REV"
if [ ! -d x1e-sleep ]; then git clone -q "$X1E_SLEEP_URL" x1e-sleep; fi
git -C x1e-sleep checkout -q "$X1E_SLEEP_REV"

# 2. Patches: the community series (authorship kept), then ours
cd linux
git config user.email >/dev/null || git config user.email build@localhost
git config user.name >/dev/null || git config user.name build
# Each patch is applied once (skipped when a commit with its subject exists), so the script can run again on
# an existing tree. git mailinfo joins wrapped subjects and strips the [PATCH] prefix like git am does.
P=$WORK/vivobook-s15-fedora/kernel/patches
SUBJECTS=$(git log --format=%s -n 2000)
for p in $(grep -v -E '^#|^$' $P/series | sed "s#^#$P/#") "$HERE"/patches/*.patch; do
  subj=$(git mailinfo /dev/null /dev/null < "$p" | sed -n 's/^Subject: //p')
  grep -Fxq -- "$subj" <<< "$SUBJECTS" || git am -q --3way "$p"
done

# 3. Config: Debian 7.2 arm64 config + every Debian module + S15 extras (see docs/kernel.md)
cp "$HERE/config-7.3.0-s15" .config
$M -s olddefconfig

# 4. Build (DTBs one by one: parallel builds of the base DTB and its -el2 overlay race)
$M -j"$JOBS" Image modules
$M -j1 qcom/x1e80100-asus-vivobook-s15.dtb
KREL=$($M -s kernelrelease)

# 5. DT overlay from the community repo (audio, both cameras, optional EC) + IR sensor rotation
cd "$WORK"
vivobook-s15-fedora/overlay/build-overlay.sh --dtbo-only --out "$WORK/overlay" >/dev/null
OUT=$WORK/payload; rm -rf "$OUT"; mkdir -p "$OUT/dtb" "$OUT/stage"
D=linux/arch/arm64/boot/dts/qcom/x1e80100-asus-vivobook-s15.dtb
for v in "":vivobook-s15.dtbo "-ec":vivobook-s15-experimental.dtbo; do
  suf=${v%%:*}; o=${v#*:}; f=$OUT/dtb/x1e80100-asus-vivobook-s15-$KREL$suf.dtb
  fdtoverlay -i "$D" -o "$OUT/tmp.dtb" "overlay/$o"
  for n in /__symbols__ /__fixups__ /__local_fixups__; do fdtput -r "$OUT/tmp.dtb" $n 2>/dev/null || true; done
  dtc -q -I dtb -O dtb -o "$f" "$OUT/tmp.dtb"
  # The overlay rotates only the RGB sensor; the HM1092 IR sensor is mounted upside down as well.
  fdtput -t i "$f" /soc@0/cci@ac15000/i2c-bus@0/camera@24 rotation 180
  # VREG_EDP_3P3 only feeds the OLED panel, whose driver powers it via runtime PM; always-on kept the panel
  # powered in standby (about 0.7 W here). Keep boot-on for a seamless handover. (from x1e-sleep)
  fdtput -d "$f" /regulator-edp-3p3 regulator-always-on
done
rm -f "$OUT/tmp.dtb"

# 6. Out-of-tree modules from x1e-sleep: ADSP "Modern Standby" message, AOSS CX-collapse-only
for m in adsp-pwr-lmts aoss-cxsd-only; do
  rm -rf "$WORK/oot-$m"; cp -r "$WORK/x1e-sleep/modules/$m" "$WORK/oot-$m"
  $M -C linux M="$WORK/oot-$m" modules >/dev/null
done

# 7. Package
$M -C linux -s INSTALL_MOD_PATH="$OUT/stage" INSTALL_MOD_STRIP=1 modules_install
for m in adsp-pwr-lmts aoss-cxsd-only; do
  $M -C linux -s M="$WORK/oot-$m" INSTALL_MOD_PATH="$OUT/stage" INSTALL_MOD_STRIP=1 modules_install
done
mkdir -p "$OUT/stage/usr"; mv "$OUT/stage/lib" "$OUT/stage/usr/lib"
rm -f "$OUT/stage/usr/lib/modules/$KREL/build" "$OUT/stage/usr/lib/modules/$KREL/source"
(cd "$OUT/stage" && find usr -print0 | cpio --null -o -H newc --owner=0:0 --quiet) | zstd -12 -T0 -q -o "$OUT/modules-$KREL.cpio.zst"
rm -rf "$OUT/stage"
cp linux/arch/arm64/boot/Image "$OUT/vmlinuz-$KREL"
echo "$KREL" > "$OUT/kernel-version"
ls -la "$OUT" "$OUT/dtb"
