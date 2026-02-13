#!/bin/bash
set -euo pipefail

INSTALL_DIR="/opt/cpumonitor"
DESKTOP_FILE="/usr/share/applications/cpumonitor.desktop"
PYTHON="$(command -v python3 || true)"

# ── Helpers ──────────────────────────────────────────────────────

ask_yes_no() {
    # Safe prompt that works even when piped (defaults to yes on EOF)
    local prompt="$1"
    local answer
    if [ -t 0 ]; then
        read -rp "$prompt [Y/n] " answer
        [ "${answer,,}" = "n" ] && return 1
    fi
    return 0
}

# ── Preflight checks ────────────────────────────────────────────

if ! sudo -v 2>/dev/null; then
    echo "Error: This installer requires sudo access."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$SCRIPT_DIR/cpu_monitor.py" ]; then
    echo "Error: cpu_monitor.py not found next to install.sh"
    exit 1
fi

# ── Detect package manager and install dependencies ──────────────

install_deps() {
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        # Try ayatana first, fall back to legacy appindicator
        if apt-cache show gir1.2-ayatanaappindicator3-0.1 &>/dev/null; then
            local indicator_pkg="gir1.2-ayatanaappindicator3-0.1"
        else
            local indicator_pkg="gir1.2-appindicator3-0.1"
        fi
        sudo apt-get install -y -qq \
            python3 python3-psutil python3-gi python3-cairo \
            "$indicator_pkg" gir1.2-notify-0.7 \
            libnotify-bin
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y -q \
            python3 python3-psutil python3-gobject python3-cairo \
            libnotify || true
        # Indicator package name varies across Fedora versions
        sudo dnf install -y -q libayatana-appindicator-gtk3 2>/dev/null \
            || sudo dnf install -y -q libappindicator-gtk3 2>/dev/null \
            || echo "Warning: Could not install AppIndicator package. Tray icon may not work."
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm --needed \
            python python-psutil python-gobject python-cairo \
            libnotify
        # libayatana-appindicator is in the AUR on Arch
        if command -v yay &>/dev/null; then
            yay -S --noconfirm --needed libayatana-appindicator 2>/dev/null || true
        elif command -v paru &>/dev/null; then
            paru -S --noconfirm --needed libayatana-appindicator 2>/dev/null || true
        else
            echo "Warning: libayatana-appindicator is in the AUR."
            echo "Install it with your AUR helper for tray icon support."
        fi
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

# Kill running instance if reinstalling
if pgrep -f "python3.*cpu_monitor\.py" &>/dev/null; then
    echo "Stopping running instance..."
    pkill -f "python3.*cpu_monitor\.py" 2>/dev/null || true
    sleep 1
fi

echo "Installing dependencies..."
install_deps

# Find python3 (may have just been installed)
PYTHON="$(command -v python3 || true)"
if [ -z "$PYTHON" ]; then
    echo "Error: python3 not found after installing dependencies."
    exit 1
fi

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
Exec=$PYTHON $INSTALL_DIR/cpu_monitor.py
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
StartupNotify=false
EOF

echo ""
echo "Done! You can now:"
echo "  - Launch from your app menu (search 'CPU Monitor')"
echo "  - Or run: $PYTHON $INSTALL_DIR/cpu_monitor.py"
echo ""
echo "To uninstall: sudo rm -rf $INSTALL_DIR $DESKTOP_FILE"

# ── GNOME tray support ───────────────────────────────────────────

if [ "${XDG_CURRENT_DESKTOP:-}" = "GNOME" ]; then
    if ! gnome-extensions list 2>/dev/null | grep -q appindicatorsupport; then
        echo ""
        echo "GNOME does not show tray icons by default."
        echo "CPU Monitor needs the AppIndicator extension to display its tray icon."
        echo "This is a small, well-known extension that adds system tray support to GNOME."
        echo ""
        if ask_yes_no "Install the AppIndicator GNOME extension?"; then
            if command -v apt-get &>/dev/null; then
                sudo apt-get install -y -qq gnome-shell-extension-appindicator
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y -q gnome-shell-extension-appindicator
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm --needed gnome-shell-extension-appindicator
            elif command -v zypper &>/dev/null; then
                sudo zypper install -y gnome-shell-extension-appindicator
            fi
            gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com 2>/dev/null || true
            echo "Extension installed. You may need to log out and back in for it to take effect."
        else
            echo "Skipped. The tray icon will not be visible until the extension is installed."
        fi
    fi
fi
