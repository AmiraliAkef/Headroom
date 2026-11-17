import AppKit

/// Everything prep needs from the system. `LiveEnvironment` is the real one;
/// tests substitute a fake so nothing is ever quit.
public protocol PrepEnvironment {
    func memory() -> MemorySnapshot?
    func runningApps() -> [AppInfo]
    /// Apps hosting this process (e.g. the terminal app); always protected.
    func hostApps(among apps: [AppInfo]) -> Set<String>
    /// Memory footprint per bundle id (Docker includes its VM).
    func footprints(for apps: [AppInfo]) -> [String: UInt64]
    func loadedModels() -> [LoadedModel]
    func quit(_ app: AppInfo, force: Bool) -> QuitOutcome
    /// The app is showing at least one window (not hidden, not windowless).
    func hasVisibleWindow(_ app: AppInfo) -> Bool
    /// Whether an app with this bundle id is running now.
    func isRunning(bundleId: String) -> Bool
    func stopDocker(_ app: AppInfo) -> Bool
    func unloadOllama(_ name: String) -> Bool
    func unloadAllLMStudio() -> Bool
    /// Relaunch without stealing focus; hidden if it was in the background.
    func open(_ app: SessionApp) -> Bool
    func startDocker() -> Bool
    /// Terminal.app's windows and tabs, or nil if they can't be read.
    func terminalWindows() -> [TerminalSessions.Window]?
    /// TTYs running a Claude Code session.
    func claudeTTYs() -> Set<String>
    /// Close Terminal windows by id; returns how many closed.
    func closeTerminalWindows(_ ids: [Int]) -> Int
    /// End the idle Claude sessions on these TTYs; what was ended, or nil if any didn't exit.
    func endClaudeSessions(ttys: [String]) -> [ClaudeSession]?
    /// Resume an ended Claude session in a new Terminal window.
    func reopenClaude(_ session: ClaudeSession) -> Bool
    /// A DisplayLink dock or adapter is plugged in (DisplayLink Manager must stay).
    func displayLinkConnected() -> Bool
    /// Pause after each step so memory stats reflect it.
    func settle()
}

public struct LiveEnvironment: PrepEnvironment {
    public var quitTimeout: TimeInterval = 15
    public var settleSeconds: TimeInterval = 1

    public init() {}

    public func memory() -> MemorySnapshot? { MemoryMonitor.snapshot() }
    public func runningApps() -> [AppInfo] { RunningApps.list() }
    public func hostApps(among apps: [AppInfo]) -> Set<String> { RunningApps.hostApps(among: apps) }
    public func footprints(for apps: [AppInfo]) -> [String: UInt64] {
        let extra: [String: (ProcessSample) -> Bool] =
            apps.contains { $0.bundleId == Docker.bundleId } ? [Docker.bundleId: Docker.isVMProcess] : [:]
        return AppAttribution.footprints(processes: RunningApps.processes(), apps: apps, extra: extra)
    }
    public func loadedModels() -> [LoadedModel] { LocalModels.loaded() }
    public func quit(_ app: AppInfo, force: Bool) -> QuitOutcome {
        RunningApps.quit(app, timeout: quitTimeout, force: force)
    }
    public func hasVisibleWindow(_ app: AppInfo) -> Bool { RunningApps.hasVisibleWindow(app) }
    public func isRunning(bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }
    public func stopDocker(_ app: AppInfo) -> Bool { Docker.stop(app) }
    public func unloadOllama(_ name: String) -> Bool { LocalModels.unloadOllama(name) }
    public func unloadAllLMStudio() -> Bool { LocalModels.unloadAllLMStudio() }
    public func open(_ app: SessionApp) -> Bool {
        RunningApps.open(bundleURL: app.bundleURL, hidden: app.background)
    }
    public func startDocker() -> Bool { Docker.start() }
    public func terminalWindows() -> [TerminalSessions.Window]? { TerminalSessions.windows() }
    public func claudeTTYs() -> Set<String> { TerminalSessions.liveClaudeTTYs() }
    public func closeTerminalWindows(_ ids: [Int]) -> Int { TerminalSessions.close(windowIds: ids) }
    public func endClaudeSessions(ttys: [String]) -> [ClaudeSession]? {
        TerminalSessions.endClaudeSessions(ttys: ttys)
    }
    public func reopenClaude(_ session: ClaudeSession) -> Bool { TerminalSessions.reopen(session) }
    public func displayLinkConnected() -> Bool { DisplayLink.isDeviceConnected() }
    public func settle() { Thread.sleep(forTimeInterval: settleSeconds) }
}

