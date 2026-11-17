import AppKit
import ApplicationServices
import Darwin

/// A user app, identified by bundle id. The name is for display only.
public struct AppInfo: Codable, Equatable, Hashable, Sendable {
    public var bundleId: String
    public var name: String
    public var bundleURL: String  // path of the .app bundle
    public var pid: Int32

    public init(bundleId: String, name: String, bundleURL: String, pid: Int32) {
        self.bundleId = bundleId
        self.name = name
        self.bundleURL = bundleURL
        self.pid = pid
    }
}

/// One process: its executable path and memory footprint.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var path: String
    public var footprint: UInt64

    public init(pid: Int32, path: String, footprint: UInt64) {
        self.pid = pid
        self.path = path
        self.footprint = footprint
    }
}

public enum QuitOutcome: Equatable, Sendable {
    case quit
    case timedOut  // e.g. an unsaved-document prompt is showing
    case failed(String)
}

public enum AppAttribution {
    /// Sum each app's process footprints. A process belongs to the app whose bundle
    /// contains its executable (this folds helpers like "Google Chrome Helper
    /// (Renderer)" into Chrome). The innermost matching bundle wins, so an app
    /// nested inside another app's bundle is counted on its own.
    public static func footprints(processes: [ProcessSample], apps: [AppInfo],
                                  extra: [String: (ProcessSample) -> Bool] = [:])
        -> [String: UInt64]
    {
        let bundles = apps.map { (id: $0.bundleId, prefix: $0.bundleURL.hasSuffix("/")
                                    ? $0.bundleURL : $0.bundleURL + "/") }
            .sorted { $0.prefix.count > $1.prefix.count }
        var totals: [String: UInt64] = [:]
        for p in processes {
            if let owner = bundles.first(where: { p.path.hasPrefix($0.prefix) }) {
                totals[owner.id, default: 0] += p.footprint
            } else {
                for (id, matches) in extra where matches(p) {
                    totals[id, default: 0] += p.footprint
                }
            }
        }
        return totals
    }
}

/// Real implementation backed by NSWorkspace and libproc.
public enum RunningApps {
    /// Whether an app with this activation policy can be a prep candidate.
    ///
    /// Regular (Dock) apps and accessory apps (menu bar style, no Dock icon, e.g.
    /// "Siri AI") both count. Nothing is touched unless it is also on the active
    /// quit list, and system accessory apps like Control Centre are on the
    /// protected list. Background-only (`.prohibited`) processes never count.
    public static func isUserApp(_ policy: NSApplication.ActivationPolicy) -> Bool {
        policy == .regular || policy == .accessory
    }

    /// User apps (see `isUserApp`) that have a bundle id and URL.
    public static func list() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard isUserApp(app.activationPolicy), !app.isTerminated,
                  let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            return AppInfo(bundleId: id, name: app.localizedName ?? url.deletingPathExtension()
                .lastPathComponent, bundleURL: url.path, pid: app.processIdentifier)
        }
    }

    /// Every process we can read. Ones we can't (other users, root) are skipped.
    public static func processes() -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        guard n > 0 else { return [] }
        var out: [ProcessSample] = []
        out.reserveCapacity(n)
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(n) where pid > 0 {
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard len > 0, let fp = footprint(pid) else { continue }
            out.append(ProcessSample(pid: pid, path: String(cString: pathBuf), footprint: fp))
        }
        return out
    }

    /// `ri_phys_footprint`: the same "Memory" figure Activity Monitor shows.
    public static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    public static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Bundle ids of apps in our own parent chain (e.g. VS Code when run from its
    /// terminal). These are treated as protected so the tool never quits its host.
    public static func hostApps(among apps: [AppInfo]) -> Set<String> {
        let byPID = Dictionary(apps.map { ($0.pid, $0.bundleId) }, uniquingKeysWith: { a, _ in a })
        var result: Set<String> = []
        var pid = getpid()
        var seen: Set<pid_t> = []
        while pid > 1, !seen.contains(pid) {
            seen.insert(pid)
            if let id = byPID[pid] { result.insert(id) }
            guard let parent = parentPID(pid) else { break }
            pid = parent
        }
        return result
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Quit gracefully with `terminate()`, then wait for the process to exit.
    /// Never force-quits unless `force` is set. Callers must only pass apps on the
    /// active quit list; protected apps are refused here as a last line of defence.
    public static func quit(_ app: AppInfo, timeout: TimeInterval = 15, force: Bool = false)
        -> QuitOutcome
    {
        if ProtectedApps.contains(app) { return .failed("protected app") }
        guard let running = NSRunningApplication(processIdentifier: app.pid),
              running.bundleIdentifier == app.bundleId
        else { return isAlive(app.pid) ? .failed("app not found") : .quit }
        if !running.terminate() && !isAlive(app.pid) { return .quit }
        if waitForExit(app.pid, timeout: timeout) { return .quit }
        guard force else { return .timedOut }
        _ = running.forceTerminate()
        return waitForExit(app.pid, timeout: 5) ? .quit : .failed("did not exit after force quit")
    }

    public static func waitForExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            usleep(200_000)
        }
        return !isAlive(pid)
    }

    /// Whether the app has a normal window open: not hidden, and a standard-layer
    /// window on screen in the current Space. Window owner and layer don't need
    /// Screen Recording permission (only titles do). Minimized windows and ones on
    /// another Space aren't on screen; if Headroom already has Accessibility access
    /// they're found through it, otherwise such an app counts as in the background
    /// (restore then relaunches it hidden, which is harmless).
    public static func hasVisibleWindow(_ app: AppInfo) -> Bool {
        if NSRunningApplication(processIdentifier: app.pid)?.isHidden == true { return false }
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                  kCGNullWindowID) as? [[String: Any]] ?? []
        if onScreen.contains(where: { isStandardWindow($0, pid: app.pid) }) { return true }
        guard AXIsProcessTrusted() else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.pid),
                                            kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return false }
        return !list.isEmpty
    }

    /// A window of this process on the normal layer, visible and big enough to be a
    /// real window rather than a status item or helper.
    static func isStandardWindow(_ w: [String: Any], pid: Int32) -> Bool {
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
              (w[kCGWindowLayer as String] as? Int) == 0,
              ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let width = b["Width"] as? Double, let height = b["Height"] as? Double
        else { return false }
        return width >= 100 && height >= 60
    }

    /// Reopen without stealing focus, hidden if asked (for apps that were in the
    /// background when prep quit them).
    public static func open(bundleURL: String, hidden: Bool = false) -> Bool {
        let url = URL(fileURLWithPath: bundleURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = hidden
        let done = DispatchSemaphore(value: 0)
        var ok = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            ok = app != nil && error == nil
            done.signal()
        }
        return done.wait(timeout: .now() + 30) == .success && ok
    }

    /// Resolve an app name (or bundle id) to a bundle id: running apps first, then
    /// the usual Applications folders.
    public static func resolve(_ nameOrId: String) -> (bundleId: String, name: String)? {
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: {
            $0.localizedName?.caseInsensitiveCompare(nameOrId) == .orderedSame
                || $0.bundleIdentifier == nameOrId
        }), let id = app.bundleIdentifier {
            return (id, app.localizedName ?? nameOrId)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: nameOrId) {
            return (nameOrId, url.deletingPathExtension().lastPathComponent)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", home + "/Applications"]
        for dir in dirs {
            let path = "\(dir)/\(nameOrId).app"
            if let id = Bundle(path: path)?.bundleIdentifier { return (id, nameOrId) }
        }
        return nil
    }
}
