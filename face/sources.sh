# Pinned inputs of the face unlock build (face/build.sh): sha256, file, URL. Biopass's own pins
# (auth/Dependencies.cmake, auth/BundleLibcamera.cmake of the tag) as checksummed archives. The app's dependencies come
# from the lockfiles in Biopass's archive: its frontend packages from app/bun.lock (sha512 each, face/bunlock.py), its
# Rust crates from app/src-tauri/Cargo.lock (sha256 each, cargo --locked); the Rust toolchain and Node.js from the
# SteamOS image's own repository, into the build overlay only.
BIOPASS_VERSION=1.5.1
FACE_SOURCES="\
d34c6eae6f5e063cdfe03a5300f33604e3d7bfcf104bf3ec9be07c45f87d9951 biopass-1.5.1.tar.gz https://github.com/phucvinh57/biopass/archive/refs/tags/1.5.1.tar.gz
5317505e2da99be65f8e2775ba3c2afd6d2961fd78aba1bd8f56159f48820c78 onnxruntime-linux-aarch64-1.31.1.tgz https://github.com/microsoft/onnxruntime/releases/download/v1.31.1/onnxruntime-linux-aarch64-1.31.1.tgz
5ecea748d40d531ba1c977f56aab7180ce81871f6267e672968c7ace2a8dfdfd libcamera-0.8.0.tar.gz https://github.com/libcamera-org/libcamera/archive/refs/tags/v0.8.0.tar.gz
1b59a668a789a28a8fd4e01ff1413eec7eaeb28688bafdc66ec7068f4e7095e1 stb-d14d46f6b44456eb88beac58cba833a4135d4c89.tar.gz https://github.com/nothings/stb/archive/d14d46f6b44456eb88beac58cba833a4135d4c89.tar.gz
25cb043240f828a8c51beb830569634bc7ac603978e0f69d6b63558dadefd49a yaml-cpp-0.9.0.tar.gz https://github.com/jbeder/yaml-cpp/archive/refs/tags/yaml-cpp-0.9.0.tar.gz
d8862955c6d74e5846b3f580b1605d2428b11d97a410d86e2fb13e857cd3a744 spdlog-1.17.0.tar.gz https://github.com/gabime/spdlog/archive/refs/tags/v1.17.0.tar.gz
0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9 sqlite-amalgamation-3540100.zip https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip"

# What the build depends on: the pins above, the patches and the build scripts. A build whose id matches the
# installed one is not repeated (install-face.sh, s15-os-update).
face_build_id() {
  local d
  d=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  echo "$BIOPASS_VERSION-$(cat "$d/sources.sh" "$d/build.sh" "$d/build-in-chroot.sh" "$d/bunlock.py" \
    "$d"/node-test/*.mjs "$d"/patches/*.patch |
    sha256sum | cut -c1-12)"
}
