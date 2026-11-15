#!/bin/bash
# Native build for installed SteamOS, or in its chroot with /sys and /dev bound.
set -euo pipefail
if [ "$(id -u)" != 0 ] || [ "$(uname -m)" != aarch64 ]; then echo 'Needs root on ARM64'; exit 1; fi
grep -q 'ASUS Vivobook S 15' /sys/firmware/devicetree/base/model || { echo 'Not a Vivobook S 15'; exit 1; }
grep -q '^ID=steamos' /etc/os-release || { echo 'Needs SteamOS'; exit 1; }
LC=0.7.1; PW=1.6.8
LCP=1   # our libcamera patch level (below); a new one rebuilds
[ "$(pkg-config --modversion libpipewire-0.3)" = "$PW" ] || { echo "Expected PipeWire $PW; update the camera build pin for this image"; exit 1; }
STAMP=/var/lib/s15-camera.version
if [ "$(cat "$STAMP" 2>/dev/null || true)" = "$LC/$PW/$LCP" ] &&
   [ -x /usr/local/bin/cam ] && [ -f /usr/local/lib/libcamera.so.0.7 ] &&
   [ -f /usr/local/lib/libcamera/ipa/ipa_soft_simple.so ] &&
   [ -f /usr/lib/spa-0.2/libcamera/libspa-libcamera.so ]; then
    echo 'S15 camera components already installed'; exit 0
fi
pacman -S --needed --noconfirm python-jinja python-ply
W=$(mktemp -d /var/tmp/s15-camera.XXXXXX)
trap 'rm -r "$W"' EXIT
cd "$W"
curl -fL --retry 3 "https://github.com/libcamera-org/libcamera/archive/refs/tags/v$LC.tar.gz" -o libcamera.tar.gz
curl -fL --retry 3 "https://github.com/PipeWire/pipewire/archive/refs/tags/$PW.tar.gz" -o pipewire.tar.gz
sha256sum -c <<'SUMS'
d9e73b8d9c38080aa874138d870faaf1b682199349c04b0a7710aba834e0d181  libcamera.tar.gz
8181172a1d95131f6af8bbc0b98f90b2a33349b042b84c3ce57dd5d11348cc58  pipewire.tar.gz
SUMS
tar -xf libcamera.tar.gz
tar -xf pipewire.tar.gz
# The simple pipeline sets up the media links from its own copy of their state, read when the process started. A
# second libcamera user (face unlock's Biopass, which switches the shared CSID to the IR camera) changes them behind
# a long-running one (WirePlumber): it then skips disabling the IR link, the CSID refuses a second input with EBUSY,
# and browsers get no camera. Set every link up from scratch instead (disabling a disabled link is a no-op).
patch -d "libcamera-$LC" -p1 <<'PATCH'
--- a/src/libcamera/pipeline/simple/simple.cpp
+++ b/src/libcamera/pipeline/simple/simple.cpp
@@ -795,8 +795,13 @@
 				if (link == sinkLink)
 					continue;
 
-				if ((link->flags() & MEDIA_LNK_FL_ENABLED) &&
-				    !(link->flags() & MEDIA_LNK_FL_IMMUTABLE)) {
+				/*
+				 * Not only the links this instance enabled: another
+				 * process may have changed them since it read the
+				 * graph (a link already disabled is a no-op in the
+				 * kernel).
+				 */
+				if (!(link->flags() & MEDIA_LNK_FL_IMMUTABLE)) {
 					ret = link->setEnabled(false);
 					if (ret < 0)
 						return ret;
@@ -804,11 +809,9 @@
 			}
 		}
 
-		if (!(sinkLink->flags() & MEDIA_LNK_FL_ENABLED)) {
-			ret = sinkLink->setEnabled(true);
-			if (ret < 0)
-				return ret;
-		}
+		ret = sinkLink->setEnabled(true);
+		if (ret < 0)
+			return ret;
 
 		sinkLink = e.sourceLink;
 	}
PATCH
meson setup libcamera-build "libcamera-$LC" --prefix=/usr/local --libdir=lib --buildtype=release \
    -Dauto_features=disabled -Dpipelines=simple -Dipas=simple -Dcam=enabled -Dudev=enabled
ninja -C libcamera-build -j4
DESTDIR="$W/stage" ninja -C libcamera-build install
cp -a "$W/stage/." /
mkdir -p /etc/ld.so.conf.d
echo /usr/local/lib > /etc/ld.so.conf.d/s15-camera.conf
ldconfig
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
meson setup pipewire-build "pipewire-$PW" --prefix=/usr --libdir=lib --buildtype=release \
    -Dauto_features=disabled -Dlibcamera=enabled -Dsession-managers=[]
ninja -C pipewire-build -j4 spa/plugins/libcamera/libspa-libcamera.so
install -Dm755 pipewire-build/spa/plugins/libcamera/libspa-libcamera.so /usr/lib/spa-0.2/libcamera/libspa-libcamera.so
mkdir -p /var/lib
(cd "$W/stage" && find . \( -type f -o -type l \) | sed 's#^\.#/#; s#//#/#') > /var/lib/s15-camera.files
printf '%s\n' /etc/ld.so.conf.d/s15-camera.conf /usr/lib/spa-0.2/libcamera/libspa-libcamera.so >> /var/lib/s15-camera.files
echo "$LC/$PW/$LCP" > "$STAMP"
echo 'Camera components installed. Restart the desktop WirePlumber service, or reboot.'
