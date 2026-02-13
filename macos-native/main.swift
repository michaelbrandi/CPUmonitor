// CPU Monitor for macOS — native menu bar app, zero third-party dependencies.
//
// Build:  ./build.sh
// Run:    open build/CPUMonitor.app
// Test:   yes > /dev/null  (or: stress --cpu 1 --timeout 90)

import AppKit
import UserNotifications

// MARK: - Constants

private let cpuThreshold    = 90.0
private let durationThreshold: TimeInterval = 60
private let checkInterval: TimeInterval = 5

private let launchAgentDir  = NSString("~/Library/LaunchAgents").expandingTildeInPath
private let launchAgentID   = "com.cpumonitor"
private let launchAgentFile = (launchAgentDir as NSString).appendingPathComponent("\(launchAgentID).plist")

// MARK: - Per-process CPU sampling via libproc

private struct ProcessSnapshot {
    let pid: pid_t
    let name: String
    let cpuTimeNs: UInt64       // user + system, in nanoseconds
}

private func sampleAllProcesses() -> [pid_t: ProcessSnapshot] {
    var result: [pid_t: ProcessSnapshot] = [:]

    // Ask for the buffer size needed
    let bufferBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard bufferBytes > 0 else { return result }

    let pidCount = Int(bufferBytes) / MemoryLayout<pid_t>.size
    var pids = [pid_t](repeating: 0, count: pidCount + 16)
    let actualBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferBytes)
    let actualCount = Int(actualBytes) / MemoryLayout<pid_t>.size

    // Mach timebase for converting absolute time → nanoseconds
    // (1:1 on Apple Silicon, differs on Intel)
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)

    for i in 0..<actualCount {
        let pid = pids[i]
        guard pid > 0 else { continue }

        var info = proc_taskinfo()
        let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize) == infoSize else {
            continue
        }

        var nameBuf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuf, 256)
        let name = String(cString: nameBuf)
        guard !name.isEmpty else { continue }

        let totalTicks = info.pti_total_user + info.pti_total_system
        let totalNs = totalTicks * UInt64(tb.numer) / UInt64(tb.denom)

        result[pid] = ProcessSnapshot(pid: pid, name: name, cpuTimeNs: totalNs)
    }
    return result
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private var icons: [NSImage] = []
    private var autoStartMenuItem: NSMenuItem!

    // CPU tracking state
    private var highCPUStart: [pid_t: TimeInterval] = [:]
    private var alertedPIDs: [pid_t: String] = [:]  // PID -> notification identifier
    private var previousSample: [pid_t: (cpuNs: UInt64, wallNs: UInt64)] = [:]

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        generateIcons()
        setupStatusItem()
        requestNotificationPermission()

        // Prime the first sample so the next tick can compute deltas
        let snapshot = sampleAllProcesses()
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        for (pid, snap) in snapshot {
            previousSample[pid] = (cpuNs: snap.cpuTimeNs, wallNs: now)
        }

        Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkCPU()
        }
    }

    // MARK: Icons (green → yellow → red, drawn with AppKit)

    private func generateIcons() {
        let size = NSSize(width: 22, height: 22)
        for step in 0...12 {
            let t = CGFloat(step) / 12.0
            let r = min(t * 2.0, 1.0)
            let g = min((1.0 - t) * 2.0, 1.0)

            let image = NSImage(size: size, flipped: false) { rect in
                let circleRect = rect.insetBy(dx: 1, dy: 1)
                let path = NSBezierPath(ovalIn: circleRect)

                NSColor(red: r, green: g, blue: 0, alpha: 1).setFill()
                path.fill()

                NSColor(red: r * 0.5, green: g * 0.5, blue: 0, alpha: 1).setStroke()
                path.lineWidth = 1
                path.stroke()

                return true
            }
            image.isTemplate = false
            icons.append(image)
        }
    }

    // MARK: Status item (menu bar)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = icons[0]

        let menu = NSMenu()

        autoStartMenuItem = NSMenuItem(title: "Run On Login",
                                       action: #selector(toggleAutoStart),
                                       keyEquivalent: "")
        autoStartMenuItem.target = self
        autoStartMenuItem.state = FileManager.default.fileExists(atPath: launchAgentFile) ? .on : .off
        menu.addItem(autoStartMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: CPU check

    private func checkCPU() {
        let snapshot = sampleAllProcesses()
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        var currentHighPIDs: Set<pid_t> = []

        for (pid, current) in snapshot {
            guard let prev = previousSample[pid] else { continue }

            let deltaCPU  = current.cpuTimeNs > prev.cpuNs ? current.cpuTimeNs - prev.cpuNs : 0
            let deltaWall = now > prev.wallNs ? now - prev.wallNs : 1
            let cpuPercent = Double(deltaCPU) / Double(deltaWall) * 100.0

            if cpuPercent >= cpuThreshold {
                currentHighPIDs.insert(pid)
                let mono = ProcessInfo.processInfo.systemUptime

                if highCPUStart[pid] == nil {
                    highCPUStart[pid] = mono
                } else if let start = highCPUStart[pid],
                          mono - start >= durationThreshold,
                          alertedPIDs[pid] == nil {
                    let notifID = sendNotification(name: current.name, pid: pid, cpu: cpuPercent)
                    alertedPIDs[pid] = notifID
                }
            }
        }

        // Update previous sample for every live process
        for (pid, snap) in snapshot {
            previousSample[pid] = (cpuNs: snap.cpuTimeNs, wallNs: now)
        }
        // Prune dead PIDs
        let alive = Set(snapshot.keys)
        for pid in previousSample.keys where !alive.contains(pid) {
            previousSample.removeValue(forKey: pid)
        }

        // Cleanup PIDs that dropped below threshold
        for pid in Set(highCPUStart.keys).subtracting(currentHighPIDs) {
            highCPUStart.removeValue(forKey: pid)
            if let notifID = alertedPIDs.removeValue(forKey: pid) {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notifID])
            }
        }

        // Update tray icon
        let iconIndex: Int
        if !highCPUStart.isEmpty {
            let mono = ProcessInfo.processInfo.systemUptime
            let maxDur = highCPUStart.values.map { mono - $0 }.max() ?? 0
            let progress = min(maxDur / durationThreshold, 1.0)
            iconIndex = Int((progress * 12).rounded())
        } else {
            iconIndex = 0
        }
        statusItem.button?.image = icons[iconIndex]
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @discardableResult
    private func sendNotification(name: String, pid: pid_t, cpu: Double) -> String {
        let content = UNMutableNotificationContent()
        content.title = "High CPU Usage"
        content.subtitle = "\(name) (PID \(pid))"
        content.body = "Has been using \(Int(cpu))% CPU for over \(Int(durationThreshold))s"
        content.sound = .default

        let identifier = "cpu-\(pid)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        return identifier
    }

    // Show notification banner even when the app is in the foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    // MARK: Run On Login (LaunchAgent plist)

    @objc private func toggleAutoStart() {
        let enable = autoStartMenuItem.state == .off

        if enable {
            let execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            let plist: [String: Any] = [
                "Label": launchAgentID,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            try? FileManager.default.createDirectory(atPath: launchAgentDir,
                                                     withIntermediateDirectories: true)
            (plist as NSDictionary).write(toFile: launchAgentFile, atomically: true)
            autoStartMenuItem.state = .on
        } else {
            try? FileManager.default.removeItem(atPath: launchAgentFile)
            autoStartMenuItem.state = .off
        }
    }

    // MARK: Quit

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
