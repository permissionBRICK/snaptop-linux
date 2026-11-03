#!/bin/bash
# Adapts Valve's Steam Frame SteamOS image (mounted at $R) to the ASUS Vivobook S 15 (X1E80100).
# Run as root from a live ARM64 Linux on the laptop; install.sh calls it with all inputs.
# Inputs (environment):
#   R        mounted SteamOS root (default /mnt/steam)
#   PAYLOAD  kernel/build.sh output dir (vmlinuz-*, modules-*.cpio.zst, dtb/); without it the running live
#            system's /usr/lib/modules/$KV is copied and the kernel/DTB must be put into $R/boot by hand
#   FW       firmware root with linux-firmware (ath12k/WCN7850, qca, qcom/gen70500_*) and the ASUS blobs extracted
#            from Windows under qcom/x1e80100/ASUSTeK/vivobook-s15/ (steamos/fetch-deps.sh builds one)
#   TIMEZONE optional, e.g. Europe/Berlin (the Frame image defaults to US Pacific)
#   UCM      ALSA UCM tree that already contains the S15 profile (steamos/fetch-deps.sh builds one)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=${R:-/mnt/steam}
PAYLOAD=${PAYLOAD:-}
KV=${KV:-$( [ -n "$PAYLOAD" ] && cat "$PAYLOAD/kernel-version" || echo 7.3.0-s15+ )}
F=${FW:-/usr/lib/firmware}
U=${UCM:-/usr/share/alsa/ucm2}; DU=/usr/share/alsa/ucm2   # source tree / its place in SteamOS
mountpoint -q "$R" || { echo "$R not mounted"; exit 1; }
grep -q '^ID=steamos' "$R/etc/os-release" || { echo "$R is not SteamOS"; exit 1; }
[ -f "$F/qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn" ] || { echo "ASUS firmware missing under $F (docs/firmware.md)"; exit 1; }
[ -f "$U/Qualcomm/x1e80100/ASUS-Vivobook-S15.conf" ] || { echo "S15 UCM profile missing under $U"; exit 1; }
say() { echo "== $*"; }

say "kernel $KV: modules, image, DTB"
rm -rf "$R/usr/lib/modules/$KV"
if [ -n "$PAYLOAD" ]; then
  if command -v bsdtar >/dev/null; then zstd -dc "$PAYLOAD/modules-$KV.cpio.zst" | bsdtar -xpf - -C "$R"
  else zstd -dc "$PAYLOAD/modules-$KV.cpio.zst" | (cd "$R" && cpio -idmu --quiet); fi
  install -m 0644 "$PAYLOAD/vmlinuz-$KV" "$R/boot/vmlinuz-$KV"
  install -m 0644 "$PAYLOAD/dtb/x1e80100-asus-vivobook-s15-$KV-ec.dtb" "$R/boot/x1e80100-asus-vivobook-s15-ec.dtb"
  install -m 0644 "$PAYLOAD/dtb/x1e80100-asus-vivobook-s15-$KV.dtb" "$R/boot/x1e80100-asus-vivobook-s15.dtb"
else
  cp -a "/usr/lib/modules/$KV" "$R/usr/lib/modules/"
fi

say "firmware (ASUS blobs from Windows, X1E GPU/audio/Wi-Fi/BT)"
for d in qcom/x1e80100 ath12k/WCN7850 qca; do mkdir -p "$R/usr/lib/firmware/$d"; cp -a "$F/$d/." "$R/usr/lib/firmware/$d/"; done
cp -a "$F"/qcom/gen70500_* "$R/usr/lib/firmware/qcom/"

say "ALSA UCM (S15 profile)"
mkdir -p "$R$DU/Qualcomm" "$R$DU/conf.d"
cp -a "$U/Qualcomm/x1e80100" "$R$DU/Qualcomm/"
cp -a "$U/conf.d/x1e80100" "$R$DU/conf.d/" 2>/dev/null || true
cp -an "$U/codecs/." "$R$DU/codecs/"
cp -an "$U/lib/." "$R$DU/lib/" 2>/dev/null || true

