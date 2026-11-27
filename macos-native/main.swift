// CPU Monitor for macOS — native menu bar app, zero third-party dependencies.
//
// Build:  ./build.sh
// Run:    open build/CPUMonitor.app
// Test:   yes > /dev/null  (or: stress --cpu 1 --timeout 90)

import AppKit

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
    let path: String            // full executable path, for grouping restarts
    let cpuTimeNs: UInt64       // user + system, in nanoseconds
}

// A process currently above the threshold, as shown in the menu.
private struct Offender {
    let pid: pid_t
    let name: String
    let cpu: Double             // % of one core, at the last sample
    let since: TimeInterval     // system uptime when it crossed the threshold
}

// The same executable burning CPU through instance after instance, none of
// which alone lasts the full threshold — a crash/respawn loop.
private struct ChurnGroup {
    let name: String
    var start: TimeInterval        // when the first qualifying instance was pinned
    var lastActive: TimeInterval   // last tick with a qualifying instance
    var pids: Set<pid_t>           // instances seen since `start`
}

// A process this app killed, kept for a while so the menu can explain itself.
private struct KillRecord {
    let pid: pid_t
    let name: String
    let spawner: String         // parent process, e.g. OneDrive
    let cpu: Double
    let at: TimeInterval        // system uptime when it was killed
}

// Full executable path, used to group restarts of the same binary.
private func processExecutablePath(pid: pid_t) -> String {
    var pathBuf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return "" }
    return String(cString: pathBuf)
}

// Full executable name (e.g. qemu-system-aarch64-headless) instead of the
// 16-character p_comm that proc_name() returns.
private func processDisplayName(path: String, pid: pid_t) -> String {
    let base = (path as NSString).lastPathComponent
    if !base.isEmpty { return base }
    var nameBuf = [CChar](repeating: 0, count: 256)
    proc_name(pid, &nameBuf, 256)
    return String(cString: nameBuf)
}

private func processDisplayName(pid: pid_t) -> String {
    processDisplayName(path: processExecutablePath(pid: pid), pid: pid)
}

private let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "sudo", "env", "nohup"]

private func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { return nil }
    let ppid = pid_t(info.pbi_ppid)
    return ppid > 0 ? ppid : nil
}

