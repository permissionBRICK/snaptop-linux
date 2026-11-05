#!/bin/bash
# Desktop Mode for the Steam Frame SteamOS build on a laptop: the Frame's plasma.desktop starts a nested
# "Gamescope VR Session" (plasma-session.target + steamvr-plasma). Replace it with a real Plasma Wayland
# session on the panel, as on a Steam Deck. Adapted from SteamOS-ARM-Port (sm8550-startplasma/prepare-plasma).
# Usage: R=<root> steamos-s15-desktop.sh   (R=/ on the running system)
set -euo pipefail
R=${R:-/}
bak() { [ -e "$1" ] && [ ! -e "$1.frame" ] && cp -a "$1" "$1.frame" || true; }

install -d "$R/usr/lib/steamos"
cat > "$R/usr/lib/steamos/s15-prepare-plasma" <<'EOF'
#!/bin/bash
# Leave nothing from the gamescope (Game Mode) session in the environment of the Plasma session.
set -u
mkdir -p /tmp/.X11-unix 2>/dev/null; chmod 1777 /tmp/.X11-unix 2>/dev/null || true
# gamescope-cleanup blanks DISPLAY/WAYLAND_DISPLAY/XDG_SESSION_TYPE/... (VAR=) in the activation environment.
# Only before the switch: inside the Plasma start it raced KWin's own import and left Plasma without a display.
[[ "${1:-}" == --switch && -f /usr/lib/steamos/gamescope-cleanup ]] && bash /usr/lib/steamos/gamescope-cleanup >/dev/null 2>&1
vars=(GAMESCOPE_WAYLAND_DISPLAY GAMESCOPE_STATS GAMESCOPE_READY_NOTIFY_SOCKET _STEAM_SETENV_MANAGER SteamDeck
      STEAM_DISPLAY_REFRESH_LIMITS GAMESCOPE_MANGOAPP_SOCKET_DISABLE ENABLE_GAMESCOPE_WSI XDG_SESSION_DESKTOP
      STEAM_USE_MANGOAPP MANGOHUD_CONFIGFILE)
# Before the switch (called from steamos-session-select) the display variables still point at gamescope.
# Inside the Plasma start (s15-plasma-env.service) they are Plasma's own and must stay.
[[ "${1:-}" == --switch ]] && vars+=(QT_QPA_PLATFORM DISPLAY WAYLAND_DISPLAY)
systemctl --user unset-environment "${vars[@]}" 2>/dev/null || true
dbus-update-activation-environment "${vars[@]/%/=}" >/dev/null 2>&1 || true
rm -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gamescope-steam.env"
for lock in /tmp/.X[0-9]*-lock; do
  [[ -f "$lock" ]] || continue
  pid="$(tr -dc 0-9 <"$lock" 2>/dev/null)"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then n="${lock#/tmp/.X}"; n="${n%-lock}"; rm -f "$lock" "/tmp/.X11-unix/X$n"; fi
done
exit 0
EOF
cat > "$R/usr/lib/steamos/s15-startplasma" <<'EOF'
#!/bin/bash
/usr/lib/steamos/s15-prepare-plasma --switch
unset GAMESCOPE_WAYLAND_DISPLAY QT_QPA_PLATFORM DISPLAY WAYLAND_DISPLAY XDG_SESSION_DESKTOP
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE
exec /usr/bin/startplasma-wayland "$@"
EOF
chmod 0755 "$R/usr/lib/steamos/s15-prepare-plasma" "$R/usr/lib/steamos/s15-startplasma"

bak "$R/usr/share/wayland-sessions/plasma.desktop"
cat > "$R/usr/share/wayland-sessions/plasma.desktop" <<'EOF'
[Desktop Entry]
Encoding=UTF-8
Type=Application
Name=Plasma (Wayland)
Comment=KDE Plasma desktop on Wayland (laptop panel, not the Frame VR session)
Exec=/usr/lib/steamos/s15-startplasma
TryExec=/usr/bin/startplasma-wayland
DesktopNames=KDE
EOF