say "ALSA UCM: speaker profile without the LPASS WSA macro compander (UI sounds started loud and faded)"
SP="$R$DU/Qualcomm/x1e80100/ASUS-Vivobook-S15-Speaker.conf"; WS="$R$DU/codecs/qcom-lpass/wsa-macro/Wsa1SpeakerEnableSeq.conf"
python3 - "$SP" "$WS" <<'PY'
import re, sys
sp, ws = sys.argv[1], sys.argv[2]
s = open(sp).read()
inc = '\tInclude.wsm1e.File "/codecs/qcom-lpass/wsa-macro/Wsa1SpeakerEnableSeq.conf"\n'
if inc in s:
    seq = [l.strip() for l in open(ws).read().splitlines() if l.strip().startswith("cset") and "WSA_COMP" not in l]
    seq += ["cset \"name='WSA WSA_COMP1 Switch' 0\"", "cset \"name='WSA WSA_COMP2 Switch' 0\""]
    block = ("\t# s15: Wsa1SpeakerEnableSeq.conf inlined without its compander. The LPASS WSA macro compander\n"
             "\t# (WSA_COMP1/2) boosts every sound onset and pulls the gain down within ~100 ms; the steady-state\n"
             "\t# level is the same without it (measured with the built-in mics).\n"
             "\tEnableSequence [\n" + "".join("\t\t%s\n" % c for c in seq) + "\t]\n")
    open(sp, "w").write(s.replace(inc, block))
PY

say "Wi-Fi: NetworkManager with iwd (Steam sets this backend on every start; forcing another one restarts NetworkManager)"
install -d "$R/etc/NetworkManager/conf.d"
printf '[device]\nwifi.backend=iwd\n' > "$R/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf"
# Wi-Fi power save: on (kernel default; NetworkManager's wifi.powersave is not applied with the iwd backend), off
# for networks in /etc/s15-wifi-nopowersave. Some access points (seen on two UniFi-type APs, 2.4 GHz) disassociate
# us with DISASSOC_LOW_ACK about 30 s after every connect while power save is on; s15-wifi-powersave check (from the
# watchdog) adds such a network to the list by itself. The dispatcher hook applies the setting on every connect.
install -D -m0755 "$HERE/s15-wifi-powersave" "$R/usr/local/sbin/s15-wifi-powersave"
install -D -m0755 "$HERE/90-s15-wifi-powersave" "$R/etc/NetworkManager/dispatcher.d/90-s15-wifi-powersave"
install -D -m0755 "$HERE/s15-wifi-watchdog" "$R/usr/local/sbin/s15-wifi-watchdog"
printf '[Unit]\nDescription=Wi-Fi watchdog\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/s15-wifi-watchdog\n' \
  > "$R/etc/systemd/system/s15-wifi-watchdog.service"
printf '[Unit]\nDescription=Wi-Fi watchdog every minute\n[Timer]\nOnBootSec=3min\nOnUnitActiveSec=60s\n[Install]\nWantedBy=timers.target\n' \
  > "$R/etc/systemd/system/s15-wifi-watchdog.timer"
install -d "$R/etc/systemd/system/timers.target.wants"
ln -sfn /etc/systemd/system/s15-wifi-watchdog.timer "$R/etc/systemd/system/timers.target.wants/s15-wifi-watchdog.timer"
# The WCN7850 firmware can get stuck (dmesg "received scan start failure event", EAPOL frames never acked, so
# connects time out with reason 15); reloading the driver recovers it.
cat > "$R/usr/local/sbin/s15-wifi-reset" <<'EOS'
#!/bin/bash
# Reset the Wi-Fi (reload ath12k) and let NetworkManager reconnect.
nmcli radio wifi off; sleep 1
modprobe -r ath12k_wifi7 && modprobe ath12k_wifi7
sleep 5; nmcli radio wifi on
EOS
chmod 0755 "$R/usr/local/sbin/s15-wifi-reset"

