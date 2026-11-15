#!/bin/bash
# Runs INSIDE the SteamOS chroot of face/build.sh (natively or under qemu-user): unpack the pinned sources, apply our
# patches, build Biopass's auth part and its app, run the unit tests the patches touch, stage the files under
# /build/stage in the layout of Biopass's own package (/usr/lib/biopass, /usr/bin/biopass, ...). Offline but for the
# app's crates (cargo fetch --locked, each checked against Cargo.lock) and the image's packages.
set -euo pipefail
B=/build; S=$B/src; T=$B/b; STAGE=$B/stage; J=${J:-8}; V=${BIOPASS_VERSION:?}
A=$B/biopass-$V/app
log() { echo "$(date +%T) == $*"; }
# Build-only dependencies the image lacks (cli11: headers; libcamera's code generators; the app: Rust, Node.js and
# WebKitGTK's headers, which Arch's package carries), from the image's own repository, into the build overlay only.
need=()
for p in cli11 python-jinja python-ply python-yaml rust nodejs webkit2gtk-4.1; do
  pacman -Q "$p" >/dev/null 2>&1 || need+=("$p")
done
# Valve's package server sometimes stalls a download (pacman gives up after 10 s without data): try again.
for try in 1 2 3 4; do
  [ ${#need[@]} = 0 ] || pacman -S --needed --noconfirm "${need[@]}" >/dev/null && break
  [ "$try" = 4 ] && exit 1
  echo "pacman: a download failed, again in 30 s"; sleep 30
done
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
cmake --build "$T" -j "$J" --target biopass-helper biopass_pam biopass-keyring biopass_fingerprint \
  camera_capture_test pixel_convert_test capture_policy_test face_camera_reuse_test face_framing_test \
  face_both_cameras_test config_validation_test config_golden_test auth_manager_test helper_exit_test \
  camera_list_test face_pair_test > "$B/build.log" 2>&1 ||
  { grep -E -A5 'error|Error' "$B/build.log" | head -60; exit 1; }
log "unit tests"
for t in pixel_convert/pixel_convert_test capture_policy/capture_policy_test face_camera_reuse/face_camera_reuse_test \
  face_framing/face_framing_test face_both_cameras/face_both_cameras_test config_validation/config_validation_test \
  config_golden/config_golden_test auth_manager/auth_manager_test helper_exit/helper_exit_test \
  camera_list/camera_list_test face_pair/face_pair_test; do
  "$T/test/$t" > "$B/test.log" 2>&1 || { grep FAIL "$B/test.log"; exit 1; }
  echo "  $(basename "$t"): $(tail -1 "$B/test.log")"
done
log "app: frontend packages (bun.lock)"
python3 -I "$B/bunlock.py" install "$A/bun.lock" "$S/npm" "$A"
log "app: frontend (Node.js $(node --version))"
(cd "$A" && node node_modules/typescript/bin/tsc && node node_modules/vite/bin/vite.js build) > "$B/frontend.log" 2>&1 ||
  { tail -40 "$B/frontend.log"; exit 1; }
log "app: frontend tests"
# Biopass runs them with `bun test`; Node runs them here with bun:test's API (node-test/).
mapfile -t tests < <(cd "$A" && find src -name '*.test.ts' | sort)
(cd "$A" && node --import "$B/node-test/register.mjs" --test "${tests[@]}") > "$B/frontend-test.log" 2>&1 || { grep -E -B2 -A12 '^not ok|✖' "$B/frontend-test.log" | head -60; exit 1; }
echo "  frontend: $(sed -n 's/^ℹ \(tests\|pass\|fail\) /\1 /p' "$B/frontend-test.log" | tr '\n' ' ')"
# The version the release has (Biopass's Makefile stamps it into the manifest and its lockfile entry likewise).
sed -i -E '0,/^version = "[^"]*"/s//version = "'"$V"'"/' "$A/src-tauri/Cargo.toml"
sed -i -E '/^name = "biopass"$/{n;s/^version = "[^"]*"/version = "'"$V"'"/}' "$A/src-tauri/Cargo.lock"
# The app links auth's fingerprint library from ../../auth/build (build.rs).
ln -sfn "$T" "$B/biopass-$V/auth/build"
export CARGO_HOME=$B/cargo
log "app: crates (Cargo.lock)"
(cd "$A/src-tauri" && cargo fetch --locked --target "$(uname -m)-unknown-linux-gnu") > "$B/fetch.log" 2>&1 ||
  { tail -20 "$B/fetch.log"; exit 1; }
# The image's Rust (1.93) is older than the 1.95 one crate (rusqlite_migration 2.6) declares; it builds with it, and
# the app's database tests run below.
log "app: build ($(rustc --version), $J jobs)"
(cd "$A/src-tauri" && cargo build --release --frozen --ignore-rust-version -j "$J" --features tauri/custom-protocol) \
  > "$B/app-build.log" 2>&1 || { grep -E -A8 '^error' "$B/app-build.log" | head -60; exit 1; }
log "app: tests"
# With the build's features: cargo test also builds the app's binary (for the integration tests), and one without
# tauri/custom-protocol is a development build that loads its pages from Vite's dev server (localhost:1420).
(cd "$A/src-tauri" && cargo test --release --frozen --ignore-rust-version -j "$J" --features tauri/custom-protocol) \
  > "$B/app-test.log" 2>&1 ||
  { grep -E 'FAILED|panicked|^error' -A6 "$B/app-test.log" | head -60; exit 1; }
echo "  app: $(grep -E '^test result' "$B/app-test.log" | awk '{p+=$4; f+=$6} END {print p " passed, " f " failed"}')"
# The production build embeds the frontend (each file of dist/assets by its path); a development build has none.
strings "$A/src-tauri/target/release/biopass" > "$B/app-strings.txt"
for f in "$A"/dist/assets/*; do
  grep -qF "/assets/${f##*/}" "$B/app-strings.txt" || { echo "app: ${f##*/} not embedded: a development build"; exit 1; }
done
echo "  app: frontend embedded ($(find "$A/dist/assets" -type f | wc -l) assets)"
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
install -D -m0755 "$A/src-tauri/target/release/biopass" "$STAGE/usr/bin/biopass"
install -D -m0644 "$A/src-tauri/scripts/com.ticklab.biopass.policy" \
  "$STAGE/usr/share/polkit-1/actions/com.ticklab.biopass.policy"
for i in 32x32:32x32 128x128:128x128 256x256:128x128@2x; do
  install -D -m0644 "$A/src-tauri/icons/${i#*:}.png" "$STAGE/usr/share/icons/hicolor/${i%%:*}/apps/biopass.png"
done
# Biopass's own menu entry (its .deb's), started without WebKitGTK's DMA-BUF renderer, which ends the app at once on
# this GPU under Wayland ("Error 71 (Protocol error)").
install -d "$STAGE/usr/share/applications"
cat > "$STAGE/usr/share/applications/biopass.desktop" <<'EOF'
[Desktop Entry]
Categories=System;
Comment=Biometric Authentication System
Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 biopass
StartupWMClass=biopass
Icon=biopass
Name=Biopass
Terminal=false
Type=Application
EOF
strip --strip-unneeded "$STAGE/usr/bin/biopass" "$STAGE/usr/bin/biopass-helper" "$STAGE/usr/lib/security/libbiopass_pam.so" \
  "$STAGE/usr/libexec/biopass/biopass-keyring" "$STAGE/usr/lib/s15-face/camera_capture_test" "$L"/*.so* \
  "$L/libcamera/ipa/ipa_softisp.so" "$L/libcamera/softisp_ipa_proxy"
echo "  biopass-helper needs: $(readelf -d "$STAGE/usr/bin/biopass-helper" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
echo "  libcamera needs: $(readelf -d "$L/libcamera.so.0.8" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
echo "  biopass (app) needs: $(readelf -d "$STAGE/usr/bin/biopass" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
log "ALL DONE"
