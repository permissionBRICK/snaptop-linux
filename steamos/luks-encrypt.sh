#!/bin/bash
# Encrypt the SteamOS partition (PARTLABEL SNAPSTEAM-NVME) of the Vivobook S15 in place with LUKS2 (docs/encryption.md).
# Runs as root in a live system, with SteamOS not running. Everything at once: luks-encrypt.sh run
# Steps (each refuses to run if the state is not right):
#   check    read-only checks (machine, partition, tools); changes nothing
#   keys     temporary key (32 modhex letters) and a random re-seal key, in /run/s15-luks only (tmpfs)
#   prompt   boot prompt's keymap and font from the SteamOS root (read-only), then luks-passphrase.py on VT 8:
#            the user chooses the passphrase (/run/s15-luks/pass) and confirms (/run/s15-luks/confirmed)
#   encrypt  shrink btrfs by 32 MiB, cryptsetup reencrypt --encrypt (resumes an interrupted run)
#   finish   btrfs check, passphrase and re-seal key slots, re-seal key into the root fs, boot entries, BootNext
# Key slots afterwards: 0 temporary key (remove after the passphrase worked at boot), 1 passphrase, 2 re-seal key.
# The first boot asks for the passphrase; s15-luks-reseal.service then enrolls the TPM. Never prints key material.
# S15_TEST_DEV=<loop device>: dry run on a scratch image (no machine check, no S15BOOT/EFI changes).
set -euo pipefail
D=/run/s15-luks
NAME=s15luks
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "ERROR: $*" >&2; exit 1; }
dev() { [ -n "${S15_TEST_DEV:-}" ] && { echo "$S15_TEST_DEV"; return; }; local p; p=$(readlink -f /dev/disk/by-partlabel/SNAPSTEAM-NVME 2>/dev/null) || die "no partition SNAPSTEAM-NVME"
        [ "$p" = /dev/nvme0n1p15 ] || die "SNAPSTEAM-NVME is $p, expected /dev/nvme0n1p15"; echo "$p"; }
machine() {
  [ -n "${S15_TEST_DEV:-}" ] && return; local m; m=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  case $m in *"Vivobook S 15"*|*"S5507Q"*) ;; *) die "not the Vivobook S15 (model: $m)";; esac
}
progress() { echo "$*" > "$D/progress"; echo "$*"; }
cs() {  # cryptsetup; its progress lines (--progress-frequency) go to $D/progress and $D/encrypt.log
  local rc=0
  stdbuf -oL -eL cryptsetup "$@" 2>&1 | while IFS= read -r l; do
    [ -n "$l" ] && printf '%s\n' "$l" > "$D/progress"; printf '%s\n' "$l" >> "$D/encrypt.log"; done || rc=$?
  return $rc
}

step_check() {
  machine
  local p; p=$(dev)
  echo "partition: $p, $(blockdev --getsize64 "$p") bytes, type $(blkid -o value -s TYPE "$p" || echo none)"
  findmnt -S "$p" >/dev/null && die "$p is mounted"
  for t in cryptsetup btrfs blkid efibootmgr python3 setfont loadkeys kbd_mode stdbuf; do printf '%s: %s\n' "$t" "$(command -v $t || echo MISSING)"; done
  cryptsetup --version
  modprobe dm_crypt && echo "dm_crypt ok"
  free -m | sed -n 2p
  if [ "$(blkid -o value -s TYPE "$p")" = btrfs ]; then
    btrfs inspect-internal dump-super "$p" | grep -E '^(total_bytes|bytes_used|sectorsize)'
  else
    cryptsetup luksDump "$p" | grep -E '^(Version|UUID|Label|Requirements)|reencrypt|Keyslots|^  [0-9]+: luks2' || true
  fi
  local b; b=$(readlink -f /dev/disk/by-partlabel/S15BOOT) && echo "S15BOOT: $b ($(blkid -o value -s TYPE "$b"))"
  efibootmgr 2>/dev/null | grep -E '^Boot0002|^BootOrder' || echo "efibootmgr: no EFI variables yet"
}

step_keys() {
  install -d -m 0700 "$D"
  if [ -s "$D/rk-plain" ]; then echo "keys exist already (kept)"; return; fi
  python3 - "$D" <<'EOF'
import os, secrets, sys
d = sys.argv[1]
mh = "cbdefghijklnrtuv"
key = "".join(mh[b >> 4] + mh[b & 15] for b in secrets.token_bytes(16))
os.umask(0o077)
open(f"{d}/rk-plain", "w").write(key)
open(f"{d}/reseal.key", "wb").write(secrets.token_bytes(64))
EOF
  # Key files without a trailing newline: cryptsetup uses a key file's bytes as they are.
  echo "keys created in $D (temporary key 32 letters, re-seal key 64 random bytes)"
}