if [ -n "${TIMEZONE:-}" ]; then
  say "time zone $TIMEZONE"
  ln -sfn "../usr/share/zoneinfo/$TIMEZONE" "$R/etc/localtime"
fi

say "modules to load at boot"
mkdir -p "$R/etc/modules-load.d"
printf 'scmi-cpufreq\n' > "$R/etc/modules-load.d/vivobook-s15-cpufreq.conf"
# Firmware TPM (kernel patch 0011, docs/tpm.md): there is no devicetree node for it, so it does not autoload.
printf 'tpm_qcom_crb\n' > "$R/etc/modules-load.d/s15-tpm.conf"

say "mask Frame-only system and user units"
mkdir -p "$R/etc/systemd/system" "$R/etc/systemd/user"
for u in steamvr-program-ble.service steamvr-v4l2loopback.service steamvr-set-kernel-thread-priorities.service \
         deckard-audio-setup.service deckard-fan-control.service deckard-fpga.service deckard-led-control.service \
         deckard-typec-logger.service set-wifi-mac-address.service deckard-charger.service \
         deckard-power-monitor.service deckard-fpga-resume.service deckard-boot-images.service \
         adbd.service adbd-post.service usb-gadget.service usb-gadget.target usb-ncm-gadget@.service \
         usb-ncm-dnsmasq@.service steamos-boot.service efi.mount esp.mount home.mount persist.mount \
         systemd-repart.service set-bluetooth-mac-address.service; do
  ln -sfn /dev/null "$R/etc/systemd/system/$u"
done
for u in steamvr.service steamvr-logs.service steamvr-proxmicmute.service steamvr-v4l2cam.service \
         steamvr-nested-desktop.service steamvr-plasma.service; do
  ln -sfn /dev/null "$R/etc/systemd/user/$u"
done

say "fstab: drop the A/B partition-set mounts (everything lives on the root btrfs)"
[ -f "$R/etc/fstab.frame" ] || cp -a "$R/etc/fstab" "$R/etc/fstab.frame"
sed -i -E 's@^([^#].*[[:space:]]/(persist|efi|esp|home)[[:space:]])@# s15: \1@' "$R/etc/fstab"
mkdir -p "$R/home/steamos"; chown 1000:1000 "$R/home/steamos"; chmod 0750 "$R/home/steamos"

say "flat Game Mode: gamescope DRM backend instead of the OpenVR headset backend"
S="$R/usr/lib/steamos/gamescope-session"
[ -f "$S.frame" ] || cp -a "$S" "$S.frame"
python3 - "$S.frame" "$S" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
head = s[:s.index("GAMESCOPE_ARGS=(")]
tail = '''GAMESCOPE_ARGS=(
  --backend drm
  -T "$stats"
  --cursor-hotspot 5,3 --cursor /usr/share/holo/holo-cursor.png
  --cursor-scale-height 720
  --default-touch-mode 4
  --fade-out-duration 200
  --hide-cursor-delay 3000
  --max-scale 2
  --xwayland-count 2
  --prefer-output '*,eDP-1'
)

# s15: flat Steam Deck-style session on the laptop panel (external displays preferred when present)
GAMESCOPE_SESSION_TARGET="${GAMESCOPE_SESSION_TARGET:-gamescope-session.target}"
if [[ "${GAMESCOPE_SESSION_TARGET}" == "gamescope-session.target" ]]; then
  GAMESCOPE_ARGS+=( --keep-alive --mangoapp --steam )
  # Render the Steam UI at the internal panel's native mode (gamescope otherwise used 1920x1080 and upscaled).
  if read -r PW PH < <(head -n1 /sys/class/drm/card*-eDP-1/modes 2>/dev/null | tr x ' ') && [[ -n "$PH" ]]; then
    GAMESCOPE_ARGS+=( -w "$PW" -h "$PH" -W "$PW" -H "$PH" )
  fi
fi

exec gamescope "${GAMESCOPE_ARGS[@]}" -- /usr/lib/steamos/gamescope-onready ${WATCH_SERVICE:-}
'''
open(dst, "w").write(head + tail)
PY
chmod 0755 "$S"

