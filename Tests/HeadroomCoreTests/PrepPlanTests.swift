import XCTest
@testable import HeadroomCore

let GB = UInt64(1_073_741_824)

/// Fake system: nothing real is ever quit or opened.
final class FakeEnvironment: PrepEnvironment {
    var apps: [AppInfo]
    var sizes: [String: UInt64]
    var models: [LoadedModel] = []
    var hosts: Set<String> = []
    /// Successive available-memory readings (GB); the last one repeats.
    var availableGB: [Double]
    var refuse: Set<String> = []  // bundle ids that time out on quit
    var failOpen: Set<String> = []

    var quitCalls: [(String, Bool)] = []
    var openCalls: [String] = []
    var dockerStops = 0, dockerStarts = 0, ollamaUnloads: [String] = [], lmsUnloads = 0

    init(apps: [AppInfo], sizes: [String: UInt64], availableGB: [Double]) {
        self.apps = apps
        self.sizes = sizes
        self.availableGB = availableGB
    }

    func memory() -> MemorySnapshot? {
        let gb = availableGB.count > 1 ? availableGB.removeFirst() : availableGB[0]
        return MemorySnapshot(total: 32 * GB, used: 0, available: UInt64(gb * Double(GB)), compressed: 0,
                              swapUsed: 0, swapTotal: 0, pressure: .warning)
    }
    func runningApps() -> [AppInfo] { apps }
    func hostApps(among apps: [AppInfo]) -> Set<String> { hosts }
    func footprints(for apps: [AppInfo]) -> [String: UInt64] {
        sizes.filter { id, _ in apps.contains { $0.bundleId == id } }
    }
    func loadedModels() -> [LoadedModel] { models }
    func quit(_ app: AppInfo, force: Bool) -> QuitOutcome {
        quitCalls.append((app.bundleId, force))
        return refuse.contains(app.bundleId) && !force ? .timedOut : .quit
    }
    func stopDocker(_ app: AppInfo) -> Bool { dockerStops += 1; return true }
    func unloadOllama(_ name: String) -> Bool { ollamaUnloads.append(name); return true }
    func unloadAllLMStudio() -> Bool { lmsUnloads += 1; return true }
    func open(_ app: SessionApp) -> Bool {
        openCalls.append(app.bundleId)
        if app.background { openedHidden.append(app.bundleId) }
        return !failOpen.contains(app.bundleId)
    }
    var openedHidden: [String] = []
    /// Apps with no window open (so prep records them as background).
    var windowless: Set<String> = []
    func hasVisibleWindow(_ app: AppInfo) -> Bool { !windowless.contains(app.bundleId) }
    /// Apps the user reopened themselves after prep.
    var runningAgain: Set<String> = []
    func isRunning(bundleId: String) -> Bool { runningAgain.contains(bundleId) }
    func startDocker() -> Bool { dockerStarts += 1; return true }
    func settle() {}
    /// Successive "DisplayLink device plugged in" readings; the last one repeats.
    var displayLink: [Bool] = [false]
    func displayLinkConnected() -> Bool { displayLink.count > 1 ? displayLink.removeFirst() : displayLink[0] }

    /// Successive Terminal window readings; the last one repeats. nil = can't read.
    var terminal: [[TerminalSessions.Window]?] = [nil]
    var claude: Set<String> = []
    var closedWindows: [Int] = []
    func terminalWindows() -> [TerminalSessions.Window]? {
        terminal.count > 1 ? terminal.removeFirst() : terminal[0]
    }
    func claudeTTYs() -> Set<String> { claude }
    func closeTerminalWindows(_ ids: [Int]) -> Int { closedWindows += ids; return ids.count }
    var endedClaude: [String] = []
    var claudeRefusesToExit = false
    func endClaudeSessions(ttys: [String]) -> [ClaudeSession]? {
        endedClaude += ttys
        return claudeRefusesToExit ? nil : ttys.map { ClaudeSession(cwd: "/proj", sessionId: "id-" + $0) }
    }
    var reopenedClaude: [ClaudeSession] = []
    var claudeReopenFails = false
    func reopenClaude(_ s: ClaudeSession) -> Bool { reopenedClaude.append(s); return !claudeReopenFails }
}