U="$R/usr/lib/systemd/user"
cat > "$U/s15-plasma-env.service" <<'EOF'
[Unit]
Description=Clear Game Mode environment before Plasma starts
ConditionUser=!root
DefaultDependencies=no
Before=plasma-core.target plasma-workspace.target plasma-workspace-wayland.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/steamos/s15-prepare-plasma
EOF
for t in plasma-core.target plasma-workspace.target plasma-workspace-wayland.target; do
  install -d "$U/$t.d"
  printf '[Unit]\nWants=s15-plasma-env.service\nAfter=s15-plasma-env.service\n' > "$U/$t.d/99-s15.conf"
done
for s in plasma-plasmashell plasma-ksplash plasma-ksmserver plasma-kcminit plasma-kcminit-phase1 plasma-kded6 \
         plasma-kwin_wayland plasma-gmenudbusmenuproxy plasma-xembedsniproxy plasma-kaccess plasma-powerdevil \
         plasma-polkit-agent plasma-kglobalaccel plasma-kscreen plasma-xdg-desktop-portal-kde plasma-krunner \
         plasma-kactivitymanagerd plasma-dolphin plasma-ksystemstats plasma-restoresession plasma-baloorunner; do
  install -d "$U/$s.service.d"
  # "wayland;xcb": apps started from Plasma inherit it; an X11-only Qt app (a Flatpak without the Wayland socket,
  # e.g. Thincast) falls back to Xwayland instead of aborting with "no Qt platform plugin could be initialized".
  printf '[Service]\nEnvironment=QT_QPA_PLATFORM=wayland;xcb\nEnvironment=XDG_SESSION_TYPE=wayland\nEnvironment=XDG_CURRENT_DESKTOP=KDE\nEnvironment=XDG_SESSION_DESKTOP=KDE\nUnsetEnvironment=GAMESCOPE_WAYLAND_DISPLAY\n' > "$U/$s.service.d/99-s15-wayland.conf"
done

S="$R/usr/bin/steamos-session-select"
bak "$S"
sed -i 's#s15-prepare-plasma || true#s15-prepare-plasma --switch || true#' "$S"
if ! grep -q s15-prepare-plasma "$S"; then
  sed -i 's|^\(\s*\)steamosctl switch-to-desktop-mode|\1/usr/lib/steamos/s15-prepare-plasma --switch \|\| true\n\1steamosctl switch-to-desktop-mode|' "$S"
fi
# 60 Hz on battery, 120 Hz on AC in Desktop Mode (user service in the Plasma session)
install -D -m0755 "$(dirname "$0")/s15-refresh-on-battery" "$R/usr/local/bin/s15-refresh-on-battery"
cat > "$U/s15-refresh-on-battery.service" <<'EOF2'
[Unit]
Description=Internal panel 60 Hz on battery, 120 Hz on AC
PartOf=graphical-session.target
After=plasma-workspace.target
[Service]
ExecStart=/usr/local/bin/s15-refresh-on-battery
Restart=on-failure
RestartSec=10
[Install]
WantedBy=plasma-workspace.target
EOF2
install -d "$U/plasma-workspace.target.wants"
ln -sfn ../s15-refresh-on-battery.service "$U/plasma-workspace.target.wants/s15-refresh-on-battery.service"

# Boot into Desktop Mode by default (DEFAULT_MODE=game keeps Game Mode). "Return to Gaming Mode" and Steam's
# "Switch to Desktop" then switch for the current boot only: steamos-manager keeps the default login session in
# zz-steamos-autologin.conf and one-off switches in zzt-steamos-temp-login.conf.
sed -i '/^  gamescope)$/,/;;/{/steamosctl set-default-login-mode game/d}' "$S"
if [ "${DEFAULT_MODE:-desktop}" = desktop ]; then
  install -d "$R/etc/sddm.conf.d"
  printf '[Autologin]\nSession=plasma.desktop\n' > "$R/etc/sddm.conf.d/zz-steamos-autologin.conf"