// MARK: - Plan

public struct Candidate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case app(AppInfo)
        case docker(AppInfo)
        case ollama(String)
        case lmstudio([String])
        /// Terminal: quit it, or close only idle windows (see TerminalSessions).
        case terminal(AppInfo, TerminalSessions.Action)
    }

    public var kind: Kind
    public var name: String
    public var estimatedBytes: UInt64

    public var verb: String {
        switch kind {
        case .app: return "Quit"
        case .docker: return "Stop"
        case .ollama, .lmstudio: return "Unload"
        case .terminal(_, let action): return action == .quit ? "Quit" : "Close"
        }
    }

    public var estimatedGB: Double { Double(estimatedBytes) / bytesPerGB }
}

public struct PlanItem: Equatable, Sendable {
    public var candidate: Candidate
    /// Estimated total freed after this item.
    public var cumulativeBytes: UInt64
    /// This is the item where the target is expected to be reached.
    public var reachesTarget: Bool
}

public struct PrepPlan: Equatable, Sendable {
    public var profile: Profile
    public var targetBytes: UInt64
    public var before: MemorySnapshot
    public var items: [PlanItem]

    public var targetGB: Double { Double(targetBytes) / bytesPerGB }
    public var alreadyMet: Bool { before.available >= targetBytes }
    public var neededBytes: UInt64 { alreadyMet ? 0 : targetBytes - before.available }
    public var expectedTotalBytes: UInt64 { items.last?.cumulativeBytes ?? 0 }
    /// Estimates are upper bounds (shared memory is counted per process), so this is optimistic.
    public var expectedToReachTarget: Bool { alreadyMet || items.contains { $0.reachesTarget } }
}

public enum PrepEvent: Equatable, Sendable {
    case started(Candidate)
    case finished(Candidate, availableNow: UInt64)
    case skipped(Candidate, reason: String)
}

public struct PrepResult: Equatable, Sendable {
    public var targetBytes: UInt64
    public var availableBefore: UInt64
    public var availableAfter: UInt64
    public var handled: [Candidate]
    public var skipped: [(candidate: Candidate, reason: String)]
    public var targetReached: Bool { availableAfter >= targetBytes }

    public var freedBytes: Int64 { Int64(availableAfter) - Int64(availableBefore) }

    public static func == (a: PrepResult, b: PrepResult) -> Bool {
        a.targetBytes == b.targetBytes && a.availableBefore == b.availableBefore
            && a.availableAfter == b.availableAfter && a.handled == b.handled
            && a.skipped.map(\.candidate) == b.skipped.map(\.candidate)
            && a.skipped.map(\.reason) == b.skipped.map(\.reason)
    }
}

public struct RestoreResult: Equatable, Sendable {
    public var reopened: [SessionApp] = []
    /// Already running again (the user reopened them), so left alone.
    public var alreadyRunning: [SessionApp] = []
    public var failed: [SessionApp] = []
    public var dockerStarted = false
    public var dockerFailed = false
    public var modelsNotReloaded: [String] = []
    public var claudeReopened: [ClaudeSession] = []
    public var claudeFailed: [ClaudeSession] = []
    public var ok: Bool { failed.isEmpty && !dockerFailed && claudeFailed.isEmpty }
}

/// Status of everything prep could act on, for `headroom status`.
public struct StatusReport: Codable, Equatable, Sendable {
    public struct AppUsage: Codable, Equatable, Sendable {
        public var bundleId: String
        public var name: String
        public var bytes: UInt64
        public var gb: Double
    }

