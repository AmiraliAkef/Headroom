import XCTest
@testable import HeadroomCore

typealias TWindow = TerminalSessions.Window
typealias TTab = TerminalSessions.Tab

let idleTab = { (tty: String) in TTab(tty: tty, busy: false, processes: ["login", "-zsh"]) }
let claudeTab = TTab(tty: "/dev/ttys000", busy: true, processes: ["login", "-zsh", "claude", "caffeinate"])
let idleClaudeTab = TTab(tty: "/dev/ttys001", busy: true, processes: ["login", "-zsh", "claude"],
                         title: "\u{2733} Notch terminal session tracking")
let workingClaudeTab = TTab(tty: "/dev/ttys006", busy: true, processes: ["login", "-zsh", "claude"],
                            title: "\u{25D0} available-ram-topbar")
let buildTab = TTab(tty: "/dev/ttys004", busy: true, processes: ["login", "-zsh", "make"])
let terminalApp = AppInfo(bundleId: "com.apple.Terminal", name: "Terminal",
                          bundleURL: "/System/Applications/Utilities/Terminal.app", pid: 200)

final class TerminalParsingTests: XCTestCase {
    func testParseTabsGroupsByWindow() {
        // Shape of the real osascript output on this Mac (one Claude tab, one idle tab).
        let out = "1234\ttrue\t/dev/ttys000\tlogin,-zsh,claude,caffeinate\n1234\tfalse\t/dev/ttys001\tlogin,-zsh\n99\tfalse\t/dev/ttys002\tlogin,-zsh\n"
        let w = TerminalSessions.parseTabs(out)
        XCTAssertEqual(w.map(\.id), [1234, 99])
        XCTAssertEqual(w[0].tabs, [claudeTab, idleTab("/dev/ttys001")])
        XCTAssertEqual(w[1].tabs, [idleTab("/dev/ttys002")])
        XCTAssertEqual(TerminalSessions.parseTabs(""), [])
    }

    func testParseTabsReadsTitle() {
        let out = "2318\ttrue\t/dev/ttys001\tlogin,-zsh,claude\t\u{2733} Notch terminal session tracking\n"
        XCTAssertEqual(TerminalSessions.parseTabs(out), [TWindow(id: 2318, tabs: [idleClaudeTab])])
    }

    func testListScriptSkipsUnreadableWindows() {
        // Regression: a ghost window with no id failed the whole script.
        let flat = TerminalSessions.listScript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("try set wid to id of w"))
    }

    func testListScriptDoesNotUseBareTabInsideTell() {
        // Regression: inside `tell application "Terminal"`, `tab` is Terminal's tab
        // object, so it printed the word "tab" and nothing parsed.
        XCTAssertFalse(TerminalSessions.listScript.contains("& tab &"))
        XCTAssertTrue(TerminalSessions.listScript.contains("set sep to character id 9"))
    }

    func testClaudeTTYsFromPS() {
        let ps = """
            ttys000  claude
            ttys001  -zsh
            ttys002  /Users/me/.local/share/claude/versions/2.1.321 --resume
            ttys003  vim claude-notes.md
            ??       /Applications/Claude.app/Contents/MacOS/Claude
            """
        XCTAssertEqual(TerminalSessions.claudeTTYs(psOutput: ps), ["/dev/ttys000", "/dev/ttys002"])
    }
}

final class TerminalActionTests: XCTestCase {
    func testAllIdleQuits() {
        let w = [TWindow(id: 1, tabs: [idleTab("/dev/ttys001")]), TWindow(id: 2, tabs: [idleTab("/dev/ttys002")])]
        XCTAssertEqual(TerminalSessions.action(for: w, claudeTTYs: []), .quit)
    }

    func testClaudeWindowKeptOthersClosed() {
        let w = [TWindow(id: 1, tabs: [claudeTab, idleTab("/dev/ttys001")]),  // mixed: whole window kept
                 TWindow(id: 2, tabs: [idleTab("/dev/ttys002")])]
        XCTAssertEqual(TerminalSessions.action(for: w, claudeTTYs: []), .closeWindows([2]))
    }