func app(_ id: String, _ name: String, pid: Int32) -> AppInfo {
    AppInfo(bundleId: id, name: name, bundleURL: "/Applications/\(name).app", pid: pid)
}

let chrome = app("com.google.Chrome", "Google Chrome", pid: 101)
let slack = app("com.tinyspeck.slackmacgap", "Slack", pid: 102)
let spotify = app("com.spotify.client", "Spotify", pid: 103)
let docker = app("com.docker.docker", "Docker", pid: 104)
let finder = app("com.apple.finder", "Finder", pid: 105)
let notes = app("com.apple.Notes", "Notes", pid: 106)  // running, but not on the list
let vscode = app("com.microsoft.VSCode", "Code", pid: 107)

final class PrepPlanTests: XCTestCase {
    var store: SessionStore!
    var dir: URL!
    var env: FakeEnvironment!
    var engine: PrepEngine!

    let profile = Profile(name: "llm", targetGB: 20,
                          quitApps: [chrome.bundleId, slack.bundleId, spotify.bundleId, vscode.bundleId,
                                     "com.hnc.Discord"],
                          unloadModels: true, stopDocker: true)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(url: dir.appendingPathComponent("session.json"))
        env = FakeEnvironment(
            apps: [chrome, slack, spotify, docker, finder, notes, vscode],
            sizes: [chrome.bundleId: 3 * GB, slack.bundleId: GB / 2, spotify.bundleId: GB / 4,
                    docker.bundleId: 4 * GB, finder.bundleId: GB, notes.bundleId: 2 * GB, vscode.bundleId: GB],
            availableGB: [10])
        engine = PrepEngine(env: env, store: store)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testCandidatesOnlyFromQuitListLargestFirst() {
        env.models = [LoadedModel(name: "qwen", sizeBytes: 5 * GB, runtime: .ollama),
                      LoadedModel(name: "a", sizeBytes: GB, runtime: .lmstudio),
                      LoadedModel(name: "b", sizeBytes: GB, runtime: .lmstudio)]
        let names = engine.candidates(for: profile).map(\.name)
        XCTAssertEqual(names, ["qwen (Ollama)", "Docker Desktop", "Google Chrome", "LM Studio: a, b", "Code",
                               "Slack", "Spotify"])
        XCTAssertFalse(names.contains("Notes"))  // not on the list
        XCTAssertFalse(names.contains("Finder"))  // protected
    }

    func testProtectedNeverCandidateEvenIfListed() {
        // Config validation rejects this, but the engine must refuse too.
        let p = Profile(name: "x", targetGB: 20, quitApps: [finder.bundleId, slack.bundleId])
        XCTAssertEqual(engine.candidates(for: p).map(\.name), ["Slack"])
    }

    func testHostAppExcluded() {
        env.hosts = [vscode.bundleId]
        XCTAssertFalse(engine.candidates(for: profile).map(\.name).contains("Code"))
    }

    func testModelsAndDockerRespectProfileFlags() {
        env.models = [LoadedModel(name: "qwen", sizeBytes: 5 * GB, runtime: .ollama)]
        var p = profile
        p.unloadModels = false
        p.stopDocker = false
        XCTAssertEqual(engine.candidates(for: p).map(\.name), ["Google Chrome", "Code", "Slack", "Spotify"])
    }

    func testDockerOnQuitListWithoutStopDockerIsAPlainApp() {
        let p = Profile(name: "x", targetGB: 20, quitApps: [docker.bundleId], stopDocker: false)
        XCTAssertEqual(engine.candidates(for: p).map(\.kind), [.app(docker)])
    }