    public struct ModelUsage: Codable, Equatable, Sendable {
        public var name: String
        public var runtime: String
        public var bytes: UInt64
        public var gb: Double
    }

    public var memory: MemorySnapshot
    public var profile: String
    public var targetGB: Double
    public var targetMet: Bool
    public var apps: [AppUsage]
    public var docker: AppUsage?
    public var dockerStoppedByProfile: Bool
    public var models: [ModelUsage]
    public var reclaimableBytes: UInt64
    public var reclaimableGB: Double
    public var session: Session?
}

public final class PrepEngine {
    public let env: PrepEnvironment
    public let store: SessionStore

    public init(env: PrepEnvironment = LiveEnvironment(), store: SessionStore = SessionStore()) {
        self.env = env
        self.store = store
    }

    /// All candidates for a profile, largest first. Only apps on the quit list are
    /// considered; protected apps and the app hosting this process never are.
    public func candidates(for profile: Profile) -> [Candidate] {
        let running = env.runningApps()
        let hosts = env.hostApps(among: running)
        var wanted = Set(profile.quitApps)
        if profile.stopDocker { wanted.remove(Docker.bundleId) }  // handled as Docker below
        // Terminal is handled by window (below), never as a plain quit.
        let terminalApp = wanted.remove(TerminalSessions.bundleId) != nil
            ? running.first { $0.bundleId == TerminalSessions.bundleId } : nil
        // DisplayLink only while no DisplayLink monitor is attached.
        if wanted.contains(DisplayLink.bundleId), running.contains(where: { $0.bundleId == DisplayLink.bundleId }),
           env.displayLinkConnected() {
            wanted.remove(DisplayLink.bundleId)
        }
        let quittable = running.filter {
            wanted.contains($0.bundleId) && !ProtectedApps.contains($0) && !hosts.contains($0.bundleId)
        }
        let dockerApp = profile.stopDocker ? Docker.runningApp(in: running) : nil
        let measured = quittable + (dockerApp.map { [$0] } ?? []) + (terminalApp.map { [$0] } ?? [])
        let sizes = measured.isEmpty ? [:] : env.footprints(for: measured)

        var out: [Candidate] = []
        var seen = Set<String>()
        for app in quittable where seen.insert(app.bundleId).inserted {
            out.append(Candidate(kind: .app(app), name: app.name, estimatedBytes: sizes[app.bundleId] ?? 0))
        }
        if let d = dockerApp {
            out.append(Candidate(kind: .docker(d), name: "Docker Desktop",
                                 estimatedBytes: sizes[d.bundleId] ?? 0))
        }
        if let t = terminalApp, let c = terminalCandidate(t, size: sizes[t.bundleId] ?? 0,
                                                          isHost: hosts.contains(t.bundleId),
                                                          closeIdleClaude: profile.closeIdleClaude) {
            out.append(c)
        }
        if profile.unloadModels {
            let models = env.loadedModels()
            for m in models where m.runtime == .ollama {
                out.append(Candidate(kind: .ollama(m.name), name: "\(m.name) (Ollama)",
                                     estimatedBytes: m.sizeBytes))
            }
            let lms = models.filter { $0.runtime == .lmstudio }
            if !lms.isEmpty {
                out.append(Candidate(kind: .lmstudio(lms.map(\.name)),
                                     name: "LM Studio: " + lms.map(\.name).joined(separator: ", "),
                                     estimatedBytes: lms.reduce(0) { $0 + $1.sizeBytes }))
            }
        }
        return out.sorted { ($0.estimatedBytes, $1.name) > ($1.estimatedBytes, $0.name) }
    }