step_prompt() {
  machine
  local p m f km font map
  p=$(dev)
  [ -s "$D/rk-plain" ] || die "run 'keys' first"
  [ "$(blkid -o value -s TYPE "$p")" = btrfs ] || die "$p is not the unencrypted btrfs"
  # The passphrase must produce the same bytes here as at the boot prompt: same keymap file, ASCII only.
  m=$D/ro; mkdir -p "$m"; mount -t btrfs -o ro,rescue=nologreplay "$p" "$m"
  for f in "$m/var/lib/overlays/etc/upper/vconsole.conf" "$m/etc/vconsole.conf"; do
    [ -f "$f" ] || continue
    km=$(sed -n 's/^KEYMAP=//p' "$f" | tr -d '"'); font=$(sed -n 's/^FONT=//p' "$f" | tr -d '"'); break
  done
  km=${km:-us}
  map=$(find "$m/usr/share/kbd/keymaps" -name "$km.map*" | head -1)
  if [ -n "$map" ]; then rm -rf "$D/keymaps"; cp -a "$m/usr/share/kbd/keymaps" "$D/keymaps"; map=$D/keymaps/${map#"$m/usr/share/kbd/keymaps/"}; fi
  f=$(find "$m/usr/share/kbd/consolefonts" -name "${font:-none}.*" 2>/dev/null | head -1)
  [ -n "$f" ] && cp "$f" "$D/console-font"
  umount "$m"; rmdir "$m"
  [ -n "$map" ] || die "keymap $km not found in the SteamOS root"
  kbd_mode -u -C /dev/tty8
  loadkeys -C /dev/tty8 -u "$map" >/dev/null
  echo "keymap $km, font ${font:-default}; passphrase prompt on VT 8"
  rm -f "$D/confirmed" "$D/pass"
  setsid -f python3 "$HERE/luks-passphrase.py" 8 >"$D/prompt.err" 2>&1 </dev/null
}

step_encrypt() {
  machine
  local p; p=$(dev)
  [ -f "$D/confirmed" ] && [ -s "$D/pass" ] || die "passphrase not set on the laptop yet"
  findmnt -S "$p" >/dev/null && die "$p is mounted"
  local t rc=0; t=$(blkid -o value -s TYPE "$p" || true)
  if [ "$t" = crypto_LUKS ]; then
    cryptsetup luksDump "$p" | grep -q 'online-reencrypt' || die "$p is LUKS already and no encryption is pending"
    progress "resuming the interrupted encryption"
    cs reencrypt --resume-only --key-file "$D/rk-plain" --progress-frequency 5 "$p" || rc=$?
  else
    [ "$t" = btrfs ] || die "$p: unexpected type '$t'"
    local size total; size=$(blockdev --getsize64 "$p")
    total=$(btrfs inspect-internal dump-super "$p" | awk '/^total_bytes/{print $2}')
    if [ "$total" = "$size" ]; then
      progress "shrinking the btrfs filesystem by 32 MiB"
      mkdir -p "$D/mnt"; mount -t btrfs "$p" "$D/mnt"
      btrfs filesystem resize -32M "$D/mnt"; umount "$D/mnt"
      total=$(btrfs inspect-internal dump-super "$p" | awk '/^total_bytes/{print $2}')
    fi
    [ "$total" -le $((size - 33554432)) ] || die "btrfs is $total bytes, needs <= $((size - 33554432))"
    echo "btrfs $total of $size bytes"
    progress "encrypting (this takes a while)"
    cs reencrypt --encrypt --type luks2 --reduce-device-size 32M --sector-size 4096 \
      --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id --iter-time 1000 --label SNAPSTEAM \
      --key-file "$D/rk-plain" --progress-frequency 5 "$p" || rc=$?
  fi
  [ "$rc" = 0 ] || { progress "FAILED: cryptsetup exit $rc - leave the laptop on, it can be resumed"; die "cryptsetup exit $rc"; }
  cryptsetup luksDump "$p" | grep -q 'online-reencrypt' && { progress "FAILED: encryption not complete"; die "not complete"; }
  progress "encryption complete - finishing the setup"
}

step_finish() {
  machine
  local p uuid m b; p=$(dev)
  [ "$(blkid -o value -s TYPE "$p")" = crypto_LUKS ] || die "$p is not LUKS"
  cryptsetup luksDump "$p" | grep -q 'online-reencrypt' && die "encryption still pending"
  uuid=$(cryptsetup luksUUID "$p")
  [ -e /dev/mapper/$NAME ] || cryptsetup open --allow-discards --key-file "$D/rk-plain" "$p" $NAME
  echo "== btrfs check (read-only)"; btrfs check --readonly /dev/mapper/$NAME 2>&1 | tail -4
  echo "== key slots"
  local slots; slots=$(cryptsetup luksDump "$p" | grep -cE '^  [0-9]+: luks2' || true)
  if [ "$slots" -lt 2 ]; then
    [ -s "$D/pass" ] || die "no passphrase in $D/pass"
    cryptsetup luksAddKey --key-file "$D/rk-plain" --pbkdf argon2id --iter-time 2000 "$p" "$D/pass"
  fi
  if [ "$slots" -lt 3 ]; then
    cryptsetup luksAddKey --key-file "$D/rk-plain" --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$p" "$D/reseal.key"
  fi
  cryptsetup luksDump "$p" | grep -E '^  [0-9]+: luks2|PBKDF:'
  echo "== root filesystem"
  m=$D/mnt; mkdir -p "$m"; mountpoint -q "$m" || mount -t btrfs /dev/mapper/$NAME "$m"
  grep -q '^ID=steamos' "$m/etc/os-release" || die "not the SteamOS root"
  install -d -m 0700 "$m/var/lib/s15-luks"
  install -m 0400 "$D/reseal.key" "$m/var/lib/s15-luks/reseal.key"
  printf 'uuid=%s\nencrypted=%s\nslot0=temporary generated key (remove after the passphrase worked at boot)\nslot1=passphrase\nslot2=re-seal key %s\n' \
    "$uuid" "$(date -Is)" /var/lib/s15-luks/reseal.key > "$m/var/lib/s15-luks/info"
  cryptsetup --test-passphrase --key-file "$m/var/lib/s15-luks/reseal.key" open "$p" && echo "re-seal key opens the volume"
  cryptsetup --test-passphrase --key-file "$D/pass" open "$p" && echo "passphrase opens the volume"
  # The encryption wrote every block, so the SSD considers the whole partition in use (a QLC drive then gets slow):
  # tell it which blocks are free.
  fstrim -v "$m" || echo "fstrim failed (run 'fstrim -v /' in SteamOS)"
  umount "$m"
  [ -n "${S15_TEST_DEV:-}" ] && { cryptsetup close $NAME; progress "DONE (test)"; return; }
  echo "== boot entries on S15BOOT"
  b=$D/esp; mkdir -p "$b"; mountpoint -q "$b" || mount /dev/disk/by-partlabel/S15BOOT "$b"
  local opt="root=/dev/mapper/root rd.luks.name=$uuid=root rd.luks.options=$uuid=discard,tpm2-device=auto"
  for e in s15 s15-previous; do
    f=$b/loader/entries/$e.conf
    [ -f "$f" ] || continue
    [ -f "$f.pre-luks" ] || cp "$f" "$f.pre-luks"
    sed -i "s#root=PARTLABEL=SNAPSTEAM-NVME#$opt#" "$f"
    grep -q "rd.luks.name=$uuid" "$f" || die "$f not updated"
  done
  # The previous entry had the busybox initramfs, which cannot open LUKS: give it the current (systemd) one.
  cp -f "$b/EFI/S15/initramfs-s15.img" "$b/EFI/S15/initramfs-s15.img.old"
  sync; grep -H '^options' "$b"/loader/entries/s15.conf "$b"/loader/entries/s15-previous.conf
  umount "$b"
  cryptsetup close $NAME
  echo "== BootNext"
  mountpoint -q /sys/firmware/efi/efivars && mount -o remount,rw /sys/firmware/efi/efivars 2>/dev/null || true
  efibootmgr | grep -q '^Boot0002.*SteamOS (S15)' || die "Boot0002 is not SteamOS (S15)"
  efibootmgr -q -n 0002 && efibootmgr | grep BootNext
  progress "DONE - restart: SteamOS asks for the passphrase once, then the TPM is enrolled"
}

step_run() {
  step_check; step_keys; step_prompt
  echo "waiting for the passphrase on the laptop's screen (VT 8, Ctrl+Alt+F8) ..."
  while [ ! -f "$D/confirmed" ]; do sleep 2; done
  step_encrypt; step_finish
  echo "Restart now (reboot). Afterwards, in SteamOS, once the passphrase has worked at the boot prompt:"
  echo "  systemd-cryptenroll --unlock-key-file=/var/lib/s15-luks/reseal.key --wipe-slot=0 /dev/disk/by-partlabel/SNAPSTEAM-NVME"
}

case "${1:-}" in
  check) step_check ;; keys) step_keys ;; prompt) step_prompt ;; encrypt) step_encrypt ;; finish) step_finish ;;
  run) step_run ;;
  *) echo "usage: $0 run|check|keys|prompt|encrypt|finish"; exit 2 ;;
esac
