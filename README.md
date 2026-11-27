# CPU Monitor

A lightweight tray/menu bar application that watches for runaway processes. The icon gradually changes color from green to yellow to red as a high-CPU process approaches the 60-second threshold. Click the icon at any time to see which process is responsible, at what CPU percentage, and for how long it has been running hot.

Available for **macOS**, **Linux**, and **Android**.

## Download

**[Download the latest release](https://github.com/michaelbrandi/CPUmonitor/releases/latest)**

| Platform | Download |
|----------|----------|
| macOS | `CPUMonitor-macOS.zip` — unzip and drag to Applications |
| Linux | `CPUMonitor-linux.tar.gz` — extract and run `./install.sh` |
| Android | `app-debug.apk` — install via `adb` or sideload |

## Install

### macOS

1. Download `CPUMonitor-macOS.zip` from the [latest release](https://github.com/michaelbrandi/CPUmonitor/releases/latest)
2. Unzip and drag `CPUMonitor.app` to your `/Applications` folder
3. Right-click the app and select **Open** (required once — the app is not notarized)
4. A green icon will appear in the menu bar

### Updating an existing install (macOS)

One command swaps `/Applications/CPUMonitor.app` for the newest published build — no Xcode or Swift needed on the target Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/michaelbrandi/CPUmonitor/master/macos-native/update.sh | bash
```

Pin a specific release with its tag:

```bash
curl -fsSL https://raw.githubusercontent.com/michaelbrandi/CPUmonitor/master/macos-native/update.sh | bash -s -- build-1a2b3c4
```

It stops the running copy, replaces the bundle, clears the quarantine flag, relaunches, and leaves the **Run On Login** setting untouched.

### Linux

```bash
tar xzf CPUMonitor-linux.tar.gz
cd CPUMonitor-linux
./install.sh
```

The installer auto-detects your package manager (apt, dnf, pacman, zypper) and installs all dependencies. The app is installed to `/opt/cpumonitor` and added to your application menu.

### Android

Download `app-debug.apk` and install via sideloading (enable "Install unknown apps" in settings), or:

```bash
adb install app-debug.apk
```

## Usage

A green system tray/menu bar icon will appear. Right-click it for options. When a process holds above 90% CPU, the icon gradually shifts from green through yellow to red over ~60 seconds.

- **macOS:** clicking the icon lists the offending processes above the menu options — name, PID, CPU % and how long they have been hot. No notifications are used, so Focus/Do Not Disturb can't hide them. A `lsof` process that stays above 90% CPU for 60 s is killed automatically (sync clients such as OneDrive are known to spin it); the menu then lists the kill, including which app spawned it, for the next hour.

An executable that keeps producing pinned instances — a crash/respawn loop where no single process lasts the full 60 s — is tracked as one ongoing burn, so it still turns the icon red and appears in the menu as `↻ name — N pinned instances · 3m 20s`. An instance only joins that group after staying above 90% for 10 s on its own, which keeps brief bursts (browser helpers, compiler jobs) from counting.
- **Linux / Android:** a desktop notification names the offending process and automatically dismisses when the CPU load drops.

## Autostart

Right-click the tray icon and select **Run On Login** to start the monitor automatically at login. Select again to disable.

## Testing

Simulate a CPU spike with:

```bash
# Linux / macOS
yes > /dev/null
```

Watch the icon change from green to yellow to red over ~60 seconds. On macOS, click the icon to see `yes` listed as the offending process; kill it and the icon returns to green.

## Build from source

### macOS

```bash
cd macos-native
./build.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`). The script compiles, signs, installs to `/Applications`, and launches the app automatically.

### Linux

No build step needed — the Python script runs directly after `./install.sh` installs dependencies.

### Android

```bash
cd android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
ANDROID_HOME="$HOME/Library/Android/sdk" \
./gradlew assembleDebug
```
