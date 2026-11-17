import Foundation

public enum Paths {
    /// `~/Library/Application Support/Headroom`, shared by the app and the CLI.
    /// `HEADROOM_SUPPORT_DIR` overrides it (used by tests and for trying things out).
    public static var supportDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["HEADROOM_SUPPORT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Headroom", isDirectory: true)
    }

    public static var config: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var session: URL { supportDirectory.appendingPathComponent("session.json") }
}

public struct Profile: Equatable, Sendable {
    public var name: String
    public var targetGB: Double
    public var quitApps: [String]  // bundle identifiers
    public var unloadModels: Bool
    public var stopDocker: Bool
    /// Let prep end Claude Code sessions in Terminal that are idle at their prompt.
    public var closeIdleClaude: Bool

    public init(name: String, targetGB: Double, quitApps: [String] = [],
                unloadModels: Bool = true, stopDocker: Bool = false, closeIdleClaude: Bool = false) {
        self.closeIdleClaude = closeIdleClaude
        self.name = name
        self.targetGB = targetGB
        self.quitApps = quitApps
        self.unloadModels = unloadModels
        self.stopDocker = stopDocker
    }

    /// "llm" → "LLM", "build" → "Build".
    public var displayName: String {
        name.count <= 3 ? name.uppercased() : name.prefix(1).uppercased() + name.dropFirst()
    }
}

public struct ConfigError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Config: Equatable, Sendable {
    public var defaultProfile: String
    public var profiles: [String: Profile]
    public var warnings: [String] = []

    public func profile(_ name: String?) throws -> Profile {
        let name = name ?? defaultProfile
        guard let p = profiles[name] else {
            let known = profiles.keys.sorted().joined(separator: ", ")
            throw ConfigError("unknown profile '\(name)' (known: \(known.isEmpty ? "none" : known))")
        }
        return p
    }

    /// Default profile first, then the rest alphabetically.
    public var orderedProfiles: [Profile] {
        profiles.values.sorted {
            ($0.name == defaultProfile ? 0 : 1, $0.name) < ($1.name == defaultProfile ? 0 : 1, $1.name)
        }
    }
}

public enum ConfigLoader {
    static let topKeys: Set<String> = ["defaultProfile", "profiles"]
    static let profileKeys: Set<String> = ["targetGB", "quitApps", "unloadModels", "stopDocker",
                                                    "closeIdleClaude"]

    /// The plan's defaults, as JSON with stable key order.
    public static let defaultObject: [String: Any] = [
        "defaultProfile": "llm",
        "profiles": [
            "llm": [
                "targetGB": 24,
                "quitApps": ["com.google.Chrome", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
                             "com.spotify.client", "notion.id", "com.microsoft.teams2"],
                "unloadModels": true,
                "stopDocker": true,
            ] as [String: Any],
            "build": [
                "targetGB": 12,
                "quitApps": ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.spotify.client"],
                "unloadModels": true,
                "stopDocker": false,
            ] as [String: Any],
        ],
    ]

    /// Cap a default target at 60% of RAM when it wouldn't fit this Mac.
    public static func fitTarget(_ target: Double, totalGB: Double?) -> Double {
        guard let totalGB, target >= totalGB else { return target }
        return (totalGB * 0.6 * 10).rounded() / 10
    }

    /// Defaults with any target too large for this Mac scaled down, so the created
    /// file is always valid here.
    public static func defaultData(totalGB: Double?) -> Data {
        var obj = defaultObject
        var profiles = obj["profiles"] as! [String: [String: Any]]
        for (name, var p) in profiles {
            p["targetGB"] = fitTarget((p["targetGB"] as! NSNumber).doubleValue, totalGB: totalGB)
            profiles[name] = p
        }
        obj["profiles"] = profiles
        return serialize(obj)
    }

