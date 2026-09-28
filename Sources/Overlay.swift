import AppKit
import QuartzCore

enum Corner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

enum Layout: String, CaseIterable {
    case vertical, horizontal

    var title: String { self == .vertical ? "Vertical" : "Horizontal" }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// The small floating list. Stays on every Space above normal windows, never takes focus.
final class OverlayController {
    private let panel: OverlayPanel
    private let background = NSVisualEffectView()
    private let container = FlippedView()
    private var rows: [String: RowView] = [:]
    private var order: [String] = []
    private var clock: Timer?
    private var presenceCheck: Timer?
    private var targetFrame = NSRect.zero
    private var maskRadius: CGFloat = 0

    private static let resizeDuration: TimeInterval = 0.28

    // Moving to another corner or display jumps; only changes in content animate.
    var corner: Corner = .topRight { didSet { relayout(animated: false) } }
    var layout: Layout = .vertical { didSet { relayout(animated: false) } }
    /// The display to sit on; nil means the menu-bar display.
    var screen: NSScreen? { didSet { relayout(animated: false) } }
    /// Off hides the list entirely (the menu bar icon still shows status).
    var isEnabled = true { didSet { updateVisibility() } }
    var showsElapsedTime = true {
        didSet {
            rows.values.forEach { $0.showsTime = showsElapsedTime }
            relayout()
        }
    }
    /// A row was clicked.
    var onClick: ((String) -> Void)?
    /// The pointer left the list (the user has had a look).
    var onExit: (() -> Void)? {
        get { container.onExit }
        set { container.onExit = newValue }
    }

    private let margin: CGFloat = 10
    private let inset: CGFloat = 4

