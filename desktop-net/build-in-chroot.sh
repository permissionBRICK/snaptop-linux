#!/bin/bash
# Runs INSIDE the Frame image chroot (aarch64 under qemu-user). Builds the KDE network and Bluetooth stack that
# the Steam Frame image leaves out, against the image's own Qt 6.8 / KF6 6.14 / Plasma 6.2.5.
set -euo pipefail
S=/build/src; B=/build/b; STAGE=/build/stage; J=${J:-8}
mkdir -p $B $STAGE
log() { echo "$(date +%T) == $*"; }
build() {  # name, stage(yes|no), cmake args...
  local n=$1 st=$2; shift 2
  [ -f $B/$n.done ] && { log "skip $n (already built)"; return 0; }
  log "configure $n"
  cmake -S $S/$n -B $B/$n -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
        -DBUILD_QCH=OFF -DKDE_INSTALL_USE_QT_SYS_PATHS=ON -DKDE_INSTALL_LIBEXECDIR=lib "$@" > $B/$n.configure.log 2>&1 \
    || { tail -30 $B/$n.configure.log; exit 1; }
  log "build $n"
  ninja -C $B/$n -j$J > $B/$n.build.log 2>&1 || { tail -40 $B/$n.build.log; exit 1; }
  ninja -C $B/$n install > $B/$n.install.log 2>&1
  [ "$st" = yes ] && DESTDIR=$STAGE ninja -C $B/$n install >> $B/$n.install.log 2>&1
  touch $B/$n.done; log "done $n"
}
build extra-cmake-modules-6.14.0 no -DBUILD_DOC=OFF
build networkmanager-qt-6.14.0 yes
build modemmanager-qt-6.14.0 yes
build bluez-qt-6.14.0 yes
build plasma-nm-6.2.5 yes -DBUILD_OPENCONNECT=OFF
build bluedevil-6.2.5 yes
log "ALL DONE"
