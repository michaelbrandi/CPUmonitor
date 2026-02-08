#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing dependencies..."
sudo apt install -y \
    gir1.2-ayatanaappindicator3-0.1 \
    python3-gi \
    python3-psutil \
    libnotify-bin

echo "Generating cpumonitor.desktop..."
cat > "$SCRIPT_DIR/cpumonitor.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CPU Monitor
Comment=Monitor CPU usage and warn about runaway processes
Exec=/usr/bin/python3 $SCRIPT_DIR/cpu_monitor.py
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
StartupNotify=false
EOF

chmod +x "$SCRIPT_DIR/cpu_monitor.py"

echo ""
echo "Done! Run the monitor with:"
echo "  python3 $SCRIPT_DIR/cpu_monitor.py"
