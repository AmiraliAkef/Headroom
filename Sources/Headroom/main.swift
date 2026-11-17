import AppKit
import ServiceManagement

// `Headroom --unregister` (used by build.sh uninstall) removes the login item and exits.
if CommandLine.arguments.contains("--unregister") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon (LSUIElement also says so)
app.run()