    func testPlanMarksWhereTargetIsReached() throws {
        let plan = try engine.plan(profile: profile)  // need 10 GB: docker 4 + chrome 3 + code 1 + ...
        XCTAssertEqual(plan.neededBytes, 10 * GB)
        XCTAssertEqual(plan.items.map(\.cumulativeBytes), [4 * GB, 7 * GB, 8 * GB, 8 * GB + GB / 2, 8 * GB + 3 * GB / 4])
        XCTAssertEqual(plan.items.filter(\.reachesTarget).count, 0)
        XCTAssertFalse(plan.expectedToReachTarget)

        let plan2 = try engine.plan(profile: profile, targetGB: 16)
        XCTAssertEqual(plan2.items.map(\.reachesTarget), [false, true, false, false, false])
        XCTAssertTrue(plan2.expectedToReachTarget)
    }

    func testAlreadyMetGivesEmptyPlan() throws {
        env.availableGB = [25]
        let plan = try engine.plan(profile: profile)
        XCTAssertTrue(plan.alreadyMet)
        XCTAssertEqual(plan.items, [])
        let r = engine.execute(plan)
        XCTAssertEqual(r.handled, [])
        XCTAssertTrue(env.quitCalls.isEmpty)
        XCTAssertNil(store.load())
    }

    func testTargetValidation() {
        XCTAssertThrowsError(try engine.plan(profile: profile, targetGB: 32))
        XCTAssertThrowsError(try engine.plan(profile: profile, targetGB: 0))
    }

    func testExecuteStopsOnceTargetReached() throws {
        env.availableGB = [10, 15, 21]  // plan read, after Docker, after Chrome
        let plan = try engine.plan(profile: profile)
        var events: [PrepEvent] = []
        let r = engine.execute(plan) { events.append($0) }
        XCTAssertEqual(env.dockerStops, 1)
        XCTAssertEqual(env.quitCalls.map(\.0), [chrome.bundleId])  // stopped before Code/Slack/Spotify
        XCTAssertTrue(r.targetReached)
        XCTAssertEqual(r.handled.map(\.name), ["Docker Desktop", "Google Chrome"])
        XCTAssertEqual(events.count, 4)

        let s = try XCTUnwrap(store.load())
        XCTAssertEqual(s.quitApps.map(\.bundleId), [chrome.bundleId])
        XCTAssertTrue(s.dockerStopped)
        XCTAssertEqual(s.availableBeforeGB, 10)
        XCTAssertEqual(s.availableAfterGB, 21)
    }

    func testRefusingAppIsSkippedNotForced() throws {
        env.refuse = [chrome.bundleId]
        env.availableGB = [10, 12, 13, 14, 15]
        let r = engine.execute(try engine.plan(profile: profile))
        XCTAssertEqual(r.skipped.map(\.candidate.name), ["Google Chrome"])
        XCTAssert(r.skipped[0].reason.contains("didn't quit"))
        XCTAssertTrue(env.quitCalls.allSatisfy { !$0.1 })
        XCTAssertFalse(store.load()!.quitApps.contains { $0.bundleId == chrome.bundleId })
        XCTAssertFalse(r.targetReached)
    }

    func testForceIsPassedThrough() throws {
        env.refuse = [chrome.bundleId]
        env.availableGB = [10, 12, 25]
        _ = engine.execute(try engine.plan(profile: profile), force: true)
        XCTAssertEqual(env.quitCalls.first?.1, true)
        XCTAssertEqual(store.load()!.quitApps.map(\.bundleId), [chrome.bundleId])
    }

    func testModelsUnloaded() throws {
        env.models = [LoadedModel(name: "qwen", sizeBytes: 9 * GB, runtime: .ollama),
                      LoadedModel(name: "a", sizeBytes: 5 * GB, runtime: .lmstudio)]
        env.availableGB = [10, 18, 24]
        _ = engine.execute(try engine.plan(profile: profile))
        XCTAssertEqual(env.ollamaUnloads, ["qwen"])
        XCTAssertEqual(env.lmsUnloads, 1)
        XCTAssertEqual(store.load()!.unloadedModels, ["qwen", "a"])
        XCTAssertTrue(env.quitCalls.isEmpty)
    }