say "Steam client flags: handheld/desktop UI instead of the headset UI"
RS="$R/usr/share/deckard/RUNSTEAM.sh"
[ -f "$RS.frame" ] || cp -a "$RS" "$RS.frame"
sed -i -e '/^[[:space:]]*-vrgamepadui[[:space:]]*$/d' -e 's/^\([[:space:]]*\)-deckard[[:space:]]*$/\1-steampal/' "$RS"
mkdir -p "$R/usr/lib/systemd/user/steam.service.d"
cat > "$R/usr/lib/systemd/user/steam.service.d/90-s15.conf" <<'EOF'
[Service]
# All 12 Oryon cores are big cores (the Frame default 0xf8 pins games to 5 cores).
Environment=STEAM_LAUNCH_WRAPPER_AFFINITY_LIST=0xfff
Environment=STEAM_DESKTOP_APP_AFFINITY_LIST=0xfff
EOF

say "audio: disable the Frame spatializer (needs SteamVR's vraudiocompositor.so; without it streams never link)"
mkdir -p "$R/etc/wireplumber/wireplumber.conf.d"
cat > "$R/etc/wireplumber/wireplumber.conf.d/99-s15-no-spatial-audio.conf" <<'EOF2'
wireplumber.settings = {
  node.stream.enable-spatial-audio = false
}
EOF2

say "WirePlumber: guard the Frame microphone-tracker.lua against a missing default device (startup crash)"
python3 "$HERE/fix-mictracker.py" "$R/etc/wireplumber/scripts/microphone-tracker.lua"

say "Desktop Mode: real Plasma Wayland session instead of the Frame VR desktop"
R="$R" bash "$HERE/steamos-s15-desktop.sh"

say "standby: send EC dark wakes back to sleep; Plasma suspends after 15 min idle on battery"
install -D -m0755 "$HERE/s15-ec-darkwake" "$R/usr/lib/systemd/system-sleep/s15-ec-darkwake"
install -D -m0755 "$HERE/s15-sleep-radios" "$R/usr/lib/systemd/system-sleep/s15-sleep-radios"
install -D -m0755 "$HERE/s15-sync-state" "$R/usr/lib/systemd/system-sleep/s15-sync-state"     # instead of fw_devlink.sync_state=timeout
install -D -m0755 "$HERE/s15-wifi-resume" "$R/usr/lib/systemd/system-sleep/s15-wifi-resume"
install -D -m0755 "$HERE/s15-input-wait" "$R/usr/local/bin/s15-input-wait"          # used by s15-ec-darkwake
install -D -m0755 "$HERE/s15-lid-watchdog" "$R/usr/local/sbin/s15-lid-watchdog"
printf '[Unit]\nDescription=Suspend when awake with the lid closed\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/s15-lid-watchdog\n' \
  > "$R/etc/systemd/system/s15-lid-watchdog.service"
printf '[Unit]\nDescription=Lid watchdog every minute\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=60s\n[Install]\nWantedBy=timers.target\n' \
  > "$R/etc/systemd/system/s15-lid-watchdog.timer"