    init() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 30),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(container)
        panel.contentView = background

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.relayout(animated: false) }

        // Checked 4× a second so the per-second count never skips; labels only redraw when the text changes.
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        clock?.tolerance = 0.05
    }

    func show(_ sessions: [Session], labels: [String: String]) {
        let keys = Set(sessions.map(\.key))
        let animate = shouldAnimate
        for (key, row) in rows where !keys.contains(key) {
            rows[key] = nil
            guard animate else { row.removeFromSuperview(); continue }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.resizeDuration * 0.6
                row.animator().alphaValue = 0
            }, completionHandler: { row.removeFromSuperview() })
        }
        for s in sessions {
            let row = rows[s.key] ?? {
                let r = RowView(key: s.key, agent: s.agent)
                r.onClick = { [weak self] key in self?.onClick?(key) }
                r.showsTime = showsElapsedTime
                r.frame = .zero                        // marks it as new for the fade-in
                container.addSubview(r)
                rows[s.key] = r
                return r
            }()
            row.label = labels[s.key]
            row.since = s.since
            row.phase = s.phase
        }
        order = sessions.map(\.key)
        relayout()
        updateVisibility()
        watchForPresence()
    }

    /// Chats that finished while you were away stay green until you next touch the Mac.
    /// "Last input" comes from the window server and covers mouse and keyboard, no permission needed.
    private func watchForPresence() {
        guard presenceCheck == nil, rows.values.contains(where: \.unseen) else { return }
        presenceCheck = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                               eventType: CGEventType(rawValue: ~0)!)
            let lastInput = Date().addingTimeInterval(-idle)
            for row in self.rows.values where row.unseen && lastInput > row.finishedAt { row.unseen = false }
            if !self.rows.values.contains(where: \.unseen) {
                timer.invalidate()
                self.presenceCheck = nil
            }
        }
    }

    private func updateVisibility() {
        if isEnabled && !order.isEmpty {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func tick() {
        guard panel.isVisible, showsElapsedTime else { return }
        let now = Date()
        var changed = false
        for row in rows.values where row.updateTime(now: now) { changed = true }
        if changed { relayout() }
    }

    private var shouldAnimate: Bool {
        panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Lays the rows out at their final positions and resizes the window to fit.
    ///
    /// When animated, the content is pinned to the chosen corner at its final size, and the
    /// window edge glides open or closed over it. Rows slide to their new places, new rows fade in.
    private func relayout(animated: Bool = true) {
        // Fall back to the menu-bar display if the tracked one was unplugged.
        let live = NSScreen.screens.first { $0.number != nil && $0.number == screen?.number }
        guard let screen = live ?? NSScreen.screens.first else { return }
        let list = order.compactMap { rows[$0] }
        let rowHeight = RowView.height
        var width: CGFloat, height: CGFloat
        var frames: [(RowView, NSRect)] = []

        switch layout {
        case .vertical:
            let rowWidth = list.map(\.preferredWidth).max() ?? RowView.minWidth
            for (i, row) in list.enumerated() {
                frames.append((row, NSRect(x: inset, y: inset + CGFloat(i) * rowHeight, width: rowWidth, height: rowHeight)))
            }
            width = rowWidth + inset * 2
            height = CGFloat(max(1, list.count)) * rowHeight + inset * 2
        case .horizontal:
            var x = inset
            for row in list {
                frames.append((row, NSRect(x: x, y: inset, width: row.preferredWidth, height: rowHeight)))
                x += row.preferredWidth
            }
            width = max(x, RowView.minWidth + inset) + inset
            height = rowHeight + inset * 2
        }

        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let area = screen.visibleFrame
        let frame = NSRect(x: left ? area.minX + margin : area.maxX - margin - width,
                           y: top ? area.maxY - margin - height : area.minY + margin,
                           width: width, height: height)
        let animate = animated && shouldAnimate

        // The content keeps its final size and sticks to the anchored corner while the window resizes.
        // Re-pinning moves the container, so remember where rows are on screen and put them back.
        let onScreen = list.map { $0.frame.isEmpty ? nil : container.convert($0.frame, to: background) }
        let bounds = background.bounds
        container.autoresizingMask = [left ? .maxXMargin : .minXMargin, top ? .minYMargin : .maxYMargin]
        container.frame = NSRect(x: left ? 0 : bounds.width - width,
                                 y: top ? bounds.height - height : 0,
                                 width: width, height: height)

        for (row, rect) in onScreen.enumerated().compactMap({ i, r in r.map { (list[i], $0) } }) {
            row.frame = container.convert(rect, from: background)
        }

        for (row, rect) in frames {
            let isNew = row.frame.isEmpty
            if animate && !isNew {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.resizeDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    row.animator().frame = rect
                }
            } else {
                row.frame = rect
            }
            if isNew && animate {
                row.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.resizeDuration
                    row.animator().alphaValue = 1
                }
            }
        }

        // The mask stretches (cap insets), so it only needs replacing when the corner radius changes.
        let radius = layout == .horizontal ? height / 2 : 11
        if radius != maskRadius {
            maskRadius = radius
            background.maskImage = .roundedRect(width: radius * 2 + 1, height: radius * 2 + 1, radius: radius)
        }

        guard frame != targetFrame else { return }
        targetFrame = frame
        if animate {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.resizeDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }
}

// MARK: - One session: logo + label (or a status icon when labels are off)

/// With a label: working text shimmers, waiting text pulses in yellow, finished text is dimmed.
/// Without one (Icons Only): a spinner, "!" or check next to the logo.
/// A row flashes once when its turn finishes or it starts waiting on you.
private final class RowView: NSView {
    static let height: CGFloat = 24
    static let minWidth: CGFloat = 6 + 16 + 5 + 13 + 6
    private static let maxLabelWidth: CGFloat = 150
    private static let restingAlpha: CGFloat = 0.7   // finished text, and the shimmer's dim base

    /// Yellow reads well on the dark material; on the light one it needs to be orange to be legible.
    static let attention = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemYellow : .systemOrange
    }

    let key: String
    var onClick: ((String) -> Void)?
    var phase: Phase = .done {
        didSet {
            guard phase != oldValue else { return }
            let justFinished = oldValue == .working && phase == .done
            if justFinished { finishedAt = Date() }
            unseen = justFinished                         // re-renders
            if phase == .waiting || justFinished { flash() }
        }
    }
    /// Finished while you weren't touching the Mac: shimmers green until you're back.
    var unseen = false { didSet { render() } }
    private(set) var finishedAt = Date.distantPast
    var label: String? {
        didSet {
            guard label != oldValue else { return }
            text.stringValue = label ?? ""
            render()
            needsLayout = true
        }
    }
    var since: Date? { didSet { if since != oldValue { _ = updateTime(now: Date()) } } }
    var showsTime = true { didSet { if showsTime != oldValue { _ = updateTime(now: Date()) } } }

    private let logo = NSImageView()
    private let textHost = NSView()           // masked by the shimmer gradient, pulsed when waiting
    private let text = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let shimmer = CAGradientLayer()
    private let glow = CALayer()
    private let spinner = SpinnerView()
    private let badge = NSImageView()
    private var hovered = false { didSet { updateHighlight() } }

    private var timeVisible: Bool { !time.stringValue.isEmpty && label != nil }
    private var timeWidth: CGFloat {
        let reserve = ("00m" as NSString).size(withAttributes: [.font: time.font!]).width
        let actual = (time.stringValue as NSString).size(withAttributes: [.font: time.font!]).width
        return ceil(max(reserve, actual)) + 2
    }

    var preferredWidth: CGFloat {
        guard label != nil else { return Self.minWidth }
        let measured = (text.stringValue as NSString).size(withAttributes: [.font: text.font!]).width
        let timePart = timeVisible ? 6 + timeWidth : 0
        return 28 + min(ceil(measured) + 4, Self.maxLabelWidth) + timePart + 8
    }

    init(key: String, agent: Agent) {
        self.key = key
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 7

        glow.cornerRadius = 7
        glow.opacity = 0
        layer?.addSublayer(glow)

        logo.image = AgentIcon.image(for: agent)
        logo.imageScaling = .scaleProportionallyUpOrDown
        text.font = .systemFont(ofSize: 12, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        textHost.wantsLayer = true
        textHost.addSubview(text)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        badge.imageScaling = .scaleProportionallyUpOrDown
        badge.wantsLayer = true

        // A bright band sweeping left to right over text at the resting opacity.
        let dim = CGColor(gray: 0, alpha: Self.restingAlpha), full = CGColor(gray: 0, alpha: 1)
        shimmer.colors = [dim, full, dim]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [0, 0.15, 0.3]

        for v in [logo, textHost, time, spinner, badge] as [NSView] { addSubview(v) }
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        logo.frame = NSRect(x: 6, y: midY - 8, width: 16, height: 16)
        let statusRect = NSRect(x: bounds.maxX - 6 - 13, y: midY - 6.5, width: 13, height: 13)
        spinner.frame = statusRect
        badge.frame = statusRect

        var textRight = bounds.maxX - 8
        if timeVisible {
            let h = ceil(time.intrinsicContentSize.height)
            time.frame = NSRect(x: textRight - timeWidth, y: midY - h / 2, width: timeWidth, height: h)
            textRight = time.frame.minX - 6
        }
        let textHeight = ceil(text.intrinsicContentSize.height)
        textHost.frame = NSRect(x: 28, y: midY - textHeight / 2, width: max(0, textRight - 28), height: textHeight)
        text.frame = textHost.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.frame = textHost.bounds
        glow.frame = bounds
        CATransaction.commit()
    }

    /// Refreshes the elapsed-time text. Returns true if the row's width may have changed.
    func updateTime(now: Date) -> Bool {
        let value = (showsTime && phase != .done) ? since.map { Self.elapsed(now.timeIntervalSince($0)) } ?? "" : ""
        guard value != time.stringValue else { return false }
        let appearing = time.stringValue.isEmpty && !value.isEmpty
        time.stringValue = value
        time.isHidden = !timeVisible
        if appearing && window?.isVisible == true {
            time.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                time.animator().alphaValue = 1
            }
        }
        needsLayout = true
        return true
    }

    /// 0s, 1s … 59s, then 1m, 2m … 59m, then 1h 5m.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    private func render() {
        let labelled = label != nil
        textHost.isHidden = !labelled
        spinner.isHidden = labelled || phase != .working
        badge.isHidden = labelled || phase == .working
        _ = updateTime(now: Date())

        if labelled {
            switch phase {
            case .working: text.textColor = .labelColor
            case .waiting: text.textColor = Self.attention
            case .done: text.textColor = unseen ? .systemGreen : NSColor.labelColor.withAlphaComponent(Self.restingAlpha)
            }
            setShimmering(phase == .working || (phase == .done && unseen))   // green shimmer when unseen
            setPulsing(textHost, phase == .waiting)
            setPulsing(badge, false)
        } else {
            setShimmering(false)
            setPulsing(textHost, false)
            switch phase {
            case .working: break
            case .waiting: badge.image = Self.symbol("exclamationmark.circle.fill", Self.attention)
            case .done: badge.image = Self.symbol("checkmark.circle.fill", .systemGreen)
            }
            setPulsing(badge, phase == .waiting)
        }
    }

    private func setShimmering(_ on: Bool) {
        guard let host = textHost.layer else { return }
        if !on {
            host.mask = nil
            shimmer.removeAllAnimations()
            return
        }
        guard host.mask == nil else { return }
        host.mask = shimmer
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.4, -0.2, 0]
        sweep.toValue = [1, 1.2, 1.4]
        sweep.duration = 1.4
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        shimmer.add(sweep, forKey: "shimmer")
    }

    /// A slow breathe that says "come back and answer me".
    private func setPulsing(_ view: NSView, _ on: Bool) {
        guard let layer = view.layer else { return }
        if !on { layer.removeAnimation(forKey: "pulse"); return }
        guard layer.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        layer.add(pulse, forKey: "pulse")
    }

    /// Two quick glows behind the row: green-ish white when a turn finishes, yellow when it needs you.
    private func flash() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = phase == .waiting ? Self.attention : NSColor.labelColor
            glow.backgroundColor = color.withAlphaComponent(0.22).cgColor
        }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [0, 1, 0.15, 1, 0]
        blink.keyTimes = [0, 0.12, 0.4, 0.55, 1]
        blink.duration = 1.4
        glow.add(blink, forKey: "flash")
    }

    // Clicks land even though the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(key) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func viewDidChangeEffectiveAppearance() { updateHighlight() }

    private func updateHighlight() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovered ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
        }
    }

    private static func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [.white, color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

private final class SpinnerView: NSView {
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 1.8
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.72
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.2, dy: 1.2), transform: nil)
        updateColor()
        startIfNeeded()
    }

    override func viewDidMoveToWindow() { startIfNeeded() }
    override func viewDidChangeEffectiveAppearance() { updateColor() }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = NSColor.labelColor.withAlphaComponent(0.75).cgColor
        }
    }

    private func startIfNeeded() {
        guard arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

// MARK: - Icons

enum AgentIcon {
    private static var cache: [Agent: NSImage] = [:]

    static func image(for agent: Agent) -> NSImage {
        if let cached = cache[agent] { return cached }
        let bundleIDs: [String]
        switch agent {
        case .claude: bundleIDs = ["com.anthropic.claudefordesktop"]
        case .codex: bundleIDs = ["com.openai.codex"]
        }
        let appIcon = bundleIDs.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        let image = appIcon ?? drawn(agent)
        cache[agent] = image
        return image
    }

    /// Fallback when the desktop app isn't installed (terminal-only usage).
    private static func drawn(_ agent: Agent) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            switch agent {
            case .claude:
                NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
                let c = NSPoint(x: rect.midX, y: rect.midY)
                for i in 0..<12 {
                    let a = CGFloat(i) * .pi / 6
                    let len: CGFloat = i % 2 == 0 ? 15 : 12
                    let ray = NSBezierPath()
                    ray.move(to: NSPoint(x: c.x + cos(a + 0.18) * 3, y: c.y + sin(a + 0.18) * 3))
                    ray.line(to: NSPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
                    ray.line(to: NSPoint(x: c.x + cos(a - 0.18) * 3, y: c.y + sin(a - 0.18) * 3))
                    ray.close(); ray.fill()
                }
            case .codex:
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
                let s = NSAttributedString(string: ">_", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
                    .foregroundColor: NSColor.white,
                ])
                let size = s.size()
                s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
            return true
        }
    }
}

private extension NSImage {
    static func roundedRect(width: CGFloat, height: CGFloat, radius r: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}
