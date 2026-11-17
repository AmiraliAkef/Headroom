import Foundation

/// Terminal.app gets special handling instead of being protected outright:
/// prep may quit it only when nothing is running in any tab. Otherwise it closes
/// just the windows whose tabs are all idle shells, and never a window containing
/// a running command. A window with a Claude session is kept too, unless the profile
/// sets `closeIdleClaude` and every Claude session in it is idle at its prompt.
public enum TerminalSessions {
    public static let bundleId = "com.apple.Terminal"

    public struct Tab: Equatable, Sendable {
        public var tty: String  // "/dev/ttys000"
        public var busy: Bool  // Terminal's own "a process other than the shell is running"
        public var processes: [String]
        public var title: String  // tab's custom title; Claude Code sets it

        public init(tty: String, busy: Bool, processes: [String], title: String = "") {
            self.tty = tty
            self.busy = busy
            self.processes = processes
            self.title = title
        }

        /// Claude Code is waiting at its prompt: it prefixes the title with ✳ when idle
        /// and with an animated spinner while working. Anything else besides the shell
        /// and Claude running on the tab counts as busy.
        public var isIdleClaude: Bool {
            title.trimmingCharacters(in: .whitespaces).hasPrefix(TerminalSessions.idleMarker)
                && processes.allSatisfy { TerminalSessions.isClaudeName($0) || TerminalSessions.isShellName($0) || $0 == "caffeinate" }
        }
    }

    /// Claude Code's idle title prefix (U+2733).
    public static let idleMarker = "\u{2733}"

    public struct Window: Equatable, Sendable {
        public var id: Int
        public var tabs: [Tab]

        public init(id: Int, tabs: [Tab]) {
            self.id = id
            self.tabs = tabs
        }

        /// Keep this window if any tab is busy or runs Claude (even in the background).
        /// With `closeIdleClaude`, a Claude tab doesn't count if that session is idle.
        public func mustKeep(claudeTTYs: Set<String>, closeIdleClaude: Bool = false) -> Bool {
            tabs.contains { tab in
                if TerminalSessions.hasClaude(tab, claudeTTYs: claudeTTYs) {
                    return !(closeIdleClaude && tab.isIdleClaude)
                }
                return tab.busy
            }
        }
    }

    /// What prep may do with Terminal right now.
    public enum Action: Equatable, Sendable {
        case quit  // nothing running anywhere: quit the app (restore reopens it)
        case closeWindows([Int])  // close only these idle windows
        case none  // every window must stay
    }

    public static func action(for windows: [Window], claudeTTYs: Set<String>,
                              closeIdleClaude: Bool = false) -> Action {
        let keep = windows.filter { $0.mustKeep(claudeTTYs: claudeTTYs, closeIdleClaude: closeIdleClaude) }
        if keep.isEmpty { return .quit }
        let idle = windows.filter { !$0.mustKeep(claudeTTYs: claudeTTYs, closeIdleClaude: closeIdleClaude) }
            .map(\.id)
        return idle.isEmpty ? .none : .closeWindows(idle)
    }

    static func hasClaude(_ tab: Tab, claudeTTYs: Set<String>) -> Bool {
        claudeTTYs.contains(tab.tty) || tab.processes.contains(where: isClaudeName)
    }

    /// TTYs of idle Claude sessions in the given windows; prep ends these before
    /// closing, so Terminal doesn't stop to ask about running processes.
    public static func idleClaudeTTYs(in windows: [Window], claudeTTYs: Set<String>) -> [String] {
        windows.flatMap(\.tabs).filter { hasClaude($0, claudeTTYs: claudeTTYs) }.map(\.tty)
    }

