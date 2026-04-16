#!/usr/bin/bash
# Live-environment setup for the Dakota X13s ISO installer image.
# Adapted from projectbluefin/dakota-iso — X13s changes:
#   - arch references use arm64/aarch64
#   - installer desktop entry uses arm64 arch flag for flatpak run
#   - images.json points to dakota-x13s image

set -exo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── VERSION_ID ────────────────────────────────────────────────────────────────
if grep -q '^VERSION_ID=' /usr/lib/os-release 2>/dev/null; then
    sed -i 's/^VERSION_ID=.*/VERSION_ID=latest/' /usr/lib/os-release
else
    echo 'VERSION_ID=latest' >> /usr/lib/os-release
fi

# ── Live user ─────────────────────────────────────────────────────────────────
useradd --create-home --uid 1000 --user-group \
    --comment "Live User" liveuser || true
passwd --delete liveuser

if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "liveuser:live" | chpasswd
    passwd --unlock root
    echo "root:root" | chpasswd
    echo "liveuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/liveuser
    chmod 440 /etc/sudoers.d/liveuser
    mkdir -p /etc/systemd/system-preset
    echo "enable sshd.service" > /etc/systemd/system-preset/90-live-debug.preset
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /usr/lib/systemd/system/sshd.service \
        /etc/systemd/system/multi-user.target.wants/sshd.service
    cat >> /etc/ssh/sshd_config << 'SSHEOF'
PermitEmptyPasswords no
PasswordAuthentication yes
PermitRootLogin yes
SSHEOF

    cat > /usr/lib/systemd/system/debug-ssh-banner.service << 'BANNEREOF'
[Unit]
Description=Print SSH connection info to serial console
After=sshd.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  IP=$(hostname -I | awk "{print \$1}"); \
  echo ""; \
  echo "========================================"; \
  echo " DEBUG SSH READY"; \
  echo " ssh liveuser@${IP:-<no-ip>}  (password: live)"; \
  echo "========================================"; \
  echo ""'
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
BANNEREOF
    systemctl enable debug-ssh-banner.service
fi

echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/liveuser
chmod 0440 /etc/sudoers.d/liveuser

mkdir -p /home/liveuser/.config
touch /home/liveuser/.config/gnome-initial-setup-done
chown -R liveuser:liveuser /home/liveuser/.config

rm -f /usr/share/applications/org.gnome.Tour.desktop

# ── Installer desktop override (arm64) ───────────────────────────────────────
INSTALLER_APP_ID="org.bootcinstaller.Installer"
[[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]] && \
    INSTALLER_APP_ID="org.bootcinstaller.Installer.Devel"

mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/${INSTALLER_APP_ID}.desktop << DESKTOPEOF
[Desktop Entry]
Name=Dakota Installer
Exec=/usr/bin/flatpak run --branch=master --arch=aarch64 --command=bootc-installer ${INSTALLER_APP_ID}
Icon=dakota
Terminal=false
Type=Application
Categories=GTK;System;Settings;
StartupNotify=true
X-Flatpak=${INSTALLER_APP_ID}
DESKTOPEOF

# ── dconf settings ────────────────────────────────────────────────────────────
mkdir -p /etc/dconf/db/distro.d /etc/dconf/db/distro.d/locks
cat > /etc/dconf/db/distro.d/50-live-iso << 'DCONFEOF'
[org/gnome/shell]
welcome-dialog-last-shown-version='999'
favorite-apps=['dakota-installer.desktop', 'org.mozilla.firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Console.desktop']