    /// What prep may do with Terminal now, as a candidate (nil if every window must stay
    /// or the windows can't be read).
    func terminalCandidate(_ app: AppInfo, size: UInt64, isHost: Bool,
                           closeIdleClaude: Bool = false) -> Candidate? {
        guard let windows = env.terminalWindows(), !windows.isEmpty else { return nil }
        let claude = env.claudeTTYs()
        var action = TerminalSessions.action(for: windows, claudeTTYs: claude, closeIdleClaude: closeIdleClaude)
        // Belt and braces: never quit the terminal this process runs in.
        if isHost, action == .quit { action = .none }
        let totalTabs = max(1, windows.reduce(0) { $0 + $1.tabs.count })
        switch action {
        case .none:
            return nil
        case .quit:
            let n = TerminalSessions.idleClaudeTTYs(in: windows, claudeTTYs: claude).count
            return Candidate(kind: .terminal(app, .quit), name: "Terminal" + Self.claudeNote(n),
                             estimatedBytes: size)
        case .closeWindows(let ids):
            let closable = windows.filter { ids.contains($0.id) }
            let tabs = closable.reduce(0) { $0 + $1.tabs.count }
            let kept = windows.count - closable.count
            let n = TerminalSessions.idleClaudeTTYs(in: closable, claudeTTYs: claude).count
            let name = "Terminal: \(closable.count) idle window\(closable.count == 1 ? "" : "s")"
                + Self.claudeNote(n) + " (keeping \(kept) with a working Claude or a running command)"
            return Candidate(kind: .terminal(app, action), name: name,
                             estimatedBytes: size * UInt64(tabs) / UInt64(totalTabs))
        }
    }

    /// " incl. 2 idle Claude sessions", or "" for none.
    static func claudeNote(_ n: Int) -> String {
        n == 0 ? "" : " incl. \(n) idle Claude session\(n == 1 ? "" : "s")"
    }

    public static func makePlan(profile: Profile, targetBytes: UInt64, before: MemorySnapshot,
                                candidates: [Candidate]) -> PrepPlan {
        var items: [PlanItem] = []
        if before.available < targetBytes {
            var cum: UInt64 = 0
            var reached = false
            for c in candidates {
                cum += c.estimatedBytes
                let hits = !reached && before.available + cum >= targetBytes
                reached = reached || hits
                items.append(PlanItem(candidate: c, cumulativeBytes: cum, reachesTarget: hits))
            }
        }
        return PrepPlan(profile: profile, targetBytes: targetBytes, before: before, items: items)
    }

    public func plan(profile: Profile, targetGB: Double? = nil) throws -> PrepPlan {
        guard let mem = env.memory() else { throw ConfigError("can't read memory statistics") }
        let target = targetGB ?? profile.targetGB
        guard target > 0, target < mem.totalGB else {
            throw ConfigError(String(format: "target must be between 0 and total RAM (%.1f GB)", mem.totalGB))
        }
        let targetBytes = UInt64(target * bytesPerGB)
        let cands = mem.available >= targetBytes ? [] : candidates(for: profile)
        return Self.makePlan(profile: profile, targetBytes: targetBytes, before: mem, candidates: cands)
    }