    func testAnyRunningCommandIsKeptToo() {
        let w = [TWindow(id: 1, tabs: [buildTab]), TWindow(id: 2, tabs: [idleTab("/dev/ttys002")])]
        XCTAssertEqual(TerminalSessions.action(for: w, claudeTTYs: []), .closeWindows([2]))
    }

    func testBackgroundClaudeOnIdleLookingTabIsKept() {
        // Terminal says not busy (claude backgrounded), but ps sees it on that tty.
        let w = [TWindow(id: 1, tabs: [idleTab("/dev/ttys005")])]
        XCTAssertEqual(TerminalSessions.action(for: w, claudeTTYs: ["/dev/ttys005"]), .none)
    }

    func testEverythingBusyDoesNothing() {
        let w = [TWindow(id: 1, tabs: [claudeTab])]
        XCTAssertEqual(TerminalSessions.action(for: w, claudeTTYs: []), .none)
    }
}

final class IdleClaudeTests: XCTestCase {
    func testResumeCommand() {
        XCTAssertEqual(ClaudeSession(cwd: "/Users/me/My Proj", sessionId: "84607ecf").resumeCommand,
                       "cd '/Users/me/My Proj' && claude --resume '84607ecf'")
        XCTAssertEqual(ClaudeSession(cwd: "/tmp/it's").resumeCommand, "cd '/tmp/it'\\''s' && claude --continue")
        XCTAssertEqual(ClaudeSession(cwd: "/a/dynamic_notch").label, "dynamic_notch")
    }

    func testParseSessionRecord() {
        let rec: [String: Any] = ["pid": 42058, "sessionId": "84607ecf", "cwd": "/a/dynamic_notch",
                                  "name": "dynamic-notch-95"]
        XCTAssertEqual(TerminalSessions.parseClaudeSessionRecord(rec, pid: 42058),
                       ClaudeSession(cwd: "/a/dynamic_notch", sessionId: "84607ecf", name: "dynamic-notch-95"))
        XCTAssertNil(TerminalSessions.parseClaudeSessionRecord(rec, pid: 1))  // stale pid
    }

    func testOldSessionFileStillLoads() throws {
        let json = #"{"createdAt":"2026-11-10T00:00:00Z","profile":"llm","quitApps":[],"dockerStopped":false,"unloadedModels":[],"availableBeforeGB":3}"#
        let s = try SessionStore.decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(s.claudeSessions, [])
    }

    func testIdleDetection() {
        XCTAssertTrue(idleClaudeTab.isIdleClaude)
        XCTAssertFalse(workingClaudeTab.isIdleClaude)
        XCTAssertFalse(claudeTab.isIdleClaude)  // no title
        var withChild = idleClaudeTab
        withChild.processes.append("npm")  // something else running on the tab
        XCTAssertFalse(withChild.isIdleClaude)
    }

    func testOffByDefault() {
        let w = [TWindow(id: 1, tabs: [idleClaudeTab]), TWindow(id: 2, tabs: [idleTab("/dev/ttys002")])]
        XCTAssertEqual(TerminalSessions.action(for: w, claudeTTYs: []), .closeWindows([2]))
    }

    func testClosesIdleButKeepsWorking() {
        let w = [TWindow(id: 1, tabs: [idleClaudeTab]), TWindow(id: 2, tabs: [workingClaudeTab])]
        XCTAssertEqual(TerminalSessions.action(for: w, claudeTTYs: [], closeIdleClaude: true), .closeWindows([1]))
        XCTAssertEqual(TerminalSessions.action(for: [w[0]], claudeTTYs: [], closeIdleClaude: true), .quit)
    }

    func testMixedWindowKeptIfAnyTabWorks() {
        let w = [TWindow(id: 1, tabs: [idleClaudeTab, buildTab])]
        XCTAssertEqual(TerminalSessions.action(for: w, claudeTTYs: [], closeIdleClaude: true), .none)
    }
}

