import Foundation

public struct SessionApp: Codable, Equatable, Hashable, Sendable {
    public var bundleId: String
    public var name: String
    public var bundleURL: String
    /// The app was running with no window on screen (or hidden) when prep quit it,
    /// e.g. TextEdit after its last document closed. Restore relaunches it hidden,
    /// and the restore chooser leaves it unticked.
    public var background: Bool

    public init(bundleId: String, name: String, bundleURL: String, background: Bool = false) {
        self.bundleId = bundleId
        self.name = name
        self.bundleURL = bundleURL
        self.background = background
    }

    public init(_ app: AppInfo, background: Bool = false) {
        self.init(bundleId: app.bundleId, name: app.name, bundleURL: app.bundleURL, background: background)
    }

    enum CodingKeys: String, CodingKey { case bundleId, name, bundleURL, background }

    // Hand-written so session files from before `background` still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        name = try c.decode(String.self, forKey: .name)
        bundleURL = try c.decode(String.self, forKey: .bundleURL)
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? false
    }
}

/// One thing restore can bring back, so the user can pick some and leave the rest.
public enum RestoreItem: Hashable, Sendable {
    case app(SessionApp)
    case docker
    case claude(ClaudeSession)

    public var label: String {
        switch self {
        case .app(let a): return a.name
        case .docker: return "Docker Desktop"
        case .claude(let s): return "Claude session: \(s.label)"
        }
    }

    /// Ticked by default in the chooser and restored by "Restore All" as normal.
    public var wasInForeground: Bool {
        if case .app(let a) = self { return !a.background }
        return true
    }

    /// Matches a CLI argument: app name or bundle id, "docker", or a Claude session's
    /// name, folder or id (case-insensitive).
    public func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        switch self {
        case .app(let a): return a.name.lowercased() == q || a.bundleId.lowercased() == q
        case .docker: return q == "docker" || q == "docker desktop"
        case .claude(let s):
            return [s.label, s.name, s.sessionId, s.cwd, "claude"].compactMap { $0?.lowercased() }.contains(q)
        }
    }
}

/// A Claude Code session prep ended, so restore can resume it in a new Terminal window.
public struct ClaudeSession: Codable, Equatable, Hashable, Sendable {
    public var cwd: String
    /// Conversation id for `claude --resume`; nil means fall back to `--continue`.
    public var sessionId: String?
    public var name: String?

    public init(cwd: String, sessionId: String? = nil, name: String? = nil) {
        self.cwd = cwd
        self.sessionId = sessionId
        self.name = name
    }

    /// Short label for menus and notifications: the session name, else the folder.
    public var label: String { name ?? (cwd as NSString).lastPathComponent }

    /// The shell command that resumes it.
    public var resumeCommand: String {
        let resume = sessionId.map { "claude --resume \(Self.shellQuote($0))" } ?? "claude --continue"
        return "cd \(Self.shellQuote(cwd)) && \(resume)"
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// What prep did, so restore can undo it. Shared by the app and the CLI.
public struct Session: Codable, Equatable, Sendable {
    public var createdAt: Date
    public var profile: String
    public var quitApps: [SessionApp]
    public var dockerStopped: Bool
    public var unloadedModels: [String]
    public var claudeSessions: [ClaudeSession]
    public var availableBeforeGB: Double
    public var availableAfterGB: Double?

    public init(createdAt: Date = Date(), profile: String, quitApps: [SessionApp] = [],
                dockerStopped: Bool = false, unloadedModels: [String] = [],
                claudeSessions: [ClaudeSession] = [],
                availableBeforeGB: Double, availableAfterGB: Double? = nil) {
        self.claudeSessions = claudeSessions
        self.createdAt = createdAt
        self.profile = profile
        self.quitApps = quitApps
        self.dockerStopped = dockerStopped
        self.unloadedModels = unloadedModels
        self.availableBeforeGB = availableBeforeGB
        self.availableAfterGB = availableAfterGB
    }

    enum CodingKeys: String, CodingKey {
        case createdAt, profile, quitApps, dockerStopped, unloadedModels, claudeSessions
        case availableBeforeGB, availableAfterGB
    }

    // Hand-written so session files from before `claudeSessions` still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        profile = try c.decode(String.self, forKey: .profile)
        quitApps = try c.decode([SessionApp].self, forKey: .quitApps)
        dockerStopped = try c.decode(Bool.self, forKey: .dockerStopped)
        unloadedModels = try c.decode([String].self, forKey: .unloadedModels)
        claudeSessions = try c.decodeIfPresent([ClaudeSession].self, forKey: .claudeSessions) ?? []
        availableBeforeGB = try c.decode(Double.self, forKey: .availableBeforeGB)
        availableAfterGB = try c.decodeIfPresent(Double.self, forKey: .availableAfterGB)
    }

    /// Number of things restore will bring back (apps, Docker, Claude sessions).
    public var restoreCount: Int { quitApps.count + (dockerStopped ? 1 : 0) + claudeSessions.count }

    /// Everything restore can bring back, in restore order (apps first, so a quit
    /// Terminal is back before Claude sessions open windows in it).
    public var restoreItems: [RestoreItem] {
        quitApps.map { .app($0) } + (dockerStopped ? [.docker] : []) + claudeSessions.map { .claude($0) }
    }

    /// This session without the given items.
    public func removing(_ items: Set<RestoreItem>) -> Session {
        var s = self
        s.quitApps.removeAll { items.contains(.app($0)) }
        if items.contains(.docker) { s.dockerStopped = false }
        s.claudeSessions.removeAll { items.contains(.claude($0)) }
        return s
    }

    /// Merge a later prep into this one so a single restore undoes both. Keeps the
    /// original creation time and "before" figure.
    public func merged(with new: Session) -> Session {
        var m = self
        for app in new.quitApps where !m.quitApps.contains(where: { $0.bundleId == app.bundleId }) {
            m.quitApps.append(app)
        }
        for model in new.unloadedModels where !m.unloadedModels.contains(model) {
            m.unloadedModels.append(model)
        }
        for s in new.claudeSessions where !m.claudeSessions.contains(s) { m.claudeSessions.append(s) }
        m.dockerStopped = dockerStopped || new.dockerStopped
        m.profile = new.profile
        m.availableAfterGB = new.availableAfterGB ?? availableAfterGB
        return m
    }
}

public struct SessionStore: Sendable {
    public let url: URL

    public init(url: URL = Paths.session) { self.url = url }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func load() -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Session.self, from: data)
    }

    /// Write atomically (temp file + rename) so the app and CLI never see half a file.
    public func write(_ session: Session) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.encoder.encode(session).write(to: url, options: .atomic)
    }

    /// Merge into the existing session (if any) and write. Returns the stored session.
    @discardableResult
    public func save(merging new: Session) throws -> Session {
        let merged = load()?.merged(with: new) ?? new
        try write(merged)
        return merged
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