    func testRestoreReopensExactlyWhatWasQuit() throws {
        env.availableGB = [10, 15, 21]
        _ = engine.execute(try engine.plan(profile: profile))
        let r = try XCTUnwrap(engine.restore())
        XCTAssertEqual(env.openCalls, [chrome.bundleId])
        XCTAssertEqual(env.dockerStarts, 1)
        XCTAssertTrue(r.ok)
        XCTAssertNil(store.load())
    }

    func testRestoreWithNoSession() {
        XCTAssertNil(engine.restore())
        XCTAssertTrue(env.openCalls.isEmpty)
    }

    func testFailedReopenStaysInSession() throws {
        try store.write(Session(profile: "llm", quitApps: [SessionApp(slack), SessionApp(spotify)],
                                unloadedModels: ["m"], availableBeforeGB: 5))
        env.failOpen = [spotify.bundleId]
        let r = try XCTUnwrap(engine.restore())
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.modelsNotReloaded, ["m"])
        XCTAssertEqual(store.load()!.quitApps.map(\.bundleId), [spotify.bundleId])
        XCTAssertEqual(store.load()!.unloadedModels, [])
    }

    func testSecondPrepMergesIntoSession() throws {
        env.availableGB = [10, 21]
        _ = engine.execute(try engine.plan(profile: Profile(name: "a", targetGB: 20, quitApps: [slack.bundleId])))
        env.availableGB = [10, 21]
        _ = engine.execute(try engine.plan(profile: Profile(name: "b", targetGB: 20, quitApps: [spotify.bundleId])))
        XCTAssertEqual(store.load()!.quitApps.map(\.bundleId), [slack.bundleId, spotify.bundleId])
        _ = engine.restore()
        XCTAssertEqual(env.openCalls, [slack.bundleId, spotify.bundleId])
    }

    func testWindowlessAppRecordedAsBackgroundAndReopenedHidden() throws {
        env.windowless = [slack.bundleId]
        env.availableGB = [10, 12, 21]
        let p = Profile(name: "a", targetGB: 20, quitApps: [chrome.bundleId, slack.bundleId])
        _ = engine.execute(try engine.plan(profile: p))
        let s = try XCTUnwrap(store.load())
        XCTAssertEqual(s.quitApps.map(\.background), [false, true])  // chrome had a window, slack didn't
        XCTAssertEqual(s.restoreItems.filter(\.wasInForeground).map(\.label), ["Google Chrome"])
        _ = engine.restore()
        XCTAssertEqual(env.openedHidden, [slack.bundleId])
    }

    func testRestoreOnlyChosenKeepsTheRest() throws {
        try store.write(Session(profile: "llm", quitApps: [SessionApp(slack), SessionApp(spotify)],
                                dockerStopped: true, unloadedModels: ["m"], availableBeforeGB: 5))
        let r = try XCTUnwrap(engine.restore(only: [.app(SessionApp(spotify))]))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(env.openCalls, [spotify.bundleId])
        XCTAssertEqual(env.dockerStarts, 0)
        XCTAssertEqual(r.modelsNotReloaded, [])  // session isn't over yet
        let left = try XCTUnwrap(store.load())
        XCTAssertEqual(left.restoreItems, [.app(SessionApp(slack)), .docker])
        XCTAssertEqual(left.unloadedModels, ["m"])
        let r2 = try XCTUnwrap(engine.restore(only: Set(left.restoreItems)))
        XCTAssertEqual(r2.modelsNotReloaded, ["m"])
        XCTAssertNil(store.load())
    }

    func testAlreadyRunningAppIsNotReopened() throws {
        try store.write(Session(profile: "llm", quitApps: [SessionApp(slack), SessionApp(spotify)],
                                availableBeforeGB: 5))
        env.runningAgain = [slack.bundleId]
        let r = try XCTUnwrap(engine.restore())
        XCTAssertEqual(env.openCalls, [spotify.bundleId])
        XCTAssertEqual(r.alreadyRunning.map(\.bundleId), [slack.bundleId])
        XCTAssertNil(store.load())
    }

    func testForget() throws {
        try store.write(Session(profile: "llm", quitApps: [SessionApp(slack)], availableBeforeGB: 5))
        engine.forget()
        XCTAssertNil(store.load())
        XCTAssertTrue(env.openCalls.isEmpty)
    }

    func testRestoreItemMatching() {
        XCTAssertTrue(RestoreItem.app(SessionApp(slack)).matches("slack"))
        XCTAssertTrue(RestoreItem.app(SessionApp(slack)).matches("com.tinyspeck.slackmacgap"))
        XCTAssertTrue(RestoreItem.docker.matches("Docker"))
        XCTAssertTrue(RestoreItem.claude(ClaudeSession(cwd: "/p/Headroom")).matches("headroom"))
        XCTAssertFalse(RestoreItem.app(SessionApp(slack)).matches("spot"))
    }

    func testStatusReport() throws {
        env.models = [LoadedModel(name: "qwen", sizeBytes: 5 * GB, runtime: .ollama)]
        let s = try XCTUnwrap(engine.status(profile: profile))
        XCTAssertEqual(s.apps.map(\.name), ["Google Chrome", "Code", "Slack", "Spotify"])
        XCTAssertEqual(s.docker?.bytes, 4 * GB)
        XCTAssertEqual(s.reclaimableBytes, 3 * GB + GB + GB / 2 + GB / 4 + 4 * GB + 5 * GB)
        XCTAssertTrue(env.quitCalls.isEmpty)
    }
}