    /// Handle candidates one at a time, re-reading real memory after each and
    /// stopping as soon as the target is reached. Records progress in the session
    /// after every step, so an interrupted prep can still be restored.
    public func execute(_ plan: PrepPlan, force: Bool = false,
                        progress: (PrepEvent) -> Void = { _ in }) -> PrepResult {
        var available = plan.before.available
        var handled: [Candidate] = []
        var skipped: [(Candidate, String)] = []
        let beforeGB = (plan.before.availableGB * 10).rounded() / 10

        for item in plan.items {
            if available >= plan.targetBytes { break }
            let c = item.candidate
            progress(.started(c))
            var step = Session(profile: plan.profile.name, availableBeforeGB: beforeGB)
            var failure: String?
            switch c.kind {
            case .app(let app):
                // Re-check: the monitor may have been plugged in since the plan was shown.
                if app.bundleId == DisplayLink.bundleId, env.displayLinkConnected() {
                    failure = "a DisplayLink monitor is connected"
                    break
                }
                let background = !env.hasVisibleWindow(app)
                switch env.quit(app, force: force) {
                case .quit: step.quitApps = [SessionApp(app, background: background)]
                case .timedOut: failure = "didn't quit in time (unsaved changes?)"
                case .failed(let why): failure = why
                }
            case .docker(let app):
                if env.stopDocker(app) { step.dockerStopped = true } else { failure = "didn't stop" }
            case .ollama(let name):
                if env.unloadOllama(name) { step.unloadedModels = [name] } else { failure = "unload failed" }
            case .lmstudio(let names):
                if env.unloadAllLMStudio() { step.unloadedModels = names } else { failure = "unload failed" }
            case .terminal(let app, _):
                // Re-check now: a Claude session may have started since the plan was made.
                guard let windows = env.terminalWindows() else {
                    failure = "can't read Terminal's windows"
                    break
                }
                let claude = env.claudeTTYs()
                let action = TerminalSessions.action(for: windows, claudeTTYs: claude,
                                                     closeIdleClaude: plan.profile.closeIdleClaude)
                // Idle Claude sessions in what's about to go are ended first, so Terminal
                // doesn't stop to ask about running processes.
                let doomed: [TerminalSessions.Window]
                switch action {
                case .quit: doomed = windows
                case .closeWindows(let ids): doomed = windows.filter { ids.contains($0.id) }
                case .none: doomed = []
                }
                let claudeToEnd = TerminalSessions.idleClaudeTTYs(in: doomed, claudeTTYs: claude)
                if !claudeToEnd.isEmpty {
                    guard let ended = env.endClaudeSessions(ttys: claudeToEnd) else {
                        failure = "an idle Claude session didn't exit"
                        break
                    }
                    step.claudeSessions = ended
                    // Saved now: the sessions are gone even if closing the window fails.
                    _ = try? store.save(merging: step)
                }
                switch action {
                case .quit:
                    // Never forced: a forced quit could take running sessions with it.
                    switch env.quit(app, force: false) {
                    case .quit: step.quitApps = [SessionApp(app)]
                    case .timedOut: failure = "didn't quit in time"
                    case .failed(let why): failure = why
                    }
                case .closeWindows(let ids):
                    if env.closeTerminalWindows(ids) == 0 {
                        failure = "couldn't close idle windows"
                    } else if env.terminalWindows()?.isEmpty == true {
                        // Nothing left open (e.g. the kept window was closed meanwhile):
                        // don't leave Terminal sitting in the Dock with no windows. Not
                        // recorded, since there's no window to bring back; Claude
                        // sessions reopen Terminal themselves.
                        _ = env.quit(app, force: false)
                    }
                case .none:
                    failure = "every window has a working Claude session or running command"
                }
            }
            if let failure {
                skipped.append((c, failure))
                progress(.skipped(c, reason: failure))
                continue
            }
            _ = try? store.save(merging: step)
            handled.append(c)
            env.settle()
            available = env.memory()?.available ?? available
            progress(.finished(c, availableNow: available))
        }

        if !handled.isEmpty, var s = store.load() {
            s.availableAfterGB = (Double(available) / bytesPerGB * 10).rounded() / 10
            try? store.write(s)
        }
        return PrepResult(targetBytes: plan.targetBytes, availableBefore: plan.before.available,
                          availableAfter: available, handled: handled,
                          skipped: skipped.map { (candidate: $0.0, reason: $0.1) })
    }

