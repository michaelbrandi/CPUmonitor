# CPU Monitor

A lightweight tray/menu bar application that watches for runaway processes. The icon gradually changes color from green to yellow to red as a high-CPU process approaches the 60-second threshold. When any process holds above 90% CPU for more than 60 seconds, you get a desktop notification that automatically dismisses when the load drops.

Available for **Linux** (GTK3 tray app) and **macOS** (native Swift menu bar app).

## Install

Download the latest release from the [Releases page](https://github.com/michaelbrandi/CPUmonitor/releases).

### Linux

```bash
tar xzf CPUMonitor-linux.tar.gz
cd CPUMonitor-linux
./install.sh
```

The installer auto-detects your package manager (apt, dnf, pacman, zypper) and installs all dependencies. The app is installed to `/opt/cpumonitor` and added to your application menu.

### macOS

Download `CPUMonitor-macOS.zip`, unzip, and move `CPUMonitor.app` to your Applications folder. On first launch, right-click the app and select Open (required once since the app is not notarized).

## Run

A green system tray/menu bar icon will appear. Right-click it for options. When a process exceeds 90% CPU, the icon gradually shifts from green through yellow to red over 60 seconds.

## Autostart

Right-click the tray icon and check **Run On Login** to start the monitor automatically when you log in. Uncheck to disable.

## Testing

Simulate a CPU spike with:

```bash
# Linux
stress --cpu 1 --timeout 90

# macOS
yes > /dev/null
```

Watch the icon change from green to yellow to red over ~60 seconds, then a notification fires.
