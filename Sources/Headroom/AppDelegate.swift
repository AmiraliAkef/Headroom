import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.registerOnFirstLaunch()
        let c = StatusItemController()
        controller = c
        c.start()

        // Pause the update loop while the Mac or its screens sleep.
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak c] _ in c?.pause() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak c] _ in c?.resume() }
        }
    }
}