install -d "$R/etc/systemd/system/timers.target.wants"
ln -sfn /etc/systemd/system/s15-lid-watchdog.timer "$R/etc/systemd/system/timers.target.wants/s15-lid-watchdog.timer"
install -D -m0755 "$HERE/../power/s15-sleep-hook" "$R/usr/lib/systemd/system-sleep/s15-sleep-hook"
# USB controllers: powered while awake (hot-plugging), runtime PM only around a suspend. Replaces the old udev rule
# that kept them runtime-suspended all the time: a plugged-in device then never woke them.
rm -f "$R/etc/udev/rules.d/91-s15-usb-runtime-pm.rules"
install -D -m0755 "$HERE/s15-usb-sleep" "$R/usr/lib/systemd/system-sleep/s15-usb-sleep"
install -D -m0644 "$HERE/92-s15-wakeup.rules" "$R/etc/udev/rules.d/92-s15-wakeup.rules"
install -D -m0755 "$HERE/s15-lid-wake" "$R/usr/lib/systemd/system-sleep/s15-lid-wake"
echo aoss_cxsd_only > "$R/etc/modules-load.d/s15-aoss-cxsd-only.conf"   # x1e-sleep: avoid AOSD (hourly resets)
install -d -o 1000 -g 1000 "$R/home/steamos/.config"
[ -f "$R/home/steamos/.config/powerdevilrc" ] || install -o 1000 -g 1000 -m0644 "$HERE/powerdevilrc" "$R/home/steamos/.config/powerdevilrc"
# Touchpad: two-finger scrolling moves the content like on Windows (libinput "natural scrolling"; KWin keys the
# setting by vendor/product ID in decimal and device name).
K="$R/home/steamos/.config/kcminputrc"
grep -q 'hid-over-i2c 093A:3016 Touchpad' "$K" 2>/dev/null || \
  printf '[Libinput][2362][12310][hid-over-i2c 093A:3016 Touchpad]\nNaturalScroll=true\n\n' >> "$K"
chown 1000:1000 "$K"
# Power key: s15-power-key handles it in Desktop Mode (short press = sleep, the waking press is ignored); Plasma's own
# action ("show the logout screen", which also popped up on every wake by the power key) is set to "do nothing".
python3 - "$R/home/steamos/.config/powerdevilrc" <<'PY'
import configparser, sys
c = configparser.RawConfigParser(); c.optionxform = str; c.read(sys.argv[1])
for p in ("AC", "Battery", "LowBattery"):
    sec = p + "][SuspendAndShutdown"
    if not c.has_section(sec): c.add_section(sec)
    c.set(sec, "PowerButtonAction", "0")
with open(sys.argv[1], "w") as f: c.write(f, space_around_delimiters=False)
PY
install -D -m0755 "$HERE/s15-power-key" "$R/usr/local/bin/s15-power-key"
install -D -m0755 "$HERE/s15-power-key-mark" "$R/usr/lib/systemd/system-sleep/s15-power-key-mark"
printf '[Unit]\nDescription=Power key: sleep in Desktop Mode, ignore the waking press\n[Service]\nExecStart=/usr/local/bin/s15-power-key\nRestart=always\nRestartSec=2\n[Install]\nWantedBy=multi-user.target\n' \
  > "$R/etc/systemd/system/s15-power-key.service"
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/s15-power-key.service "$R/etc/systemd/system/multi-user.target.wants/s15-power-key.service"

say "Keyboard RGB: rainbow in Game Mode, white in Desktop Mode"
R="$R" bash "$HERE/steamos-s15-keyboard.sh"

say "Reboot to Windows: desktop icon and service"
R="$R" bash "$HERE/steamos-s15-dualboot.sh"



say "NTFS/exFAT automount for USB drives (/run/media/steamos/<label>, owned by steamos)"
cat > "$R/usr/local/sbin/s15-media-mount" <<'EOF'
#!/bin/bash
# s15-media-mount add|remove <kernel name>: NTFS (ntfs3) / exFAT partitions on USB disks.
set -u
act=$1; dev=/dev/$2
label=$(blkid -o value -s LABEL "$dev" 2>/dev/null); fs=$(blkid -o value -s TYPE "$dev" 2>/dev/null)
case "$label" in S15BOOT) exit 0;; esac
name=${label:-$2}; name=${name//[^A-Za-z0-9._-]/_}; mp=/run/media/steamos/$name
if [ "$act" = remove ]; then umount "$mp" 2>/dev/null; rmdir "$mp" 2>/dev/null; exit 0; fi
mkdir -p "$mp"
case "$fs" in
  ntfs) mount -t ntfs3 -o rw,noatime,uid=1000,gid=1000,umask=022,windows_names,prealloc "$dev" "$mp" ;;
  exfat) mount -t exfat -o rw,noatime,uid=1000,gid=1000,umask=022 "$dev" "$mp" ;;
  *) rmdir "$mp"; exit 0 ;;
