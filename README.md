# CPU Monitor

A lightweight Linux tray application that watches for runaway processes. When any process holds above 90% CPU for more than 60 seconds, you get a desktop notification.

## Prerequisites

- Linux with a GTK 3 desktop environment (Cinnamon, MATE, XFCE, etc.)
- Python 3

## Install

```bash
git clone <repo-url> && cd CPUmonitor
./install.sh
```

The install script will:
- Install required system packages via apt
- Generate a `cpumonitor.desktop` launcher with the correct paths

## Run

```bash
python3 cpu_monitor.py
```

A system tray icon will appear. Right-click it for options.

## Autostart

Right-click the tray icon and check **Run On Login** to start the monitor automatically when you log in. Uncheck to disable.

## Testing

Simulate a CPU spike with:

```bash
stress --cpu 1 --timeout 90
```

You should see a notification after ~60 seconds. Install `stress` with `sudo apt install stress` if needed.
