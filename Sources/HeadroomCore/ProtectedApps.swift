import Foundation

public enum Headroom {
    public static let bundleIdentifier = "com.amirali.headroom"
    public static let version = "0.2.0"
}

/// Apps prep never touches. Hard-coded; config and flags can't override it.
/// Terminal.app is deliberately not here: it gets guarded handling instead (see
/// TerminalSessions), so windows with a Claude session or running command are kept.
public enum ProtectedApps {
    public static let bundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.WindowServer",
        "com.apple.loginwindow",
        "com.apple.controlcenter",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        Headroom.bundleIdentifier,
    ]

    /// Names too, in case an app is matched by name (e.g. config typo'd with a name).
    public static let names: Set<String> = [
        "Finder", "Dock", "SystemUIServer", "WindowServer", "loginwindow", "ControlCenter",
        "Control Center", "iTerm", "iTerm2", "Ghostty", "Warp", "Headroom",
    ]

    public static func contains(bundleId: String) -> Bool {
        bundleIdentifiers.contains(bundleId)
            || bundleIdentifiers.contains { $0.caseInsensitiveCompare(bundleId) == .orderedSame }
            || names.contains(bundleId)
    }

    public static func contains(_ app: AppInfo) -> Bool {
        contains(bundleId: app.bundleId) || names.contains(app.name)
    }
}