fi
# Steam in Desktop Mode: the Frame autostart runs "steam -deckard" (client branch linux_arm64_beta_*), Game Mode
# runs "-steamdeck -steamos3" (steamdeck_stable). Every mode switch then changed the client branch and Steam
# downloaded the other build first (a minute of black screen). Start the desktop client as a Deck client too,
# like SteamOS on a Steam Deck: user-level overrides of the autostart and menu entries.
H="$R/home/steamos"; install -d "$H/.config/autostart" "$H/.local/share/applications"
sed 's#^Exec=/usr/bin/steam -silent -vrdisable -deckard %U#Exec=/usr/bin/steam -silent -vrdisable -steamdeck -steamos3 %U#' \
  "$R/etc/xdg/autostart/steam.desktop" > "$H/.config/autostart/steam.desktop"
awk 'BEGIN{d=0} /^Exec=\/usr\/bin\/steam %U$/ && !d {print "Exec=/usr/bin/steam -steamdeck -steamos3 %U"; d=1; next} {print}' \
  "$R/usr/share/applications/steam.desktop" > "$H/.local/share/applications/steam.desktop"
chown -R 1000:1000 "$H/.config" "$H/.local/share/applications" 2>/dev/null || true

# The Frame image has no Steam Deck desktop icons; add "Return to Gaming Mode".
D="$R/home/steamos/Desktop"
install -d "$D"
cat > "$D/Return.desktop" <<'EOF'
[Desktop Entry]
Name=Return to Gaming Mode
Exec=steamos-session-select gamescope
Icon=steamdeck-gaming-return
Terminal=false
Type=Application
StartupNotify=false
EOF
# The Frame image has no Plasma network/Bluetooth applets (plasma-nm, bluedevil); NetworkManager's text UI works.
cat > "$D/WiFi.desktop" <<'EOF2'
[Desktop Entry]
Name=Wi-Fi
Comment=Connect to a Wi-Fi network (NetworkManager text UI)
Exec=konsole --hide-menubar -e nmtui connect
Icon=network-wireless
Terminal=false
Type=Application
StartupNotify=false
EOF2
chmod 0755 "$D/Return.desktop" "$D/WiFi.desktop"; chown -R 1000:1000 "$D" 2>/dev/null || true
# Battery and Bluetooth stay visible in the system tray. Both hide themselves in the tray's overflow when they have
# nothing to report: on AC with the battery not charging (the normal state with a charge limit), no Bluetooth device
# connected. A Plasma update script runs once per user at the next Plasma start (also after a new user's default
# panel is created); a later change in the tray settings stays.
U="$R/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates"
install -d "$U"
cat > "$U/s15-systray-always-shown.js" <<'EOF3'
// snaptop-linux: show Power and Battery and Bluetooth always in the system tray (docs/steamos.md)
const always = ["org.kde.plasma.battery", "org.kde.plasma.bluetooth"];
const asList = v => Array.isArray(v) ? v : (v ? String(v).split(",").filter(s => s.length) : []);
function showAlways(obj) {
    obj.currentConfigGroup = ["General"];
    const shown = asList(obj.readConfig("shownItems", []));
    const hidden = asList(obj.readConfig("hiddenItems", [])).filter(i => !always.includes(i));
    for (const i of always) if (!shown.includes(i)) shown.push(i);
    obj.writeConfig("shownItems", shown);
    obj.writeConfig("hiddenItems", hidden);
    obj.reloadConfig();
}
for (const cont of desktops().concat(panels())) {
    for (const systray of cont.widgets("org.kde.plasma.systemtray")) {
        // Plasma 6.6 keeps the tray's item lists in the widget's own General group; older versions in an inner
        // containment (SystrayContainmentId)
        const inner = desktopById(Number(systray.readConfig("SystrayContainmentId", 0)));
        showAlways(inner || systray);
    }
}
EOF3
echo "desktop mode adapted in $R"