    /// Reopen the recorded apps (without stealing focus; background ones hidden),
    /// restart Docker and resume Claude sessions. `only` limits it to those items;
    /// the rest stay in the session for later. Anything that fails stays too. The
    /// session is deleted once nothing is left. Returns nil if there is no session.
    public func restore(only: Set<RestoreItem>? = nil,
                        progress: (String) -> Void = { _ in }) -> RestoreResult? {
        guard let stored = store.load() else { return nil }
        let wanted = only ?? Set(stored.restoreItems)
        let session = stored.removing(Set(stored.restoreItems).subtracting(wanted))
        let leftOver = stored.removing(wanted)
        var r = RestoreResult()
        for app in session.quitApps {
            if env.isRunning(bundleId: app.bundleId) {
                // Opening a running app sends it a reopen event, which makes many
                // (Terminal, Chrome…) open a new window. It's back already; skip it.
                r.alreadyRunning.append(app)
                progress("\(app.name) is already running")
            } else if env.open(app) {
                r.reopened.append(app)
                progress("Reopened \(app.name)")
            } else {
                r.failed.append(app)
                progress("Couldn't reopen \(app.name)")
            }
        }
        if session.dockerStopped {
            if env.startDocker() {
                r.dockerStarted = true
                progress("Started Docker Desktop")
            } else {
                r.dockerFailed = true
                progress("Couldn't start Docker Desktop")
            }
        }
        // After the apps, so a quit Terminal is back before windows open in it.
        for s in session.claudeSessions {
            if env.reopenClaude(s) {
                r.claudeReopened.append(s)
                progress("Resumed Claude session \(s.label)")
            } else {
                r.claudeFailed.append(s)
                progress("Couldn't resume Claude session \(s.label) (run: \(s.resumeCommand))")
            }
        }
        var left = leftOver
        left.quitApps = r.failed + leftOver.quitApps
        left.dockerStopped = r.dockerFailed || leftOver.dockerStopped
        left.claudeSessions = r.claudeFailed + leftOver.claudeSessions
        if left.restoreCount == 0 {
            // Models aren't reloaded; mention them once, when the session ends.
            r.modelsNotReloaded = stored.unloadedModels
            store.clear()
        } else {
            if r.ok { left.unloadedModels = stored.unloadedModels } else {
                r.modelsNotReloaded = stored.unloadedModels
                left.unloadedModels = []
            }
            try? store.write(left)
        }
        return r
    }

    /// Drop the session without reopening anything.
    public func forget() { store.clear() }

    public func status(profile: Profile) -> StatusReport? {
        guard let mem = env.memory() else { return nil }
        let running = env.runningApps()
        let hosts = env.hostApps(among: running)
        let listed = running.filter {
            profile.quitApps.contains($0.bundleId) && !ProtectedApps.contains($0)
                && !hosts.contains($0.bundleId) && $0.bundleId != Docker.bundleId
        }
        let dockerApp = Docker.runningApp(in: running)
        let sizes = env.footprints(for: listed + (dockerApp.map { [$0] } ?? []))
        func usage(_ a: AppInfo, _ name: String? = nil) -> StatusReport.AppUsage {
            let b = sizes[a.bundleId] ?? 0
            return .init(bundleId: a.bundleId, name: name ?? a.name, bytes: b, gb: round2(Double(b) / bytesPerGB))
        }
        let models = env.loadedModels()
        let apps = listed.map { usage($0) }.sorted { $0.bytes > $1.bytes }
        let docker = dockerApp.map { usage($0, "Docker Desktop") }
        let dockerCounts = profile.stopDocker || profile.quitApps.contains(Docker.bundleId)
        // What prep would actually act on (e.g. Terminal only partly, or not at all).
        let reclaim = candidates(for: profile).reduce(0) { $0 + $1.estimatedBytes }
        let targetBytes = UInt64(profile.targetGB * bytesPerGB)
        return StatusReport(
            memory: mem, profile: profile.name, targetGB: profile.targetGB,
            targetMet: mem.available >= targetBytes, apps: apps, docker: docker,
            dockerStoppedByProfile: dockerCounts,
            models: models.map { .init(name: $0.name, runtime: $0.runtime.rawValue, bytes: $0.sizeBytes,
                                       gb: round2(Double($0.sizeBytes) / bytesPerGB)) },
            reclaimableBytes: reclaim, reclaimableGB: round2(Double(reclaim) / bytesPerGB),
            session: store.load())
    }
}

func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

public enum Format {
    /// "14.2 GB"
    public static func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / bytesPerGB) }
    public static func gb(_ value: Double) -> String { String(format: "%.1f GB", value) }
}
