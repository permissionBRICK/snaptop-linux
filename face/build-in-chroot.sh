#!/bin/bash
# Runs INSIDE the SteamOS chroot of face/build.sh (natively or under qemu-user): unpack the pinned sources, apply our
# patches, build Biopass's auth part offline, run the unit tests the patches touch, stage the files under
# /build/stage in the layout of Biopass's own package (/usr/lib/biopass, ...).
set -euo pipefail
B=/build; S=$B/src; T=$B/b; STAGE=$B/stage; J=${J:-8}; V=${BIOPASS_VERSION:?}
log() { echo "$(date +%T) == $*"; }
# Build-only dependencies the image lacks (cli11: headers; libcamera's code generators), from the image's own
# repository, into the build overlay only.
need=()
for p in cli11 python-jinja python-ply python-yaml; do pacman -Q "$p" >/dev/null 2>&1 || need+=("$p"); done
[ ${#need[@]} = 0 ] || pacman -S --needed --noconfirm "${need[@]}" >/dev/null
log "sources and patches"
rm -rf "$B/biopass-$V" "$T" "$STAGE" "$B/libcamera"; mkdir -p "$T/_deps" "$B/libcamera"
tar -xf "$S/biopass-$V.tar.gz" -C "$B"
for p in "$B"/patches/*.patch; do patch -d "$B/biopass-$V" -p1 --quiet < "$p"; done
# FetchContent's own places (build/_deps/<name>-src), so the binaries' RUNPATH stays relative as in Biopass's builds
unpack() { mkdir -p "$2"; tar -xf "$1" -C "$2" --strip-components=1; }
unpack "$S"/onnxruntime-linux-aarch64-*.tgz "$T/_deps/onnxruntime-src"
unpack "$S"/stb-*.tar.gz "$T/_deps/stb-src"
unpack "$S"/yaml-cpp-*.tar.gz "$T/_deps/yaml-cpp-src"
unpack "$S"/spdlog-*.tar.gz "$T/_deps/spdlog-src"
unpack "$S"/libcamera-*.tar.gz "$B/libcamera"
mkdir -p "$T/_deps/sqlite3_amalgamation-src"
(cd "$T/_deps/sqlite3_amalgamation-src" && cmake -E tar xf "$S"/sqlite-amalgamation-*.zip && mv sqlite-amalgamation-*/* .)
log "configure"
cmake -S "$B/biopass-$V/auth" -B "$T" -DCMAKE_BUILD_TYPE=Release -DPROJECT_VERSION="$V" -DBUILD_TESTS=ON \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DFETCHCONTENT_SOURCE_DIR_ONNXRUNTIME="$T/_deps/onnxruntime-src" -DFETCHCONTENT_SOURCE_DIR_STB="$T/_deps/stb-src" \
  -DFETCHCONTENT_SOURCE_DIR_YAML-CPP="$T/_deps/yaml-cpp-src" -DFETCHCONTENT_SOURCE_DIR_SPDLOG="$T/_deps/spdlog-src" \
  -DFETCHCONTENT_SOURCE_DIR_SQLITE3_AMALGAMATION="$T/_deps/sqlite3_amalgamation-src" \
  -DBIOPASS_LIBCAMERA_SOURCE_DIR="$B/libcamera" -DBIOPASS_LIBCAMERA_SOFTISP_GPU=OFF > "$B/configure.log" 2>&1 ||
  { tail -40 "$B/configure.log"; exit 1; }
log "build ($J jobs)"
cmake --build "$T" -j "$J" --target biopass-helper biopass_pam biopass-keyring camera_capture_test \
  pixel_convert_test capture_policy_test face_camera_reuse_test face_framing_test face_both_cameras_test \
  config_validation_test config_golden_test auth_manager_test > "$B/build.log" 2>&1 ||
  { grep -E -A5 'error|Error' "$B/build.log" | head -60; exit 1; }
log "unit tests"
for t in pixel_convert/pixel_convert_test capture_policy/capture_policy_test face_camera_reuse/face_camera_reuse_test \
  face_framing/face_framing_test face_both_cameras/face_both_cameras_test config_validation/config_validation_test \
  config_golden/config_golden_test auth_manager/auth_manager_test; do
  "$T/test/$t" > "$B/test.log" 2>&1 || { grep FAIL "$B/test.log"; exit 1; }
  echo "  $(basename "$t"): $(tail -1 "$B/test.log")"
done
log "stage"
L=$STAGE/usr/lib/biopass; LB=$T/libcamera-bundle
install -D -m0755 "$T/pam/biopass-helper" "$STAGE/usr/bin/biopass-helper"
install -D -m0755 "$T/pam/libbiopass_pam.so" "$STAGE/usr/lib/security/libbiopass_pam.so"
install -D -m0755 "$T/keyring/biopass-keyring" "$STAGE/usr/libexec/biopass/biopass-keyring"
install -D -m0755 -t "$L" "$T/face/detection/libbiopass_det.so" "$T/face/recognition/libbiopass_reg.so" \
  "$T/face/antispoofing/libbiopass_as.so" "$LB/libcamera.so.0.8" "$LB/libcamera-base.so.0.8"
install -m0755 "$T"/_deps/onnxruntime-src/lib/libonnxruntime.so.1.* "$L/libonnxruntime.so.1"
install -D -m0755 "$LB/libcamera/ipa/ipa_softisp.so" "$L/libcamera/ipa/ipa_softisp.so"
install -D -m0755 "$LB/libcamera/softisp_ipa_proxy" "$L/libcamera/softisp_ipa_proxy"
install -D -m0644 "$LB/ipa/softisp/uncalibrated.yaml" "$STAGE/usr/share/biopass/libcamera/ipa/softisp/uncalibrated.yaml"
install -D -m0755 "$T/test/camera/camera_capture_test" "$STAGE/usr/lib/s15-face/camera_capture_test"
strip --strip-unneeded "$STAGE/usr/bin/biopass-helper" "$STAGE/usr/lib/security/libbiopass_pam.so" \
  "$STAGE/usr/libexec/biopass/biopass-keyring" "$STAGE/usr/lib/s15-face/camera_capture_test" "$L"/*.so* \
  "$L/libcamera/ipa/ipa_softisp.so" "$L/libcamera/softisp_ipa_proxy"
echo "  biopass-helper needs: $(readelf -d "$STAGE/usr/bin/biopass-helper" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
echo "  libcamera needs: $(readelf -d "$L/libcamera.so.0.8" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
log "ALL DONE"
