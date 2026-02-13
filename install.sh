#!/bin/bash
set -euo pipefail

INSTALL_DIR="/opt/cpumonitor"
DESKTOP_FILE="/usr/share/applications/cpumonitor.desktop"

# ── Detect package manager and install dependencies ──────────────

install_deps() {
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq \
            python3 python3-psutil python3-gi python3-cairo \
            gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 \
            libnotify-bin
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y -q \
            python3 python3-psutil python3-gobject python3-cairo \
            libayatana-appindicator-gtk3 libnotify
    elif command -v pacman &>/dev/null; then
        sudo pacman -Sy --noconfirm --needed \
            python python-psutil python-gobject python-cairo \
            libayatana-appindicator libnotify
    elif command -v zypper &>/dev/null; then
        sudo zypper install -y \
            python3 python3-psutil python3-gobject python3-cairo \
            typelib-1_0-AyatanaAppIndicator3-0_1 libnotify-tools
    else
        echo "Could not detect package manager. Please install these manually:"
        echo "  python3, psutil, PyGObject, pycairo, AyatanaAppIndicator3, libnotify"
        exit 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────

echo "Installing CPU Monitor..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$SCRIPT_DIR/cpu_monitor.py" ]; then
    echo "Error: cpu_monitor.py not found next to install.sh"
    exit 1
fi

echo "Installing dependencies..."
install_deps

echo "Installing to $INSTALL_DIR..."
sudo mkdir -p "$INSTALL_DIR"
sudo cp "$SCRIPT_DIR/cpu_monitor.py" "$INSTALL_DIR/cpu_monitor.py"
sudo chmod +x "$INSTALL_DIR/cpu_monitor.py"

echo "Creating desktop entry..."
sudo tee "$DESKTOP_FILE" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=CPU Monitor
Comment=Monitor CPU usage and warn about runaway processes
Exec=/usr/bin/python3 $INSTALL_DIR/cpu_monitor.py
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
StartupNotify=false
EOF

echo ""
echo "Done! You can now:"
echo "  - Launch from your app menu (search 'CPU Monitor')"
echo "  - Or run: python3 $INSTALL_DIR/cpu_monitor.py"
echo ""
echo "To uninstall: sudo rm -rf $INSTALL_DIR $DESKTOP_FILE"

# ── GNOME tray support check ────────────────────────────────────

if [ "${XDG_CURRENT_DESKTOP:-}" = "GNOME" ]; then
    if ! gnome-extensions list 2>/dev/null | grep -q appindicatorsupport; then
        echo ""
        echo "NOTE: You are running GNOME, which does not show tray icons by default."
        echo "Install the AppIndicator extension for the tray icon to appear:"
        echo "  sudo apt install gnome-shell-extension-appindicator  (Debian/Ubuntu)"
        echo "  sudo dnf install gnome-shell-extension-appindicator  (Fedora)"
        echo "Then log out and back in, and enable it in the Extensions app."
    fi
fi
