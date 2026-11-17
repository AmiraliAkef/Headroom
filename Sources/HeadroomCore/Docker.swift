import AppKit

public enum Docker {
    public static let bundleId = "com.docker.docker"

    /// Docker Desktop's VM runs as a Virtualization.framework XPC service outside
    /// the Docker bundle (or as qemu/krunkit inside it, which bundle attribution
    /// already catches). Note: other VM apps use the same XPC service, so with
    /// those running this over-counts. It's only used for ranking.
    public static func isVMProcess(_ p: ProcessSample) -> Bool {
        p.path.hasSuffix("/com.apple.Virtualization.VirtualMachine")
    }

    public static func runningApp(in apps: [AppInfo]) -> AppInfo? {
        apps.first { $0.bundleId == bundleId }
    }

    /// Stop with `docker desktop stop` when the CLI exists, otherwise quit the app.
    public static func stop(_ app: AppInfo, timeout: TimeInterval = 60) -> Bool {
        if let docker = Shell.which("docker"),
           let r = Shell.run(docker, ["desktop", "stop"], timeout: timeout), r.status == 0,
           RunningApps.waitForExit(app.pid, timeout: 15) {
            return true
        }
        // The engine may be stopped while the app lingers; quit the app itself.
        return RunningApps.quit(app, timeout: timeout) == .quit
    }

    public static func start() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return RunningApps.open(bundleURL: "/Applications/Docker.app")
        }
        return RunningApps.open(bundleURL: url.path)
    }
}
