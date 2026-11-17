import AppKit
import HeadroomCore

/// The menu bar label and its dropdown.
///
/// The live loop only reads CPU ticks, VM stats and whether the session file exists:
/// a few syscalls per tick. Per-app scanning happens only when building a prep plan.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let label = StatusLabelView()
    private let cpuMonitor = CPUMonitor()
    private let store = SessionStore()
    private let work = DispatchQueue(label: "headroom.prep", qos: .userInitiated)

    private var timer: Timer?
    private var paused = false
    private var menuOpen = false
    private var lastCPU: CPUUsage?
    private var lastMemory: MemorySnapshot?
    private var lastRendered: NSAttributedString?
    private var restorePending = false
    private var busyText: String?  // non-nil while prep/restore runs

    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private let menuFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize,
                                                            weight: .regular)

    // Menu items that change.
    private let menu = NSMenu()
    private let cpuRow = NSMenuItem(), userRow = NSMenuItem(), systemRow = NSMenuItem()
    private let memRow = NSMenuItem(), availRow = NSMenuItem(), pressureRow = NSMenuItem()
    private let compressedRow = NSMenuItem(), swapRow = NSMenuItem()
    private let prepItem = NSMenuItem(title: "Prep for Heavy Task", action: nil, keyEquivalent: "")
    private let busyItem = NSMenuItem()
    private let restoreItem = NSMenuItem(title: "Restore Apps", action: nil, keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
    private let showAvailableItem = NSMenuItem(title: "Show Available RAM", action: #selector(toggleShowAvailable),
                                               keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh every", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
    private let allowLoginItem = NSMenuItem(title: "Allow in Login Items…", action: #selector(openLoginSettings),
                                            keyEquivalent: "")

    override init() {
        super.init()
        buildMenu()
    }

    // MARK: Update loop

    func start() {
        _ = cpuMonitor.sample()  // baseline
        tick()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = Settings.refreshInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.2  // lets macOS coalesce wakeups
        RunLoop.main.add(t, forMode: .common)  // .common: keeps ticking while the menu is open
        timer = t
    }

    func pause() {
        guard !paused else { return }
        paused = true
        timer?.invalidate()
        timer = nil
    }

    func resume() {
        guard paused else { return }
        paused = false
        cpuMonitor.reset()
        _ = cpuMonitor.sample()  // fresh baseline; sleep time shouldn't count as idle
        lastCPU = nil
        tick()
        scheduleTimer()
    }

    private func tick() {
        if let u = cpuMonitor.sample() { lastCPU = u }
        if let m = MemoryMonitor.snapshot() { lastMemory = m }
        restorePending = store.exists
        updateLabel()
        if menuOpen { updateDetailRows() }
    }

    private func updateLabel() {
        let text = MenuBarText.render(cpu: lastCPU, memory: lastMemory, mode: Settings.displayMode,
                                      restorePending: restorePending, showAvailable: Settings.showAvailable)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        var ram = base
        switch lastMemory?.pressure {
        case .warning?: ram[.foregroundColor] = NSColor.systemYellow
        case .critical?: ram[.foregroundColor] = NSColor.systemRed
        default: break
        }
        let s = NSMutableAttributedString(string: text.cpu + text.separator, attributes: base)
        s.append(NSAttributedString(string: text.ram, attributes: ram))
        s.append(NSAttributedString(string: text.available, attributes: ram))
        s.append(NSAttributedString(string: text.suffix, attributes: base))
        // Only redraw when the text or color actually changes.
        guard s != lastRendered else { return }
        lastRendered = s
        // Drawing into our own view, instead of setting the button's title, avoids an
        // Auto Layout pass on every tick. The item's length only changes when the
        // text's width does (mode switch, ↺ appearing), and the padded digits keep
        // that rare.
        let width = ceil(s.size().width) + 8
        if abs(statusItem.length - width) > 0.5 { statusItem.length = width }
        label.text = s
        statusItem.button?.setAccessibilityLabel(text.string)
        let tip = restorePending ? "Headroom — apps waiting to be restored" : "Headroom"
        if statusItem.button?.toolTip != tip { statusItem.button?.toolTip = tip }  // rarely changes
    }

    // MARK: Menu

    private func detailTitle(_ label: String, _ value: String, indent: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 200)]
        return NSAttributedString(string: "\(label)\t\(value)", attributes: [
            .font: menuFont, .paragraphStyle: style,
            .foregroundColor: indent ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        for (row, indent) in [(cpuRow, false), (userRow, true), (systemRow, true), (memRow, false),
                              (availRow, true), (pressureRow, true), (compressedRow, true), (swapRow, true)] {
            row.isEnabled = false
            row.indentationLevel = indent ? 1 : 0
            menu.addItem(row)
        }
        menu.addItem(.separator())

        prepItem.submenu = NSMenu()
        menu.addItem(prepItem)
        busyItem.isEnabled = false
        busyItem.isHidden = true
        menu.addItem(busyItem)
        restoreItem.submenu = NSMenu()
        menu.addItem(restoreItem)
        menu.addItem(item("Edit Profiles…", #selector(editProfiles)))
        menu.addItem(.separator())

        let displayMenu = NSMenu()
        for mode in DisplayMode.allCases {
            let i = item(mode.label, #selector(setDisplayMode(_:)))
            i.representedObject = mode.rawValue
            displayMenu.addItem(i)
        }
        displayMenu.addItem(.separator())
        showAvailableItem.target = self
        displayMenu.addItem(showAvailableItem)
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        let refreshMenu = NSMenu()
        for interval in Settings.refreshChoices {
            let i = item("\(Int(interval)) s", #selector(setRefresh(_:)))
            i.representedObject = interval
            refreshMenu.addItem(i)
        }
        refreshItem.submenu = refreshMenu
        menu.addItem(refreshItem)

        loginItem.target = self
        menu.addItem(loginItem)
        allowLoginItem.target = self
        menu.addItem(allowLoginItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Activity Monitor", #selector(openActivityMonitor)))
        let quit = NSMenuItem(title: "Quit Headroom", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        if let button = statusItem.button {
            button.title = ""
            label.frame = button.bounds
            label.autoresizingMask = [.width, .height]
            button.addSubview(label)
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        // Re-read the session so a prep/restore done from the CLI shows up.
        restorePending = store.exists
        updateDetailRows()
        updateActionItems()
        updateLabel()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func updateDetailRows() {
        if let c = lastCPU {
            cpuRow.attributedTitle = detailTitle("CPU", pct(c.total))
            userRow.attributedTitle = detailTitle("User", pct(c.user), indent: true)
            systemRow.attributedTitle = detailTitle("System", pct(c.system), indent: true)
        } else {
            cpuRow.attributedTitle = detailTitle("CPU", "--")
            userRow.attributedTitle = detailTitle("User", "--", indent: true)
            systemRow.attributedTitle = detailTitle("System", "--", indent: true)
        }
        guard let m = lastMemory else { return }
        memRow.attributedTitle = detailTitle("Memory", String(format: "%.1f / %.1f GB", m.usedGB, m.totalGB))
        availRow.attributedTitle = detailTitle("Available", String(format: "%.1f GB", m.availableGB), indent: true)
        pressureRow.attributedTitle = detailTitle("Pressure", m.pressure.label, indent: true)
        compressedRow.attributedTitle = detailTitle("Compressed", String(format: "%.1f GB", m.compressedGB),
                                                    indent: true)
        swapRow.attributedTitle = detailTitle("Swap used", String(format: "%.1f GB", m.swapUsedGB), indent: true)
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    private func updateActionItems() {
        let busy = busyText != nil
        busyItem.isHidden = !busy
        busyItem.title = busyText ?? ""
        prepItem.isHidden = busy

        // Profiles, re-read each time so edits to config.json show up.
        let sub = prepItem.submenu!
        sub.removeAllItems()
        let total = lastMemory?.totalGB
        do {
            let cfg = try ConfigLoader.load(totalGB: total)
            for p in cfg.orderedProfiles {
                let i = item(String(format: "%@ (%g GB)", p.displayName, p.targetGB), #selector(startPrep(_:)))
                i.representedObject = p.name
                sub.addItem(i)
            }
            prepItem.isEnabled = true
        } catch {
            let i = NSMenuItem(title: "Config error — Edit Profiles…", action: #selector(editProfiles),
                               keyEquivalent: "")
            i.target = self
            sub.addItem(i)
        }

        let session = store.load()
        let count = session?.restoreCount ?? 0
        restoreItem.title = count > 0 ? "Restore Apps (\(count))" : "Restore Apps"
        restoreItem.isEnabled = session != nil && !busy
        restoreItem.isHidden = false
        buildRestoreMenu(session)

        for i in displayItem.submenu!.items where i.representedObject is String {
            i.state = (i.representedObject as? String) == Settings.displayMode.rawValue ? .on : .off
        }
        showAvailableItem.state = Settings.showAvailable ? .on : .off
        for i in refreshItem.submenu!.items {
            i.state = (i.representedObject as? TimeInterval) == Settings.refreshInterval ? .on : .off
        }

        if LoginItem.usesLaunchAgent {
            loginItem.title = "Launch at login (LaunchAgent)"
            loginItem.state = .on
            loginItem.isEnabled = false
            allowLoginItem.isHidden = true
        } else {
            loginItem.title = "Launch at login"
            loginItem.state = LoginItem.isEnabled ? .on : .off
            loginItem.isEnabled = true
            allowLoginItem.isHidden = !(LoginItem.needsApproval || LoginItem.lastError != nil)
        }
    }

    /// Restore submenu: everything at once, a checklist, or one item per click.
    private func buildRestoreMenu(_ session: Session?) {
        let sub = restoreItem.submenu!
        sub.removeAllItems()
        guard let session else { return }
        let items = session.restoreItems
        let foreground = items.filter(\.wasInForeground)
        if !items.isEmpty {
            let all = item("Restore All", #selector(restoreAll))
            sub.addItem(all)
            if foreground.count != items.count {
                let open = item("Restore Only Apps That Had Windows (\(foreground.count))",
                                #selector(restoreForeground))
                open.isEnabled = !foreground.isEmpty
                sub.addItem(open)
            }
            sub.addItem(item("Choose…", #selector(chooseRestore)))
            sub.addItem(.separator())
            for (n, ri) in items.enumerated() {
                let title = ri.wasInForeground ? ri.label : "\(ri.label) — had no window open"
                let i = item(title, #selector(restoreOne(_:)))
                i.tag = n
                i.toolTip = "Restore just this one; the rest stay in the list."
                sub.addItem(i)
            }
            sub.addItem(.separator())
        }
        sub.addItem(item(items.isEmpty ? "Clear" : "Forget All (Don't Reopen)", #selector(forgetRestore)))
    }

    // MARK: Actions

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) else { return }
        Settings.displayMode = mode
        updateLabel()
    }

    @objc private func toggleShowAvailable() {
        Settings.showAvailable.toggle()
        showAvailableItem.state = Settings.showAvailable ? .on : .off
        updateLabel()
    }

    @objc private func setRefresh(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? TimeInterval else { return }
        Settings.refreshInterval = v
        if !paused { scheduleTimer() }
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        if LoginItem.lastError != nil || LoginItem.needsApproval { LoginItem.openSystemSettings() }
    }

    @objc private func openLoginSettings() { LoginItem.openSystemSettings() }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func editProfiles() {
        do {
            try ConfigLoader.ensureExists(totalGB: lastMemory?.totalGB)
            NSWorkspace.shared.open(Paths.config)
        } catch {
            _ = PrepUI.info("Can't create the config", error.localizedDescription)
        }
    }

    private func setBusy(_ text: String?) {
        busyText = text
        if menuOpen { updateActionItems() }
    }

    @objc private func startPrep(_ sender: NSMenuItem) {
        guard busyText == nil, let name = sender.representedObject as? String else { return }
        let profile: Profile
        do {
            profile = try ConfigLoader.load(totalGB: lastMemory?.totalGB).profile(name)
        } catch {
            if PrepUI.info("Config error", error.localizedDescription, editButton: true) { editProfiles() }
            return
        }
        setBusy("Checking what can be freed…")
        work.async { [weak self] in
            let engine = PrepEngine()
            let result = Result { try engine.plan(profile: profile) }
            DispatchQueue.main.async { self?.planReady(result, engine: engine) }
        }
    }

    private func planReady(_ result: Result<PrepPlan, Error>, engine: PrepEngine) {
        setBusy(nil)
        let plan: PrepPlan
        switch result {
        case .failure(let e):
            _ = PrepUI.info("Can't prep", e.localizedDescription)
            return
        case .success(let p): plan = p
        }
        if plan.alreadyMet {
            _ = PrepUI.info("Already enough headroom",
                            String(format: "%.1f GB is available; the %@ target is %.1f GB.",
                                   plan.before.availableGB, plan.profile.displayName, plan.targetGB))
            return
        }
        if plan.items.isEmpty {
            if PrepUI.info("Nothing to quit",
                           "Nothing on the \(plan.profile.displayName) quit list is running, and there are no "
                               + "models or Docker to stop.", editButton: true) {
                editProfiles()
            }
            return
        }
        guard PrepUI.confirm(plan) == .prep else { return }  // Cancel never quits anything
        PrepUI.requestNotificationPermission()
        setBusy("Prepping…")
        work.async { [weak self] in
            let r = engine.execute(plan) { event in
                guard case .started(let c) = event else { return }
                let verb = c.verb == "Quit" ? "quitting" : c.verb == "Stop" ? "stopping" : "unloading"
                DispatchQueue.main.async { self?.setBusy("Prepping… \(verb) \(c.name)") }
            }
            DispatchQueue.main.async {
                self?.setBusy(nil)
                self?.tick()
                let s = PrepUI.summary(of: r)
                PrepUI.notify(s.title, s.body)
            }
        }
    }

    @objc private func restoreAll() { restore(only: nil) }

    @objc private func restoreForeground() {
        guard let s = store.load() else { return }
        restore(only: Set(s.restoreItems.filter(\.wasInForeground)))
    }

    @objc private func restoreOne(_ sender: NSMenuItem) {
        guard let items = store.load()?.restoreItems, items.indices.contains(sender.tag) else { return }
        restore(only: [items[sender.tag]])
    }

    @objc private func chooseRestore() {
        guard let items = store.load()?.restoreItems, !items.isEmpty,
              let chosen = PrepUI.chooseRestore(items), !chosen.isEmpty else { return }
        restore(only: chosen)
    }

    @objc private func forgetRestore() {
        guard busyText == nil else { return }
        PrepEngine().forget()
        tick()
    }

    private func restore(only: Set<RestoreItem>?) {
        guard busyText == nil else { return }
        setBusy("Restoring…")
        work.async { [weak self] in
            let r = PrepEngine().restore(only: only) { line in
                DispatchQueue.main.async { self?.setBusy("Restoring… \(line.lowercased())") }
            }
            DispatchQueue.main.async {
                self?.setBusy(nil)
                self?.tick()
                if let r {
                    let s = PrepUI.summary(of: r)
                    PrepUI.notify(s.title, s.body)
                }
            }
        }
    }
}

/// Draws the menu bar text. Changing `text` only marks the view for redisplay,
/// which is much cheaper than changing the status button's title.
final class StatusLabelView: NSView {
    var text = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Own layer, redrawn only when marked: the menu bar (and its copies on other
        // displays) then reuses the cached layer contents instead of re-rendering the tree.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit sets the current appearance to the menu bar's while drawing, so
        // labelColor resolves correctly in light and dark mode.
        let size = text.size()
        let origin = NSPoint(x: ((bounds.width - size.width) / 2).rounded(),
                             y: ((bounds.height - size.height) / 2).rounded())
        text.draw(at: origin)
    }

    // Clicks go to the status button underneath, which opens the menu.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
