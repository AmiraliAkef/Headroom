import AppKit
import HeadroomCore
import UserNotifications

/// Alerts and notifications for prep/restore.
enum PrepUI {
    enum Choice { case prep, cancel }

    /// The confirmation alert. Cancel never changes anything.
    static func confirm(_ plan: PrepPlan) -> Choice {
        let alert = NSAlert()
        alert.messageText = "Prep for \(plan.profile.displayName)?"
        var lines = [String(format: "Target %.1f GB available, now %.1f GB. Need ~%.1f GB more.",
                            plan.targetGB, plan.before.availableGB, Double(plan.neededBytes) / bytesPerGB), ""]
        for item in plan.items {
            let c = item.candidate
            var line = String(format: "%@ %@  ~%.1f GB", c.verb, c.name, c.estimatedGB)
            if item.reachesTarget { line += "  ← target expected here" }
            lines.append(line)
        }
        lines.append("")
        lines.append(plan.expectedToReachTarget
            ? "Stops as soon as the target is reached, so later items may not be needed."
            : String(format: "Even all of this (~%.1f GB) may not reach the target.",
                     Double(plan.expectedTotalBytes) / bytesPerGB))
        lines.append("Apps are asked to quit normally; any that refuse (e.g. unsaved changes) are skipped.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Prep")
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn ? .prep : .cancel
    }

    /// Checklist of what to restore. Apps that had no window open when prep quit
    /// them start unticked. Returns nil on Cancel.
    static func chooseRestore(_ items: [RestoreItem]) -> Set<RestoreItem>? {
        let alert = NSAlert()
        alert.messageText = "Restore which apps?"
        alert.informativeText = "Unticked items stay in the list, so you can restore them later."
        let boxes = items.map { ri -> NSButton in
            let title = ri.wasInForeground ? ri.label : "\(ri.label)  (had no window open)"
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = ri.wasInForeground ? .on : .off
            return b
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard run(alert) == .alertFirstButtonReturn else { return nil }
        return Set(zip(items, boxes).filter { $0.1.state == .on }.map(\.0))
    }

    static func info(_ title: String, _ text: String, editButton: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if editButton { alert.addButton(withTitle: "Edit Profiles…") }
        return run(alert) == .alertSecondButtonReturn
    }

    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // An accessory app has to come forward or the alert opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    // MARK: Notifications

    /// Asked the first time prep runs, not at launch.
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    static func summary(of r: PrepResult) -> (title: String, body: String) {
        let after = String(format: "%.1f GB available", Double(r.availableAfter) / bytesPerGB)
        let freed = max(0, Double(r.freedBytes) / bytesPerGB)
        var body = r.handled.isEmpty ? "Nothing was quit." : r.handled.map(\.name).joined(separator: ", ")
        if !r.skipped.isEmpty {
            body += "\nSkipped: " + r.skipped.map { "\($0.candidate.name) (\($0.reason))" }.joined(separator: ", ")
        }
        if r.targetReached {
            return (String(format: "Freed %.1f GB — %@", freed, after), body)
        }
        return (String(format: "Target not reached — %@", after),
                body + String(format: "\nEverything allowed was handled; target is %.1f GB.",
                              Double(r.targetBytes) / bytesPerGB))
    }

    static func summary(of r: RestoreResult) -> (title: String, body: String) {
        var parts = r.reopened.map(\.name) + r.alreadyRunning.map(\.name)
        if r.dockerStarted { parts.append("Docker") }
        parts += r.claudeReopened.map { "Claude (\($0.label))" }
        var body = parts.isEmpty ? "Nothing to reopen." : "Reopened " + parts.joined(separator: ", ")
        var failed = r.failed.map(\.name)
        if r.dockerFailed { failed.append("Docker") }
        failed += r.claudeFailed.map { "Claude (\($0.label))" }
        if !failed.isEmpty { body += "\nCouldn't reopen: " + failed.joined(separator: ", ") }
        if !r.modelsNotReloaded.isEmpty { body += "\nModels not reloaded." }
        return (r.ok ? "Restored" : "Restored with problems", body)
    }
}
