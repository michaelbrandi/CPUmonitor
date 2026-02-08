#!/usr/bin/env python3

import os
import signal
import time

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
gi.require_version("Notify", "0.7")
from gi.repository import Gtk, GLib, AyatanaAppIndicator3, Notify

import psutil

CPU_THRESHOLD = 90.0
DURATION_THRESHOLD = 60
CHECK_INTERVAL = 5

AUTOSTART_DIR = os.path.expanduser("~/.config/autostart")
AUTOSTART_FILE = os.path.join(AUTOSTART_DIR, "cpumonitor.desktop")


class CPUMonitor:
    def __init__(self):
        Notify.init("CPU Monitor")

        self.indicator = AyatanaAppIndicator3.Indicator.new(
            "cpu-monitor",
            "utilities-system-monitor",
            AyatanaAppIndicator3.IndicatorCategory.SYSTEM_SERVICES,
        )
        self.indicator.set_status(AyatanaAppIndicator3.IndicatorStatus.ACTIVE)

        self.indicator.set_menu(self._build_menu())

        self.high_cpu_start = {}  # PID -> monotonic timestamp
        self.alerted_pids = set()

        # Prime psutil — first cpu_percent call always returns 0
        psutil.cpu_percent()

        GLib.timeout_add_seconds(CHECK_INTERVAL, self._check_cpu)

        signal.signal(signal.SIGINT, lambda *_: self._on_quit(None))

    def _build_menu(self):
        menu = Gtk.Menu()

        self.autostart_item = Gtk.CheckMenuItem(label="Run On Login")
        self.autostart_item.set_active(os.path.exists(AUTOSTART_FILE))
        self.autostart_item.connect("toggled", self._on_autostart_toggled)
        menu.append(self.autostart_item)

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", self._on_quit)
        menu.append(quit_item)

        menu.show_all()
        return menu

    def _check_cpu(self):
        current_pids = set()

        for proc in psutil.process_iter(["pid", "name", "cpu_percent"]):
            try:
                info = proc.info
                pid = info["pid"]
                cpu = info["cpu_percent"]

                if cpu is None:
                    continue

                if cpu >= CPU_THRESHOLD:
                    current_pids.add(pid)
                    now = time.monotonic()

                    if pid not in self.high_cpu_start:
                        self.high_cpu_start[pid] = now

                    elif (now - self.high_cpu_start[pid] >= DURATION_THRESHOLD
                          and pid not in self.alerted_pids):
                        self._send_notification(info["name"], pid, cpu)
                        self.alerted_pids.add(pid)

            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

        # Cleanup PIDs that dropped below threshold
        gone = set(self.high_cpu_start) - current_pids
        for pid in gone:
            del self.high_cpu_start[pid]
            self.alerted_pids.discard(pid)

        return True

    def _send_notification(self, name, pid, cpu):
        summary = "High CPU Usage"
        body = f"<b>{name}</b> (PID {pid}) has been using {cpu:.0f}% CPU for over {DURATION_THRESHOLD}s"
        n = Notify.Notification.new(summary, body, "dialog-warning")
        n.set_urgency(Notify.Urgency.CRITICAL)
        n.show()

    def _desktop_entry(self):
        script = os.path.abspath(__file__)
        return (
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=CPU Monitor\n"
            "Comment=Monitor CPU usage and warn about runaway processes\n"
            f"Exec=/usr/bin/python3 {script}\n"
            "Icon=utilities-system-monitor\n"
            "Terminal=false\n"
            "Categories=System;Monitor;\n"
            "StartupNotify=false\n"
        )

    def _on_autostart_toggled(self, widget):
        if widget.get_active():
            os.makedirs(AUTOSTART_DIR, exist_ok=True)
            with open(AUTOSTART_FILE, "w") as f:
                f.write(self._desktop_entry())
        else:
            try:
                os.remove(AUTOSTART_FILE)
            except FileNotFoundError:
                pass

    def _on_quit(self, _widget):
        Notify.uninit()
        Gtk.main_quit()


if __name__ == "__main__":
    CPUMonitor()
    Gtk.main()