    static func isClaudeName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).lowercased() == "claude"
    }

    static func isShellName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n == "login" || n.hasPrefix("-")
            || ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash"].contains(n)
    }

    // MARK: Parsing (pure, tested)

    /// Output of `listScript`: one line per tab,
    /// "windowId<TAB>busy<TAB>tty<TAB>proc1,proc2<TAB>title" (title optional).
    public static func parseTabs(_ text: String) -> [Window] {
        var order: [Int] = []
        var byId: [Int: [Tab]] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let id = Int(f[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let procs = f[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if byId[id] == nil { order.append(id) }
            byId[id, default: []].append(Tab(tty: f[2].trimmingCharacters(in: .whitespaces),
                                              busy: f[1].trimmingCharacters(in: .whitespaces) == "true",
                                              processes: procs,
                                              title: f.count >= 5 ? f[4] : ""))
        }
        return order.map { Window(id: $0, tabs: byId[$0]!) }
    }

    /// TTYs (as "/dev/ttysNNN") running Claude Code, from `ps -axo tty=,args=`.
    /// Matches argv[0] "claude" or the versioned binary under ".../claude/versions/".
    public static func claudeTTYs(psOutput: String) -> Set<String> {
        var result: Set<String> = []
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let tty = String(parts[0])
            guard tty != "??", tty != "-" else { continue }
            let args = String(parts[1])
            let argv0 = args.split(separator: " ").first.map(String.init) ?? ""
            let base = (argv0 as NSString).lastPathComponent
            if isClaudeName(base) || args.contains("/claude/versions/") {
                result.insert(tty.hasPrefix("/dev/") ? tty : "/dev/" + tty)
            }
        }
        return result
    }

    // MARK: Live

    // The separator is set outside the tell block: inside it, `tab` means Terminal's
    // tab object, not the tab character. Each window is read inside `try`: Terminal
    // can list a ghost window with no id or name, which would otherwise fail the
    // whole script (and prep would then leave Terminal alone).
    static let listScript = """
        set sep to character id 9
        set out to ""
        set AppleScript's text item delimiters to ","
        tell application "Terminal"
            repeat with w in windows
                try
                    set wid to id of w
                    set rows to ""
                    repeat with t in tabs of w
                        set ttl to ""
                        try
                            set ttl to (custom title of t) as text
                        end try
                        set rows to rows & wid & sep & (busy of t) & sep & (tty of t) & sep & ((processes of t) as text) & sep & ttl & linefeed
                    end repeat
                    set out to out & rows
                end try
            end repeat
        end tell
        return out
        """

    /// Terminal's windows and tabs. Only call when Terminal is already running
    /// (`tell application` would launch it). Returns nil if it can't be read,
    /// e.g. Automation permission was denied; prep then leaves Terminal alone.
    public static func windows() -> [Window]? {
        guard let r = Shell.run("/usr/bin/osascript", ["-e", listScript], timeout: 10), r.status == 0
        else { return nil }
        return parseTabs(r.stdout)
    }

    public static func liveClaudeTTYs() -> Set<String> {
        guard let r = Shell.run("/bin/ps", ["-axo", "tty=,args="], timeout: 10), r.status == 0 else {
            return []
        }
        return claudeTTYs(psOutput: r.stdout)
    }

    /// What restore needs to resume a Claude process: Claude Code's own record in
    /// `~/.claude/sessions/<pid>.json` (conversation id, folder, name), else just the
    /// process's working directory (restore then uses `--continue`).
    static func claudeSessionInfo(pid: Int32) -> ClaudeSession? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(pid).json")
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = parseClaudeSessionRecord(obj, pid: pid) { return s }
        }
        guard let r = Shell.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: 5),
              r.status == 0,
              let line = r.stdout.split(separator: "\n").first(where: { $0.hasPrefix("n") })
        else { return nil }
        return ClaudeSession(cwd: String(line.dropFirst()))
    }

    /// Pure part of `claudeSessionInfo`, tested.
    static func parseClaudeSessionRecord(_ obj: [String: Any], pid: Int32) -> ClaudeSession? {
        guard let cwd = obj["cwd"] as? String, !cwd.isEmpty else { return nil }
        if let p = obj["pid"] as? NSNumber, p.int32Value != pid { return nil }  // stale file
        return ClaudeSession(cwd: cwd, sessionId: obj["sessionId"] as? String, name: obj["name"] as? String)
    }

    /// End the Claude sessions on these TTYs with SIGTERM (what closing the window
    /// would send them anyway) and wait up to `timeout` for them to exit. Claude Code
    /// saves the conversation as it goes, so restore can resume it.
    /// Returns what was ended, or nil if any of them didn't exit.
    public static func endClaudeSessions(ttys: [String], timeout: TimeInterval = 5) -> [ClaudeSession]? {
        let wanted = Set(ttys)
        func pids() -> [Int32] {
            guard let r = Shell.run("/bin/ps", ["-axo", "pid=,tty=,args="], timeout: 10), r.status == 0
            else { return [] }
            return r.stdout.split(separator: "\n").compactMap { line in
                let p = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard p.count == 3, let pid = Int32(p[0]) else { return nil }
                guard wanted.contains("/dev/" + p[1]) else { return nil }
                return claudeTTYs(psOutput: "\(p[1]) \(p[2])").isEmpty ? nil : pid
            }
        }
        let targets = pids()
        // Read before ending: Claude removes its record when it exits.
        let infos = targets.compactMap(claudeSessionInfo(pid:))
        for pid in targets { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids().isEmpty { return infos }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return pids().isEmpty ? infos : nil
    }

    /// Open a new Terminal window that resumes the session. Doesn't bring Terminal
    /// to the front.
    public static func reopen(_ session: ClaudeSession) -> Bool {
        let cmd = session.resumeCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(cmd)\""
        return Shell.run("/usr/bin/osascript", ["-e", script], timeout: 15)?.status == 0
    }

    /// Close the given windows. Returns how many closed.
    public static func close(windowIds: [Int]) -> Int {
        var closed = 0
        for id in windowIds {
            let script = "tell application \"Terminal\" to close (every window whose id is \(id))"
            if Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10)?.status == 0 { closed += 1 }
        }
        return closed
    }
}
