import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let store = SessionStore()
    private let claude = ClaudeSource()
    private let codex = CodexSource()
    private let overlay = OverlayController()
    private let displays = DisplayTracker()
    private var watcher: FileWatcher?
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var current: [Session] = []

    private static let debug = CommandLine.arguments.contains("--debug")

    /// nil = keep while the session is open.
    private static let doneOptions: [(String, TimeInterval?)] = [
        ("Don't Show", 0), ("1 Minute", 60), ("5 Minutes", 300), ("15 Minutes", 900),
        ("1 Hour", 3600), ("While Session Is Open", nil),
    ]

    private var anchor: Anchor {
        get { Anchor(rawValue: defaults.string(forKey: "corner") ?? "") ?? .topRight }
        set { defaults.set(newValue.rawValue, forKey: "corner") }
    }
    private var layout: Layout {
        get { Layout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .vertical }
        set { defaults.set(newValue.rawValue, forKey: "layout") }
    }
    private var labelMode: LabelMode {
        get { LabelMode(rawValue: defaults.string(forKey: "labels") ?? "") ?? .project }
        set { defaults.set(newValue.rawValue, forKey: "labels") }
    }
    private var doneWindow: TimeInterval? {
        get {
            let v = defaults.object(forKey: "doneSeconds") as? Double ?? 300
            return v < 0 ? nil : v
        }
        set { defaults.set(newValue ?? -1, forKey: "doneSeconds") }
    }
    /// Clear finished rows once you've looked at them (pointer leaves the list, or you click one).
    private var removeOnHover: Bool {
        get { defaults.object(forKey: "removeOnHover") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "removeOnHover") }
    }
    private func flag(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
    private var showList: Bool {
        get { flag("showList", default: true) }
        set { defaults.set(newValue, forKey: "showList") }
    }
    private var showTime: Bool {
        get { flag("showTime", default: true) }
        set { defaults.set(newValue, forKey: "showTime") }
    }
    private var followDisplay: Bool {
        get { flag("followDisplay", default: true) }
        set { defaults.set(newValue, forKey: "followDisplay") }
    }
    private func enabled(_ agent: Agent) -> Bool {
        defaults.object(forKey: "show.\(agent.rawValue)") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: "Agent Indicator")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        overlay.anchor = anchor
        overlay.onAnchorChange = { [weak self] anchor in self?.anchor = anchor }
        overlay.layout = layout
        overlay.isEnabled = showList
        overlay.showsElapsedTime = showTime
        displays.onChange = { [weak self] screen in self?.overlay.screen = screen }
        if followDisplay { displays.start() }
        overlay.onClick = { [weak self] key in self?.open(key) }
        // Once you've looked at the list and moved away, finished items have done their job.
        overlay.onExit = { [weak self] in
            guard let self, self.removeOnHover, self.current.contains(where: { $0.phase == .done }) else { return }
            self.store.dismissFinished()
            self.refresh(fullCodexScan: false)
        }

        let claudeDir = claude.directory.path
        let codexDir = realPath(codex.directory.path)
        watcher = FileWatcher(paths: [claudeDir, codexDir]) { [weak self] paths in
            guard let self else { return }
            let codexPaths = paths.filter { $0.hasPrefix(codexDir) && $0.hasSuffix(".jsonl") }
            let allKnown = self.codex.filesChanged(codexPaths)
            self.refresh(fullCodexScan: !allKnown)
        }

        // Safety net: process liveness, open/closed Codex sessions, and "done" expiry.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh(fullCodexScan: true)
        }
        timer?.tolerance = 0.2
        refresh(fullCodexScan: true)
    }

    private func refresh(fullCodexScan: Bool, force: Bool = false) {
        var raw: [RawSession] = []
        if enabled(.claude) { raw += claude.sessions() }
        if enabled(.codex) { raw += codex.sessions(discover: fullCodexScan) }
        let sessions = store.reconcile(raw, showDoneFor: doneWindow)
        if Self.debug {
            let line = sessions.map { "\($0.agent.rawValue):\($0.info.project):\($0.phase) [\($0.info.title ?? "-")]" }
                .joined(separator: "  ")
            FileHandle.standardError.write(Data("\(Date()) \(line)\n".utf8))
        }
        guard force || sessions != current else { return }
        current = sessions
        overlay.show(sessions, labels: labelMode.labels(for: sessions))
        updateStatusItem()
    }

    /// Menu bar icon: number of working chats, plus an orange dot while one is waiting on you.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let working = current.filter { $0.phase == .working }.count
        let waiting = current.contains { $0.phase == .waiting }
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        if working > 0 {
            title.append(NSAttributedString(string: "\(working)", attributes: [.font: font]))
        }
        if waiting {
            title.append(NSAttributedString(string: working > 0 ? " ●" : "●", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.systemOrange, .baselineOffset: 1.5,
            ]))
        }
        button.attributedTitle = title
        button.imagePosition = title.length == 0 ? .imageOnly : .imageLeading
        button.setAccessibilityLabel("Agent Indicator: \(working) working" + (waiting ? ", needs input" : ""))
    }

    /// Jump to a session, and clear its checkmark since you've now seen it.
    private func open(_ key: String) {
        guard let session = current.first(where: { $0.key == key }) else { return }
        Focuser.focus(session)
        if removeOnHover, session.phase == .done {
            store.dismissFinished([key])
            refresh(fullCodexScan: false)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if current.isEmpty {
            menu.addItem(disabled("No active sessions"))
        } else {
            for s in current {
                let state = s.phase == .working ? "Working" : s.phase == .waiting ? "Needs input" : "Done"
                let name = [s.info.project, s.info.title].compactMap { $0 }.joined(separator: " — ")
                let item = NSMenuItem(title: "\(name)  ·  \(state)", action: #selector(openFromMenu(_:)), keyEquivalent: "")
                item.representedObject = s.key
                item.target = self
                item.image = AgentIcon.image(for: s.agent).resized(16)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let position = NSMenu()
        for (i, a) in Anchor.allCases.enumerated() {
            if i == 3 || i == 5 { position.addItem(.separator()) }   // top · middle · bottom
            let item = NSMenuItem(title: a.title, action: #selector(setAnchor(_:)), keyEquivalent: "")
            item.representedObject = a.rawValue
            item.state = a == anchor ? .on : .off
            item.target = self
            position.addItem(item)
        }
        menu.addItem(submenu("Position", position))

        position.addItem(.separator())
        position.addItem(toggle("Follow Active Display", followDisplay, #selector(toggleFollowDisplay)))
        position.addItem(disabled("Tip: drag the list to move it"))

        let layouts = NSMenu()
        for l in Layout.allCases {
            let item = NSMenuItem(title: l.title, action: #selector(setLayout(_:)), keyEquivalent: "")
            item.representedObject = l.rawValue
            item.state = l == layout ? .on : .off
            item.target = self
            layouts.addItem(item)
        }
        menu.addItem(submenu("Layout", layouts))

        let labels = NSMenu()
        for m in LabelMode.allCases {
            let item = NSMenuItem(title: m.menuTitle, action: #selector(setLabelMode(_:)), keyEquivalent: "")
            item.representedObject = m.rawValue
            item.state = m == labelMode ? .on : .off
            item.target = self
            labels.addItem(item)
        }
        menu.addItem(submenu("Labels", labels))

        let done = NSMenu()
        for (title, value) in Self.doneOptions {
            let item = NSMenuItem(title: title, action: #selector(setDoneWindow(_:)), keyEquivalent: "")
            item.representedObject = value ?? -1
            item.state = value == doneWindow ? .on : .off
            item.target = self
            done.addItem(item)
        }
        done.addItem(.separator())
        let hover = NSMenuItem(title: "Remove on Hover", action: #selector(toggleRemoveOnHover), keyEquivalent: "")
        hover.state = removeOnHover ? .on : .off
        hover.target = self
        done.addItem(hover)
        menu.addItem(submenu("Show Finished", done))

        menu.addItem(toggle("Show Elapsed Time", showTime, #selector(toggleShowTime)))
        menu.addItem(toggle("Show Floating List", showList, #selector(toggleShowList)))

        let agents = NSMenu()
        for a in Agent.allCases {
            let item = NSMenuItem(title: a.displayName, action: #selector(toggleAgent(_:)), keyEquivalent: "")
            item.representedObject = a.rawValue
            item.state = enabled(a) ? .on : .off
            item.target = self
            agents.addItem(item)
        }
        menu.addItem(submenu("Agents", agents))

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Agent Indicator", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = on ? .on : .off
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func setAnchor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = Anchor(rawValue: raw) else { return }
        anchor = a
        overlay.anchor = a
    }

    @objc private func setLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Layout(rawValue: raw) else { return }
        layout = l
        overlay.layout = l
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { open(key) }
    }

    @objc private func setLabelMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = LabelMode(rawValue: raw) else { return }
        labelMode = m
        refresh(fullCodexScan: false, force: true)
    }

    @objc private func toggleShowTime() {
        showTime.toggle()
        overlay.showsElapsedTime = showTime
    }

    @objc private func toggleShowList() {
        showList.toggle()
        overlay.isEnabled = showList
    }

    @objc private func toggleFollowDisplay() {
        followDisplay.toggle()
        if followDisplay {
            displays.start()
        } else {
            displays.stop()
            overlay.screen = nil
        }
    }

    @objc private func toggleRemoveOnHover() {
        removeOnHover.toggle()
    }

    @objc private func setDoneWindow(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        doneWindow = v < 0 ? nil : v
        refresh(fullCodexScan: false)
    }

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = Agent(rawValue: raw) else { return }
        defaults.set(!enabled(a), forKey: "show.\(a.rawValue)")
        refresh(fullCodexScan: true)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
    }
}

private extension NSImage {
    func resized(_ side: CGFloat) -> NSImage {
        let copy = self.copy() as! NSImage
        copy.size = NSSize(width: side, height: side)
        return copy
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