esac || { rmdir "$mp" 2>/dev/null; echo "mount of $dev ($fs) failed (dirty NTFS? boot Windows and shut down cleanly)"; exit 1; }
echo "mounted $dev ($fs) at $mp"
EOF
chmod 0755 "$R/usr/local/sbin/s15-media-mount"
cat > "$R/etc/systemd/system/s15-media-mount@.service" <<'EOF'
[Unit]
Description=Mount USB NTFS/exFAT partition %I for Steam
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/s15-media-mount add %I
ExecStop=/usr/local/sbin/s15-media-mount remove %I
EOF
cat > "$R/etc/udev/rules.d/90-s15-media-mount.rules" <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_BUS}=="usb", ENV{ID_FS_TYPE}=="ntfs|exfat", TAG+="systemd", ENV{SYSTEMD_WANTS}+="s15-media-mount@%k.service"
EOF

say "initramfs for $KV (systemd; boot drivers, DSPs and display, keyboard, TPM, LUKS, btrfs)"
# docs/steamos.md#initramfs. The install hooks are files in steamos/initcpio/; the busybox variant's /etc overlay hook
# (s15_etc_overlay) is replaced by sd-s15-etc-overlay.
mkdir -p "$R/etc/initcpio/install"
for h in s15 s15-dsp sd-s15-etc-overlay; do install -m0644 "$HERE/initcpio/$h" "$R/etc/initcpio/install/$h"; done
rm -f "$R/etc/initcpio/install/s15_etc_overlay" "$R/etc/initcpio/hooks/s15_etc_overlay"
install -m0644 "$HERE/mkinitcpio-s15.conf" "$R/etc/mkinitcpio-s15.conf"
# Console font for a passphrase prompt on the 2880x1620 panel (the kernel's 8x16 font is tiny there). The keymap
# stays as it is: KEYMAP= in /etc/vconsole.conf, e.g. de-latin1-nodeadkeys (default us).
grep -qs '^FONT=' "$R/etc/vconsole.conf" || echo 'FONT=latarcyrheb-sun32' >> "$R/etc/vconsole.conf"
# --make-rslave: without it the recursive unmount below propagates to the host (/ is a shared mount) and
# takes /sys/fs/cgroup, /dev/pts, /dev/shm etc. with it, which breaks systemd until they are remounted.
for m in proc sys dev run; do mountpoint -q "$R/$m" || { mount --rbind "/$m" "$R/$m"; mount --make-rslave "$R/$m"; }; done
say "camera libraries and PipeWire plugin"
install -m0755 "$HERE/install-camera.sh" "$R/var/tmp/s15-install-camera.sh"
chroot "$R" bash /var/tmp/s15-install-camera.sh
rm "$R/var/tmp/s15-install-camera.sh"
chroot "$R" depmod "$KV"
# From a live system, autodetect would look at the live kernel's view of the hardware; INITRAMFS_ALL_DRIVERS=1
# (install.sh) builds this first image with all boot drivers instead. Later kernels (install-kernel.sh) use autodetect.
C=/etc/mkinitcpio-s15.conf
if [ "${INITRAMFS_ALL_DRIVERS:-0}" = 1 ]; then sed 's/ autodetect / /' "$R$C" > "$R/etc/mkinitcpio-s15-all.conf"; C=/etc/mkinitcpio-s15-all.conf; fi
chroot "$R" mkinitcpio -c "$C" -k "$KV" -g "/boot/initramfs-s15.img" 2>&1 | grep -i -E "error|s15-dsp|image generation" | head -12 || true
rm -f "$R/etc/mkinitcpio-s15-all.conf"
for m in run dev sys proc; do umount -R -l "$R/$m" || true; done
# The Frame's deckard-uimage post hook wraps the image in a 64-byte U-Boot header and deletes the original.
if [ -f "$R/boot/initrd.uImage" ] && [ ! -f "$R/boot/initramfs-s15.img" ]; then
  dd if="$R/boot/initrd.uImage" of="$R/boot/initramfs-s15.img" bs=64 skip=1 status=none
fi
ls -la "$R/boot/initramfs-s15.img"
echo "SETUP DONE"