final class TerminalPrepTests: XCTestCase {
    var dir: URL!
    var env: FakeEnvironment!
    var engine: PrepEngine!
    let profile = Profile(name: "p", targetGB: 20, quitApps: ["com.apple.Terminal"], unloadModels: false)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        env = FakeEnvironment(apps: [terminalApp], sizes: [terminalApp.bundleId: 400 * 1_048_576], availableGB: [10])
        engine = PrepEngine(env: env, store: SessionStore(url: dir.appendingPathComponent("session.json")))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testClaudeSessionKeepsTerminalOpenAndClosesIdleWindows() throws {
        env.terminal = [[TWindow(id: 1, tabs: [claudeTab]), TWindow(id: 2, tabs: [idleTab("/dev/ttys002")])]]
        let c = try XCTUnwrap(engine.candidates(for: profile).first)
        XCTAssertEqual(c.verb, "Close")
        XCTAssertEqual(c.estimatedBytes, 200 * 1_048_576)  // half the tabs
        let r = engine.execute(try engine.plan(profile: profile))
        XCTAssertTrue(env.quitCalls.isEmpty)  // Terminal itself never quit
        XCTAssertEqual(env.closedWindows, [2])
        XCTAssertEqual(r.handled.count, 1)
        XCTAssertEqual(SessionStore(url: dir.appendingPathComponent("session.json")).load()?.quitApps, [])
    }

    func testTerminalQuitWhenClosingLeavesNoWindows() throws {
        // Planned as close-some, but the kept window is gone by the time they're closed.
        env.terminal = [[TWindow(id: 1, tabs: [claudeTab]), TWindow(id: 2, tabs: [idleTab("/dev/ttys002")])],
                        [TWindow(id: 1, tabs: [claudeTab]), TWindow(id: 2, tabs: [idleTab("/dev/ttys002")])],
                        []]
        _ = engine.execute(try engine.plan(profile: profile))
        XCTAssertEqual(env.closedWindows, [2])
        XCTAssertEqual(env.quitCalls.map(\.0), ["com.apple.Terminal"])
        XCTAssertEqual(env.quitCalls.first?.1, false)
        XCTAssertEqual(SessionStore(url: dir.appendingPathComponent("session.json")).load()?.quitApps, [])
    }

    func testNoSessionsQuitsAndRestoreReopens() throws {
        env.terminal = [[TWindow(id: 1, tabs: [idleTab("/dev/ttys001")])]]
        _ = engine.execute(try engine.plan(profile: profile))
        XCTAssertEqual(env.quitCalls.map(\.0), ["com.apple.Terminal"])
        XCTAssertEqual(env.quitCalls.first?.1, false)  // never forced
        _ = engine.restore()
        XCTAssertEqual(env.openCalls, ["com.apple.Terminal"])
    }

    func testForceFlagNeverForcesTerminal() throws {
        env.terminal = [[TWindow(id: 1, tabs: [idleTab("/dev/ttys001")])]]
        _ = engine.execute(try engine.plan(profile: profile), force: true)
        XCTAssertEqual(env.quitCalls.first?.1, false)
    }

    func testClaudeStartedAfterPlanningDowngradesToClosingIdleWindows() throws {
        let idle = [TWindow(id: 1, tabs: [idleTab("/dev/ttys001")]), TWindow(id: 2, tabs: [idleTab("/dev/ttys002")])]
        let nowWithClaude = [TWindow(id: 1, tabs: [claudeTab]), TWindow(id: 2, tabs: [idleTab("/dev/ttys002")])]
        env.terminal = [idle, nowWithClaude]  // planned as quit; Claude appears before execution
        let plan = try engine.plan(profile: profile)
        XCTAssertEqual(plan.items.first?.candidate.verb, "Quit")
        _ = engine.execute(plan)
        XCTAssertTrue(env.quitCalls.isEmpty)
        XCTAssertEqual(env.closedWindows, [2])
    }

    func testAllWindowsBusyMeansNoCandidate() {
        env.terminal = [[TWindow(id: 1, tabs: [claudeTab])]]
        XCTAssertTrue(engine.candidates(for: profile).isEmpty)
    }

    func testUnreadableWindowsMeansNoCandidate() {
        env.terminal = [nil]  // e.g. Automation permission denied
        XCTAssertTrue(engine.candidates(for: profile).isEmpty)
    }

