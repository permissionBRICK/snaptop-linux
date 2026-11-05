#!/bin/bash
# Keyboard RGB per session mode: rainbow in Game Mode, solid white in Desktop Mode, re-applied after standby; the
# light goes off after 30 s without input on battery (s15-kbd-idle).
# Usage: R=<root> steamos-s15-keyboard.sh   (R=/ on the running system)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); R=${R:-/}
install -D -m0755 "$HERE/s15-kbd-color" "$R/usr/local/bin/s15-kbd-color"
install -D -m0755 "$HERE/s15-kbd-mode" "$R/usr/local/sbin/s15-kbd-mode"
install -D -m0755 "$HERE/s15-kbd-idle" "$R/usr/local/sbin/s15-kbd-idle"
[ -f "$R/etc/s15-kbd-mode.conf" ] || printf '# s15-kbd-color arguments per session\nGAME="ffffff rainbow 3"\nDESKTOP="ffffff solid"\n' > "$R/etc/s15-kbd-mode.conf"
grep -q '^IDLE_OFF_' "$R/etc/s15-kbd-mode.conf" ||
  printf '# keyboard light off after this many seconds without input (0: never); s15-kbd-idle\nIDLE_OFF_BATTERY=30\nIDLE_OFF_AC=0\n' >> "$R/etc/s15-kbd-mode.conf"
cat > "$R/etc/systemd/system/s15-kbd-idle.service" <<'EOS'
[Unit]
Description=Keyboard light off without input on battery (s15-kbd-mode.conf)
[Service]
ExecStart=/usr/local/sbin/s15-kbd-idle
Restart=on-failure
RestartSec=10
Nice=5
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateNetwork=yes
NoNewPrivileges=yes
[Install]
WantedBy=multi-user.target
EOS
install -d "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/s15-kbd-idle.service "$R/etc/systemd/system/multi-user.target.wants/s15-kbd-idle.service"
cat > "$R/etc/systemd/system/s15-kbd-mode@.service" <<'EOS'
[Unit]
Description=Keyboard RGB for %i mode
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/s15-kbd-mode %i
EOS
install -d "$R/etc/polkit-1/rules.d"
cat > "$R/etc/polkit-1/rules.d/50-s15-kbd-mode.rules" <<'EOS'
// The desktop user may start the keyboard-colour units for the two session modes without a password.
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.systemd1.manage-units" && action.lookup("verb") == "start" &&
      subject.user == "steamos" &&
      (action.lookup("unit") == "s15-kbd-mode@game.service" || action.lookup("unit") == "s15-kbd-mode@desktop.service")) {
    return polkit.Result.YES;
  }
});
EOS
U="$R/usr/lib/systemd/user"
for m in game:gamescope-session.target desktop:plasma-workspace.target; do
  mode=${m%%:*}; target=${m#*:}
  cat > "$U/s15-kbd-$mode.service" <<EOS
[Unit]
Description=Keyboard RGB for $mode mode
After=$target
[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl start --no-block s15-kbd-mode@$mode.service
[Install]
WantedBy=$target
EOS
  install -d "$U/$target.wants"; ln -sfn "../s15-kbd-$mode.service" "$U/$target.wants/s15-kbd-$mode.service"
done
cat > "$R/usr/lib/systemd/system-sleep/s15-kbd-mode" <<'EOS'
#!/bin/sh
# Re-apply the session's keyboard colour after standby
[ "$1" = post ] && systemctl start --no-block s15-kbd-mode@resume.service
exit 0
EOS
chmod 0755 "$R/usr/lib/systemd/system-sleep/s15-kbd-mode"
echo "keyboard modes installed in $R"
