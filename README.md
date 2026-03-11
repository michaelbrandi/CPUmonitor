# CPU Monitor

A lightweight tray/menu bar application that watches for runaway processes. The icon gradually changes color from green to yellow to red as a high-CPU process approaches the 60-second threshold. When any process holds above 90% CPU for more than 60 seconds, you get a desktop notification that automatically dismisses when the load drops.

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

A green system tray/menu bar icon will appear. Right-click it for options. When a process exceeds 90% CPU for more than 60 seconds, the icon gradually shifts from green through yellow to red, then a notification fires. The notification automatically dismisses when the CPU load drops.

## Autostart

Right-click the tray icon and select **Run On Login** to start the monitor automatically at login. Select again to disable.

## Testing

Simulate a CPU spike with:

```bash
# Linux / macOS
yes > /dev/null
```

Watch the icon change from green to yellow to red over ~60 seconds, then a notification fires and clears automatically when you kill the process.

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