    static func serialize(_ obj: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func parse(_ data: Data, totalGB: Double? = nil) throws -> Config {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) } catch {
            throw ConfigError("not valid JSON: \(error.localizedDescription)")
        }
        guard let obj = any as? [String: Any] else { throw ConfigError("top level must be an object") }
        var warnings: [String] = []
        for k in obj.keys.sorted() where !topKeys.contains(k) { warnings.append("unknown key '\(k)'") }
        guard let rawProfiles = obj["profiles"] as? [String: Any], !rawProfiles.isEmpty else {
            throw ConfigError("config needs a non-empty \"profiles\" object")
        }
        var profiles: [String: Profile] = [:]
        for name in rawProfiles.keys.sorted() {
            guard let raw = rawProfiles[name] as? [String: Any] else {
                throw ConfigError("profiles.\(name) must be an object")
            }
            for k in raw.keys.sorted() where !profileKeys.contains(k) {
                warnings.append("unknown key '\(k)' in profiles.\(name)")
            }
            guard let num = raw["targetGB"] as? NSNumber, !isBool(num) else {
                throw ConfigError("profiles.\(name).targetGB must be a number")
            }
            let target = num.doubleValue
            guard target > 0 else { throw ConfigError("profiles.\(name).targetGB must be positive") }
            if let totalGB, target >= totalGB {
                throw ConfigError(String(format: "profiles.%@.targetGB (%g) must be less than total RAM (%.1f GB)",
                                         name, target, totalGB))
            }
            let rawApps = raw["quitApps"] ?? [String]()
            guard let apps = rawApps as? [String] else {
                throw ConfigError("profiles.\(name).quitApps must be a list of bundle identifiers")
            }
            for app in apps where ProtectedApps.contains(bundleId: app) {
                throw ConfigError("profiles.\(name).quitApps contains protected app '\(app)'")
            }
            func flag(_ key: String, _ def: Bool) throws -> Bool {
                guard let v = raw[key] else { return def }
                guard let n = v as? NSNumber, isBool(n) else {
                    throw ConfigError("profiles.\(name).\(key) must be true or false")
                }
                return n.boolValue
            }
            var seen = Set<String>()
            profiles[name] = Profile(
                name: name, targetGB: target, quitApps: apps.filter { seen.insert($0).inserted },
                unloadModels: try flag("unloadModels", true), stopDocker: try flag("stopDocker", false),
                closeIdleClaude: try flag("closeIdleClaude", false))
        }
        let def = (obj["defaultProfile"] as? String) ?? profiles.keys.sorted()[0]
        guard profiles[def] != nil else {
            throw ConfigError("defaultProfile '\(def)' is not a defined profile")
        }
        return Config(defaultProfile: def, profiles: profiles, warnings: warnings)
    }

    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Create the config from defaults if it doesn't exist. Returns true if created.
    @discardableResult
    public static func ensureExists(at url: URL = Paths.config, totalGB: Double?) throws -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try defaultData(totalGB: totalGB).write(to: url, options: .atomic)
        return true
    }

    /// Load the config, creating it from defaults on first run.
    public static func load(at url: URL = Paths.config, totalGB: Double?) throws -> Config {
        try ensureExists(at: url, totalGB: totalGB)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ConfigError("can't read \(url.path): \(error.localizedDescription)")
        }
        do { return try parse(data, totalGB: totalGB) } catch let e as ConfigError {
            throw ConfigError("\(url.path): \(e.message)")
        }
    }

    /// Append a bundle id to a profile's quit list, keeping everything else in the file.
    /// Returns false if it was already there.
    @discardableResult
    public static func addApp(_ bundleId: String, toProfile profile: String,
                              at url: URL = Paths.config, totalGB: Double?) throws -> Bool {
        if ProtectedApps.contains(bundleId: bundleId) {
            throw ConfigError("'\(bundleId)' is protected and can't be added")
        }
        let config = try load(at: url, totalGB: totalGB)
        _ = try config.profile(profile)
        guard var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var profiles = obj["profiles"] as? [String: Any],
              var p = profiles[profile] as? [String: Any]
        else { throw ConfigError("can't edit \(url.path)") }
        var apps = (p["quitApps"] as? [String]) ?? []
        if apps.contains(bundleId) { return false }
        apps.append(bundleId)
        p["quitApps"] = apps
        profiles[profile] = p
        obj["profiles"] = profiles
        try serialize(obj).write(to: url, options: .atomic)
        return true
    }
}