// Name of the process that spawned `pid` (e.g. the OneDrive helper behind a
// spinning lsof). Shells are skipped so `sh -c lsof …` reports the app that
// ran the shell, not "sh". Empty if it can't be read.
private func parentDisplayName(pid: pid_t) -> String {
    var current = pid
    for _ in 0..<4 {
        guard let ppid = parentPID(of: current), ppid > 1 else { return "launchd" }
        let name = processDisplayName(pid: ppid)
        if name.isEmpty { return "" }
        if !shellNames.contains(name) { return name }
        current = ppid
    }
    return ""
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

        let path = processExecutablePath(pid: pid)
        let name = processDisplayName(path: path, pid: pid)
        guard !name.isEmpty else { continue }

        let totalTicks = info.pti_total_user + info.pti_total_system
        let totalNs = totalTicks * UInt64(tb.numer) / UInt64(tb.denom)

        result[pid] = ProcessSnapshot(pid: pid, name: name, path: path, cpuTimeNs: totalNs)
    }
    return result
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var icons: [NSImage] = []
    private var autoStartMenuItem: NSMenuItem!

    // CPU tracking state
    private var highCPUStart: [pid_t: TimeInterval] = [:]
    private var previousSample: [pid_t: (cpuNs: UInt64, wallNs: UInt64)] = [:]
    private var lastCPU: [pid_t: Double] = [:]
    private var lastName: [pid_t: String] = [:]
    private var lastPath: [pid_t: String] = [:]
    private var killedPIDs: Set<pid_t> = []

    // What the menu shows; refreshed every checkInterval
    private var offenders: [Offender] = []
    private var churnGroups: [String: ChurnGroup] = [:]   // keyed by executable path
    private var recentKills: [KillRecord] = []
    private let dynamicTag = 9001

    // An instance must burn this long on its own before it joins a churn
    // group, and the group survives a gap this long between instances.
    private let churnInstanceMinDuration: TimeInterval = 10
    private let churnGrace: TimeInterval = 12
    private let churnMinInstances = 2

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        generateIcons()
        setupStatusItem()

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
        statusItem.button?.toolTip = "CPU Monitor"

        let menu = NSMenu()
        menu.delegate = self       // fills in the offender list when the menu opens

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
        let mono = ProcessInfo.processInfo.systemUptime
        var currentHighPIDs: Set<pid_t> = []

        for (pid, current) in snapshot {
            guard let prev = previousSample[pid] else { continue }

            let deltaCPU  = current.cpuTimeNs > prev.cpuNs ? current.cpuTimeNs - prev.cpuNs : 0
            let deltaWall = now > prev.wallNs ? now - prev.wallNs : 1
            let cpuPercent = Double(deltaCPU) / Double(deltaWall) * 100.0

            lastCPU[pid] = cpuPercent
            lastName[pid] = current.name
            lastPath[pid] = current.path

            guard cpuPercent >= cpuThreshold else { continue }
            currentHighPIDs.insert(pid)

            if highCPUStart[pid] == nil {
                highCPUStart[pid] = mono
            } else if let start = highCPUStart[pid],
                      mono - start >= durationThreshold,
                      !killedPIDs.contains(pid),
                      current.name == "lsof" {
                // Kill stuck lsof (sync clients spin it). EPERM = not our
                // process, skip. Read the spawner before the pid disappears.
                let spawner = parentDisplayName(pid: pid)
                if kill(pid, SIGKILL) == 0 {
                    killedPIDs.insert(pid)
                    recentKills.insert(KillRecord(pid: pid, name: current.name,
                                                  spawner: spawner, cpu: cpuPercent,
                                                  at: mono), at: 0)
                    if recentKills.count > 5 { recentKills.removeLast() }
                }
            }
        }

        // Update previous sample for every live process
        for (pid, snap) in snapshot {
            previousSample[pid] = (cpuNs: snap.cpuTimeNs, wallNs: now)
        }
        // Prune dead PIDs
        let alive = Set(snapshot.keys)
        for pid in Array(previousSample.keys) where !alive.contains(pid) {
            previousSample.removeValue(forKey: pid)
        }
        for pid in Array(lastCPU.keys) where !alive.contains(pid) {
            lastCPU.removeValue(forKey: pid)
            lastName.removeValue(forKey: pid)
            lastPath.removeValue(forKey: pid)
        }
        killedPIDs = killedPIDs.filter { alive.contains($0) }
        recentKills.removeAll { mono - $0.at > 3600 }

        // Stop tracking PIDs that dropped below the threshold
        for pid in Set(highCPUStart.keys).subtracting(currentHighPIDs) {
            highCPUStart.removeValue(forKey: pid)
        }

        // Snapshot for the menu — longest-burning first
        offenders = currentHighPIDs.compactMap { pid in
            guard let start = highCPUStart[pid], let name = lastName[pid] else { return nil }
            return Offender(pid: pid, name: name, cpu: lastCPU[pid] ?? 0, since: start)
        }
        .sorted { $0.since < $1.since }

        // Failure that restarts: group pinned instances by executable so a
        // crash/respawn loop accumulates across PIDs. An instance only joins
        // the group once it has been pinned for churnInstanceMinDuration on its
        // own, which keeps brief bursts (browser helpers, compiler jobs) out.
        let pinnedPaths = Set(currentHighPIDs.compactMap { lastPath[$0] }.filter { !$0.isEmpty })
        var qualified: [String: (start: TimeInterval, pids: Set<pid_t>)] = [:]
        for pid in currentHighPIDs {
            guard let start = highCPUStart[pid], mono - start >= churnInstanceMinDuration else { continue }
            let path = lastPath[pid] ?? ""
            guard !path.isEmpty else { continue }
            var entry = qualified[path] ?? (start: start, pids: [])
            entry.start = min(entry.start, start)
            entry.pids.insert(pid)
            qualified[path] = entry
        }

        // A live group survives while the executable keeps producing pinned
        // instances (a respawn gap is bridged by the next one starting), and
        // for churnGrace after the last one disappears.
        for (path, group) in Array(churnGroups) {
            let alive = pinnedPaths.contains(path) || qualified[path] != nil
            if alive && mono - group.lastActive <= churnGrace {
                var updated = group
                updated.lastActive = mono
                if let q = qualified[path] { updated.pids.formUnion(q.pids) }
                churnGroups[path] = updated
            } else if mono - group.lastActive > churnGrace {
                churnGroups.removeValue(forKey: path)
            }
        }
        for (path, q) in qualified where churnGroups[path] == nil {
            churnGroups[path] = ChurnGroup(name: (path as NSString).lastPathComponent,
                                           start: q.start, lastActive: mono, pids: q.pids)
        }

        // Update tray icon
        let churnBurn = churnGroups.values
            .filter { $0.pids.count >= churnMinInstances && mono - $0.lastActive <= churnGrace }
            .map { mono - $0.start }
            .max() ?? 0
        let iconIndex: Int
        if !highCPUStart.isEmpty || churnBurn > 0 {
            let maxDur = max(highCPUStart.values.map { mono - $0 }.max() ?? 0, churnBurn)
            let progress = min(maxDur / durationThreshold, 1.0)
            iconIndex = Int((progress * 12).rounded())
        } else {
            iconIndex = 0
        }
        statusItem.button?.image = icons[iconIndex]
        statusItem.button?.toolTip = tooltipText()
    }

    private func tooltipText() -> String {
        if let top = offenders.first {
            let extra = offenders.count > 1 ? " (+\(offenders.count - 1) more)" : ""
            return "\(top.name) at \(Int(top.cpu))% CPU\(extra) — click for details"
        }
        let mono = ProcessInfo.processInfo.systemUptime
        let active = churnGroups.values.filter {
            $0.pids.count >= churnMinInstances && mono - $0.lastActive <= churnGrace
        }
        if let churn = active.max(by: { $0.start > $1.start }) {
            return "\(churn.name) keeps restarting pinned (\(churn.pids.count) instances) — click for details"
        }
        return "CPU Monitor — no process above \(Int(cpuThreshold))% CPU"
    }

    // MARK: Menu (click the icon to see what is burning CPU)

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Drop the items we added last time
        while let first = menu.items.first, first.tag == dynamicTag {
            menu.removeItem(at: 0)
        }

        var items: [NSMenuItem] = []
        let mono = ProcessInfo.processInfo.systemUptime

        if offenders.isEmpty {
            let idle = NSMenuItem(title: "No process above \(Int(cpuThreshold))% CPU",
                                  action: nil, keyEquivalent: "")
            idle.tag = dynamicTag
            items.append(idle)
        } else {
            for off in offenders.prefix(12) {
                let item = NSMenuItem(
                    title: "\(off.name) (\(off.pid))  ·  \(Int(off.cpu))% CPU  ·  \(formatDuration(mono - off.since))",
                    action: nil, keyEquivalent: "")
                item.tag = dynamicTag
                item.toolTip = "PID \(off.pid)"
                items.append(item)
            }
            if offenders.count > 12 {
                let more = NSMenuItem(title: "…and \(offenders.count - 12) more",
                                      action: nil, keyEquivalent: "")
                more.tag = dynamicTag
                items.append(more)
            }
        }

        // The same executable restarting pinned, instance after instance
        let churning = churnGroups
            .filter { $0.value.pids.count >= churnMinInstances && mono - $0.value.lastActive <= churnGrace }
            .sorted { $0.value.start < $1.value.start }
        if !churning.isEmpty {
            for (_, group) in churning {
                let item = NSMenuItem(
                    title: "↻ \(group.name) — \(group.pids.count) pinned instances · \(formatDuration(mono - group.start))",
                    action: nil, keyEquivalent: "")
                item.tag = dynamicTag
                items.append(item)
            }
        }

        // Recently killed processes — so a red dot that cleared itself is explained
        if !recentKills.isEmpty {
            let separator = NSMenuItem.separator()
            separator.tag = dynamicTag
            items.append(separator)

            for kill in recentKills {
                let from = kill.spawner.isEmpty ? "" : ", from \(kill.spawner)"
                let item = NSMenuItem(
                    title: "Killed \(kill.name) (PID \(kill.pid)\(from))  ·  \(formatDuration(mono - kill.at)) ago",
                    action: nil, keyEquivalent: "")
                item.tag = dynamicTag
                items.append(item)
            }
        }

        let separator = NSMenuItem.separator()
        separator.tag = dynamicTag
        items.append(separator)

        for (index, item) in items.enumerated() {
            menu.insertItem(item, at: index)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
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