    func testHostTerminalIsNeverQuit() {
        env.hosts = ["com.apple.Terminal"]
        env.terminal = [[TWindow(id: 1, tabs: [idleTab("/dev/ttys001")])]]
        XCTAssertTrue(engine.candidates(for: profile).isEmpty)
    }

    func testIdleClaudeEndedBeforeClosing() throws {
        var p = profile
        p.closeIdleClaude = true
        env.terminal = [[TWindow(id: 1, tabs: [idleClaudeTab]), TWindow(id: 2, tabs: [workingClaudeTab])]]
        let c = try XCTUnwrap(engine.candidates(for: p).first)
        XCTAssertTrue(c.name.contains("incl. 1 idle Claude session"), c.name)
        _ = engine.execute(try engine.plan(profile: p))
        XCTAssertEqual(env.endedClaude, ["/dev/ttys001"])
        XCTAssertEqual(env.closedWindows, [1])
    }

    func testRestoreResumesEndedClaudeSessions() throws {
        var p = profile
        p.closeIdleClaude = true
        env.terminal = [[TWindow(id: 1, tabs: [idleClaudeTab]), TWindow(id: 2, tabs: [workingClaudeTab])]]
        _ = engine.execute(try engine.plan(profile: p))
        let store = SessionStore(url: dir.appendingPathComponent("session.json"))
        XCTAssertEqual(store.load()?.claudeSessions, [ClaudeSession(cwd: "/proj", sessionId: "id-/dev/ttys001")])
        XCTAssertEqual(store.load()?.restoreCount, 1)
        let r = try XCTUnwrap(engine.restore())
        XCTAssertTrue(r.ok)
        XCTAssertEqual(env.reopenedClaude.map(\.sessionId), ["id-/dev/ttys001"])
        XCTAssertFalse(store.exists)
    }

    func testFailedClaudeResumeStaysInSession() throws {
        let store = SessionStore(url: dir.appendingPathComponent("session.json"))
        try store.write(Session(profile: "p", claudeSessions: [ClaudeSession(cwd: "/proj")], availableBeforeGB: 1))
        env.claudeReopenFails = true
        let r = try XCTUnwrap(engine.restore())
        XCTAssertFalse(r.ok)
        XCTAssertEqual(store.load()?.claudeSessions, [ClaudeSession(cwd: "/proj")])
    }

    func testClaudeThatWontExitIsNotClosed() throws {
        var p = profile
        p.closeIdleClaude = true
        env.claudeRefusesToExit = true
        env.terminal = [[TWindow(id: 1, tabs: [idleClaudeTab]), TWindow(id: 2, tabs: [workingClaudeTab])]]
        let r = engine.execute(try engine.plan(profile: p))
        XCTAssertTrue(env.closedWindows.isEmpty)
        XCTAssertEqual(r.skipped.count, 1)
    }

    func testClaudeThatStartedWorkingIsSpared() throws {
        var p = profile
        p.closeIdleClaude = true
        env.terminal = [[TWindow(id: 1, tabs: [idleClaudeTab]), TWindow(id: 2, tabs: [workingClaudeTab])],
                        [TWindow(id: 1, tabs: [workingClaudeTab]), TWindow(id: 2, tabs: [workingClaudeTab])]]
        _ = engine.execute(try engine.plan(profile: p))
        XCTAssertTrue(env.endedClaude.isEmpty)
        XCTAssertTrue(env.closedWindows.isEmpty)
    }

    func testCloseIdleClaudeConfigFlag() throws {
        let cfg = try ConfigLoader.parse(Data(#"{"profiles":{"p":{"targetGB":4,"closeIdleClaude":true}}}"#.utf8))
        XCTAssertTrue(try cfg.profile(nil).closeIdleClaude)
        XCTAssertTrue(cfg.warnings.isEmpty)
    }

    func testTerminalAllowedInConfig() throws {
        let cfg = try ConfigLoader.parse(Data(#"{"profiles":{"p":{"targetGB":4,"quitApps":["com.apple.Terminal"]}}}"#.utf8))
        XCTAssertEqual(try cfg.profile(nil).quitApps, ["com.apple.Terminal"])
    }
}