final class AttributionTests: XCTestCase {
    func testHelpersFoldIntoParentAndNestedAppsCountSeparately() {
        let apps = [AppInfo(bundleId: "chrome", name: "Google Chrome", bundleURL: "/Applications/Google Chrome.app", pid: 1),
                    AppInfo(bundleId: "xcode", name: "Xcode", bundleURL: "/Applications/Xcode.app", pid: 2),
                    AppInfo(bundleId: "sim", name: "Simulator",
                            bundleURL: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app", pid: 3)]
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/"
        let procs = [
            ProcessSample(pid: 1, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", footprint: 100),
            ProcessSample(pid: 10, path: helper + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", footprint: 50),
            ProcessSample(pid: 2, path: "/Applications/Xcode.app/Contents/MacOS/Xcode", footprint: 70),
            ProcessSample(pid: 3, path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator", footprint: 30),
            ProcessSample(pid: 4, path: "/Applications/Google Chrome Canary.app/Contents/MacOS/x", footprint: 999),
            ProcessSample(pid: 5, path: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine", footprint: 4000),
        ]
        let t = AppAttribution.footprints(processes: procs, apps: apps, extra: ["docker": Docker.isVMProcess])
        XCTAssertEqual(t["chrome"], 150)  // Canary isn't Chrome
        XCTAssertEqual(t["xcode"], 70)
        XCTAssertEqual(t["sim"], 30)
        XCTAssertEqual(t["docker"], 4000)
    }

    func testAccessoryAppsCountButBackgroundOnlyDoNot() {
        XCTAssertTrue(RunningApps.isUserApp(.regular))
        XCTAssertTrue(RunningApps.isUserApp(.accessory))  // e.g. Siri AI
        XCTAssertFalse(RunningApps.isUserApp(.prohibited))
        // System accessory apps stay protected.
        XCTAssertTrue(ProtectedApps.contains(bundleId: "com.apple.controlcenter"))
    }

    func testProtectedList() {
        for id in ["com.apple.finder", "com.apple.dock", "com.googlecode.iterm2",
                   "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.apple.controlcenter", Headroom.bundleIdentifier] {
            XCTAssertTrue(ProtectedApps.contains(bundleId: id), id)
        }
        XCTAssertFalse(ProtectedApps.contains(bundleId: "com.tinyspeck.slackmacgap"))
        // Terminal is guarded by TerminalSessions instead of being protected outright.
        XCTAssertFalse(ProtectedApps.contains(bundleId: "com.apple.Terminal"))
        XCTAssertTrue(ProtectedApps.contains(AppInfo(bundleId: "x", name: "Finder", bundleURL: "", pid: 1)))
    }
}