[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
power-button-action='nothing'
DCONFEOF

cat > /etc/dconf/db/distro.d/locks/50-live-iso << 'LOCKSEOF'
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/idle-activation-enabled
/org/gnome/desktop/session/idle-delay
/org/gnome/shell/favorite-apps
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-timeout
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-timeout
LOCKSEOF

dconf update

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# ── GDM autologin ─────────────────────────────────────────────────────────────
mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf << 'GDMEOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=liveuser
GDMEOF

# ── /var/tmp tmpfs ────────────────────────────────────────────────────────────
cat > /usr/lib/systemd/system/var-tmp.mount << 'UNITEOF'
[Unit]
Description=Large tmpfs for /var/tmp in the live environment

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=8G,nr_inodes=1m

[Install]
WantedBy=local-fs.target
UNITEOF
systemctl enable var-tmp.mount

# ── Live-ready marker ─────────────────────────────────────────────────────────
cat > /usr/lib/systemd/system/live-ready.service << 'LREOF'
[Unit]
Description=Live environment ready marker
After=display-manager.service
Wants=display-manager.service

[Service]
Type=oneshot
ExecStart=/bin/echo DAKOTA_X13S_LIVE_READY
StandardOutput=journal+console

[Install]
WantedBy=display-manager.service
LREOF
systemctl enable live-ready.service

mkdir -p /var/fisherman-tmp

# ── Installer configuration ───────────────────────────────────────────────────
mkdir -p /etc/bootc-installer
cp "$SCRIPT_DIR/etc/bootc-installer/images.json" /etc/bootc-installer/images.json
touch /etc/bootc-installer/live-iso-mode

# ── Installer autostart ───────────────────────────────────────────────────────
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/tuna-installer.desktop << DTEOF
[Desktop Entry]
Name=Dakota Installer
Exec=flatpak run --env=VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
Icon=dakota
Type=Application
X-GNOME-Autostart-enabled=true
DTEOF

mkdir -p /usr/share/applications
cat > /usr/share/applications/dakota-installer.desktop << DTEOF
[Desktop Entry]
Name=Dakota Installer
Comment=Install Dakota to your ThinkPad X13s
Exec=flatpak run --env=VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
Icon=dakota
Type=Application
Categories=System;
NoDisplay=false
DTEOF

# ── Polkit for live installer ─────────────────────────────────────────────────
mkdir -p /usr/share/polkit-1/actions
cat > /usr/share/polkit-1/actions/org.bootcinstaller.Installer.policy << 'POLICYEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
  "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="org.tunaos.Installer.install">
    <description>Install an operating system to disk</description>
    <message>Authentication is required to install an operating system</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/fisherman</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
POLICYEOF

mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/99-live-installer.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.policykit.exec" ||
         action.id === "org.tunaos.Installer.install") &&
            subject.user === "liveuser" && subject.local) {
        return polkit.Result.YES;
    }
});
EOF

# ── VFS containers-storage ────────────────────────────────────────────────────
cat > /etc/containers/storage.conf << 'STOREOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
STOREOF

# ── skopeo wrapper (double-prefix fix + scratch dir) ─────────────────────────
cp /usr/bin/skopeo /usr/bin/skopeo.real
cp /usr/bin/podman /usr/bin/podman.real

cat > /usr/bin/skopeo << 'SKOPEOF'
#!/bin/bash
ARGS=()
for arg in "$@"; do
    ARGS+=("${arg/containers-storage:containers-storage:/containers-storage:}")
done
for target in /mnt/fisherman-target /var/mnt/fisherman-target; do
    if mountpoint -q "$target" 2>/dev/null; then
        SCRATCH="$target/@scratch"
        if [ ! -d "$SCRATCH" ]; then btrfs subvolume create "$SCRATCH"; fi
        DEV=$(findmnt -n -o SOURCE "$target" | head -1)
        mount -o subvol=@scratch "$DEV" "$SCRATCH"
        mkdir -p "$SCRATCH/var-tmp"
        mount --bind "$SCRATCH/var-tmp" /var/tmp
        [ -d /var/fisherman-tmp ] && mount --bind "$SCRATCH/var-tmp" /var/fisherman-tmp
        CS=/var/lib/containers/storage
        LOWER=/run/rootfsbase/var/lib/containers/storage
        if [ -d "$LOWER" ] && ! mountpoint -q "$CS" 2>/dev/null; then
            mkdir -p "$SCRATCH/cs-upper" "$SCRATCH/cs-work"
            mount -t overlay overlay \
                -o "lowerdir=$LOWER,upperdir=$SCRATCH/cs-upper,workdir=$SCRATCH/cs-work" \
                "$CS"
        fi
        break
    fi
done
exec /usr/bin/skopeo.real "${ARGS[@]}"
SKOPEOF
chmod +x /usr/bin/skopeo

cat > /usr/bin/podman << 'PODMEOF'
#!/bin/bash
exec /usr/bin/podman.real "$@"
PODMEOF
chmod +x /usr/bin/podman
