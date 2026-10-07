import AppKit
import QuartzCore

/// Where the list sits: the four corners and the middle of each edge.
enum Anchor: String, CaseIterable {
    case topLeft, topCenter, topRight, middleLeft, middleRight, bottomLeft, bottomCenter, bottomRight

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .middleRight: return "Middle Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }

    enum Edge { case start, center, end }

    var horizontal: Edge {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: return .start
        case .topCenter, .bottomCenter: return .center
        case .topRight, .middleRight, .bottomRight: return .end
        }
    }

    /// .start is the top.
    var vertical: Edge {
        switch self {
        case .topLeft, .topCenter, .topRight: return .start
        case .middleLeft, .middleRight: return .center
        case .bottomLeft, .bottomCenter, .bottomRight: return .end
        }
    }

    /// The list's frame at this anchor, for a list of `size` on a display's usable area.
    func frame(size: NSSize, in area: NSRect, margin: CGFloat) -> NSRect {
        let x: CGFloat
        switch horizontal {
        case .start: x = area.minX + margin
        case .center: x = area.midX - size.width / 2
        case .end: x = area.maxX - margin - size.width
        }
        let y: CGFloat
        switch vertical {
        case .start: y = area.maxY - margin - size.height
        case .center: y = area.midY - size.height / 2
        case .end: y = area.minY + margin
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: size).integral
    }
}

/// Mouse handling shared by rows and the list's padding: a press that moves more than a few
/// points becomes a drag of the whole list; otherwise it's a click.
struct PressHandlers {
    var began: () -> Void = {}
    var moved: () -> Void = {}
    /// Returns true if the press was a drag (so it shouldn't count as a click).
    var ended: () -> Bool = { false }
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
    var onEnter: (() -> Void)?
    var press = PressHandlers()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { press.began() }
    override func mouseDragged(with event: NSEvent) { press.moved() }
    override func mouseUp(with event: NSEvent) { _ = press.ended() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// The small floating list. Stays on every Space above normal windows, never takes focus.
final class OverlayController {
    private let panel: OverlayPanel
    private let background = NSVisualEffectView()
    private let container = FlippedView()
    private let beam = BeamView()
    private var hovering = false
    private var collapsed = false
    private var lastChange = Date()
    private static let collapseDelay: TimeInterval = 6
    private var rows: [String: RowView] = [:]
    private var order: [String] = []
    private var clock: Timer?
    private var presenceCheck: Timer?
    private var targetFrame = NSRect.zero
    private var maskRadius: CGFloat = 0
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var isDragging = false
    private var snapping = false

    private static let resizeDuration: TimeInterval = 0.28
    private static let dragThreshold: CGFloat = 4

    // Picking a position from the menu or changing display jumps; content changes and snaps animate.
    var anchor: Anchor = .topRight { didSet { if !snapping { relayout(animated: false) } } }
    var layout: Layout = .vertical { didSet { relayout(animated: false) } }
    /// The display to sit on; nil means the menu-bar display.
    var screen: NSScreen? { didSet { if !snapping { relayout(animated: false) } } }
    /// The list was dragged and snapped to a new position.
    var onAnchorChange: ((Anchor) -> Void)?
    /// Off hides the list entirely (the menu bar icon still shows status).
    var isEnabled = true { didSet { updateVisibility() } }
    var theme: ShimmerTheme = .silver {
        didSet {
            ShimmerTheme.current = theme
            rows.values.forEach { $0.applyTheme() }
            updateBeam()
        }
    }
    var showsElapsedTime = true {
        didSet {
            rows.values.forEach { $0.showsTime = showsElapsedTime }
            relayout()
        }
    }
    /// A row was clicked.
    var onClick: ((String) -> Void)?
    /// The pointer left the list (the user has had a look).
    var onExit: (() -> Void)?
    var effects = Effects() {
        didSet {
            Effects.current = effects
            rows.values.forEach { $0.applyEffects() }
            updateBeam()
            updateCollapse()
            relayout()
        }
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
        beam.frame = background.bounds
        beam.autoresizingMask = [.width, .height]
        background.addSubview(beam)
        panel.contentView = background
        container.press = pressHandlers
        container.onEnter = { [weak self] in
            self?.hovering = true
            self?.updateCollapse()
        }
        container.onExit = { [weak self] in
            guard let self else { return }
            self.hovering = false
            self.lastChange = Date()          // stay open a moment after you look away
            self.onExit?()
        }

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
                r.onFinish = { [weak self] in
                    if Effects.current.borderGlow { self?.beam.celebrate() }
                }
                r.press = pressHandlers
                r.showsTime = showsElapsedTime
                r.frame = .zero                        // marks it as new for the fade-in
                container.addSubview(r)
                rows[s.key] = r
                return r
            }()
            if row.phase != s.phase || row.superview == nil { lastChange = Date() }
            row.label = labels[s.key]
            row.since = s.since
            row.activity = s.activity
            row.beats = s.beats
            row.phase = s.phase
            row.toolTip = s.phase == .unknown ? "Status unconfirmed: no recent activity. Click to check the session." : nil
            row.compact = collapsed
        }
        if order != sessions.map(\.key) { lastChange = Date() }
        order = sessions.map(\.key)
        updateBeam()
        updateCollapse()
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
        guard panel.isVisible else { return }
        updateCollapse()
        let now = Date()
        rows.values.forEach { $0.tickTrace() }
        guard showsElapsedTime else { return }
        var changed = false
        for row in rows.values where row.updateTime(now: now) { changed = true }
        if changed { relayout() }
    }

    /// Border light: pulsing when something waits on you, a travelling comet while anything works.
    private func updateBeam() {
        let phases = rows.values.map(\.phase)
        beam.capsule = layout == .horizontal
        if !Effects.current.borderGlow {
            beam.set(.off)
        } else if phases.contains(.waiting) {
            beam.set(.waiting(RowView.attention))
        } else if phases.contains(.working) {
            beam.set(.working(ShimmerTheme.current.text.withAlphaComponent(1)))
        } else {
            beam.set(.off)
        }
    }

    /// Shrinks to just the logos once every chat is finished (and seen), nobody's hovering,
    /// and nothing has changed for a few seconds. Anything new expands it again.
    private func updateCollapse() {
        let idle = Effects.current.collapseWhenIdle && !hovering && !rows.isEmpty
            && rows.values.allSatisfy { $0.phase == .done && !$0.unseen }
            && Date().timeIntervalSince(lastChange) > Self.collapseDelay
        guard idle != collapsed else { return }
        collapsed = idle
        rows.values.forEach { $0.compact = idle }
        relayout()
    }

    // MARK: Dragging

    private var pressHandlers: PressHandlers {
        PressHandlers(
            began: { [weak self] in self?.pressBegan() },
            moved: { [weak self] in self?.pressMoved() },
            ended: { [weak self] in self?.pressEnded() ?? false })
    }

    private func pressBegan() {
        dragStart = (NSEvent.mouseLocation, panel.frame.origin)
        isDragging = false
    }

    private func pressMoved() {
        guard let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        if !isDragging {
            guard hypot(dx, dy) > Self.dragThreshold else { return }
            isDragging = true
        }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    private func pressEnded() -> Bool {
        defer { dragStart = nil; isDragging = false }
        guard isDragging else { return false }
        isDragging = false
        snapToNearestAnchor()
        return true
    }

    /// Drop point → the closest of the eight positions on the display under the pointer.
    private func snapToNearestAnchor() {
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? panel.screen ?? NSScreen.screens[0]
        let current = panel.frame
        let center = NSPoint(x: current.midX, y: current.midY)
        let best = Anchor.allCases.min { a, b in
            let fa = a.frame(size: current.size, in: target.visibleFrame, margin: margin)
            let fb = b.frame(size: current.size, in: target.visibleFrame, margin: margin)
            return hypot(fa.midX - center.x, fa.midY - center.y) < hypot(fb.midX - center.x, fb.midY - center.y)
        } ?? anchor

        snapping = true
        anchor = best
        screen = target
        snapping = false
        targetFrame = .zero            // force the move even if it lands back where it started
        relayout(animated: true)
        onAnchorChange?(best)
    }

    private var shouldAnimate: Bool {
        panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Lays the rows out at their final positions and resizes the window to fit.
    ///
    /// When animated, the content is pinned to the chosen corner at its final size, and the
    /// window edge glides open or closed over it. Rows slide to their new places, new rows fade in.
    private func relayout(animated: Bool = true) {
        guard !isDragging else { return }      // the snap at the end of the drag lays out again
        // Fall back to the menu-bar display if the tracked one was unplugged.
        let live = NSScreen.screens.first { $0.number != nil && $0.number == screen?.number }
        guard let screen = live ?? NSScreen.screens.first else { return }
        let list = order.compactMap { rows[$0] }
        let rowHeight = RowView.height
        var width: CGFloat, height: CGFloat
        var frames: [(RowView, NSRect)] = []

        switch layout {
        case .vertical:
            let rowWidth = list.map(\.preferredWidth).max() ?? rowHeight
            var y = inset
            for row in list {
                frames.append((row, NSRect(x: inset, y: y, width: rowWidth, height: row.preferredHeight)))
                y += row.preferredHeight
            }
            width = rowWidth + inset * 2
            height = max(y, inset + rowHeight) + inset
        case .horizontal:
            let tallest = list.map(\.preferredHeight).max() ?? rowHeight
            var x = inset
            for row in list {
                frames.append((row, NSRect(x: x, y: inset, width: row.preferredWidth, height: tallest)))
                x += row.preferredWidth
            }
            width = max(x, rowHeight + inset) + inset
            height = tallest + inset * 2
        }

        let frame = anchor.frame(size: NSSize(width: width, height: height), in: screen.visibleFrame, margin: margin)
        let animate = animated && shouldAnimate

        // The content keeps its final size and sticks to the anchored side (or stays centred) while
        // the window resizes. Re-pinning moves the container, so remember where rows are on screen.
        let onScreen = list.map { $0.frame.isEmpty ? nil : container.convert($0.frame, to: background) }
        let bounds = background.bounds
        var mask: NSView.AutoresizingMask = []
        let x: CGFloat, y: CGFloat
        switch anchor.horizontal {
        case .start: x = 0; mask.insert(.maxXMargin)
        case .center: x = (bounds.width - width) / 2; mask.formUnion([.minXMargin, .maxXMargin])
        case .end: x = bounds.width - width; mask.insert(.minXMargin)
        }
        switch anchor.vertical {                  // background isn't flipped: top = high y
        case .start: y = bounds.height - height; mask.insert(.minYMargin)
        case .center: y = (bounds.height - height) / 2; mask.formUnion([.minYMargin, .maxYMargin])
        case .end: y = 0; mask.insert(.maxYMargin)
        }
        container.autoresizingMask = mask
        container.frame = NSRect(x: x, y: y, width: width, height: height)

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

/// With a label: working text is blue with a white shimmer, waiting text pulses in yellow,
/// finished text is dimmed.
/// Without one (Icons Only): a spinner, "!" or check next to the logo.
/// A row flashes once when its turn finishes or it starts waiting on you.
private final class RowView: NSView {
    static let height: CGFloat = 24
    static let tallHeight: CGFloat = 38               // with the activity line
    static let minWidth: CGFloat = 6 + 16 + 5 + 13 + 6
    static let compactWidth: CGFloat = 6 + 16 + 6
    private static let maxLabelWidth: CGFloat = 150
    private static let activityColumn: CGFloat = 170
    private static let restingAlpha: CGFloat = 0.7   // finished text

    /// Yellow reads well on the dark material; on the light one it needs to be orange to be legible.
    static let attention = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemYellow : .systemOrange
    }

    /// Highlight for the green "finished while you were away" shimmer.
    private static let unseenHighlight = NSColor.white.withAlphaComponent(0.6)

    let key: String
    var onClick: ((String) -> Void)?
    var onFinish: (() -> Void)?
    var press = PressHandlers()
    var phase: Phase = .done {
        didSet {
            guard phase != oldValue else { return }
            let justFinished = oldValue == .working && phase == .done
            if justFinished { finishedAt = Date() }
            unseen = justFinished                         // re-renders
            if phase == .waiting || justFinished { flash() }
            if justFinished { onFinish?() }
        }
    }
    /// Collapsed list: just the logo.
    var compact = false { didSet { if compact != oldValue { render(); needsLayout = true } } }
    var activity: String? {
        didSet {
            guard activity != oldValue else { return }
            activityLabel.stringValue = activity ?? ""
            render()
        }
    }
    var beats: [Date] = [] { didSet { trace.beats = beats } }
    /// Finished while you weren't touching the Mac: shimmers green until you're back.
    var unseen = false { didSet { render() } }
    private(set) var finishedAt = Date.distantPast
    var label: String? {
        didSet {
            guard label != oldValue else { return }
            text.stringValue = label ?? ""
            highlight.stringValue = label ?? ""
            render()
            needsLayout = true
        }
    }
    var since: Date? { didSet { if since != oldValue { _ = updateTime(now: Date()) } } }
    var showsTime = true { didSet { if showsTime != oldValue { _ = updateTime(now: Date()) } } }

    private let logo: LogoView
    private let activityLabel = NSTextField(labelWithString: "")
    private let trace = TraceView(frame: NSRect(origin: .zero, size: TraceView.size))
    private let textHost = NSView()           // pulsed when waiting
    private let highlightHost = NSView()      // white copy of the label, masked to the moving band
    private let highlight = NSTextField(labelWithString: "")
    private let text = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let shimmer = CAGradientLayer()
    private let glow = CALayer()
    private let spinner = SpinnerView()
    private let badge = NSImageView()
    private var hovered = false { didSet { updateHighlight() } }

    private var timeVisible: Bool { !time.stringValue.isEmpty && label != nil && !compact }
    private var activityVisible: Bool {
        Effects.current.activityLine && !compact && label != nil && phase != .done && !(activity ?? "").isEmpty
    }
    private var traceVisible: Bool {
        Effects.current.activityTrace && !compact && label != nil && phase != .done
    }
    var preferredHeight: CGFloat { activityVisible ? Self.tallHeight : Self.height }
    private var timeWidth: CGFloat {
        let reserve = ("00m" as NSString).size(withAttributes: [.font: time.font!]).width
        let actual = (time.stringValue as NSString).size(withAttributes: [.font: time.font!]).width
        return ceil(max(reserve, actual)) + 2
    }

    var preferredWidth: CGFloat {
        if compact { return Self.compactWidth }
        guard label != nil else { return Self.minWidth }
        let measured = (text.stringValue as NSString).size(withAttributes: [.font: text.font!]).width
        let timePart = timeVisible ? 6 + timeWidth : 0
        let tracePart = traceVisible ? 6 + TraceView.size.width : 0
        var column = min(ceil(measured) + 4, Self.maxLabelWidth)
        // A fixed column while the activity line shows, so its changing text doesn't resize the list.
        if activityVisible { column = max(column, Self.activityColumn - tracePart - timePart) }
        return 28 + column + tracePart + timePart + 8
    }

    init(key: String, agent: Agent) {
        self.key = key
        logo = LogoView(agent: agent)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 7

        glow.cornerRadius = 7
        glow.opacity = 0
        layer?.addSublayer(glow)

        activityLabel.font = .systemFont(ofSize: 10.5)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.lineBreakMode = .byTruncatingTail
        text.font = .systemFont(ofSize: 12, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        textHost.wantsLayer = true
        textHost.addSubview(text)
        highlight.font = text.font
        highlight.lineBreakMode = .byTruncatingTail
        highlightHost.wantsLayer = true
        highlightHost.isHidden = true
        highlightHost.addSubview(highlight)
        textHost.addSubview(highlightHost)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        badge.imageScaling = .scaleProportionallyUpOrDown
        badge.wantsLayer = true

        // A bright band sweeping left to right over text at the resting opacity.
        // Mask for the white copy: transparent everywhere except a soft band.
        let clear = CGColor(gray: 0, alpha: 0), band = CGColor(gray: 0, alpha: 1)
        shimmer.colors = [clear, band, clear]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [0, 0.15, 0.3]

        for v in [logo, textHost, activityLabel, trace, time, spinner, badge] as [NSView] { addSubview(v) }
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        // With the activity line, the label sits on the upper line and the logo stays centred.
        let lineY = activityVisible ? 12.5 : midY
        logo.frame = NSRect(x: 6, y: midY - 8, width: 16, height: 16)
        let statusRect = NSRect(x: bounds.maxX - 6 - 13, y: midY - 6.5, width: 13, height: 13)
        spinner.frame = statusRect
        badge.frame = statusRect

        var textRight = bounds.maxX - 8
        if timeVisible {
            let h = ceil(time.intrinsicContentSize.height)
            time.frame = NSRect(x: textRight - timeWidth, y: lineY - h / 2, width: timeWidth, height: h)
            textRight = time.frame.minX - 6
        }
        if traceVisible {
            trace.frame = NSRect(x: textRight - TraceView.size.width, y: lineY - TraceView.size.height / 2,
                                 width: TraceView.size.width, height: TraceView.size.height)
            textRight = trace.frame.minX - 6
        }
        if activityVisible {
            let h = ceil(activityLabel.intrinsicContentSize.height)
            activityLabel.frame = NSRect(x: 28, y: 25.5 - h / 2, width: max(0, bounds.maxX - 8 - 28), height: h)
        }
        let textHeight = ceil(text.intrinsicContentSize.height)
        textHost.frame = NSRect(x: 28, y: lineY - textHeight / 2, width: max(0, textRight - 28), height: textHeight)
        text.frame = textHost.bounds
        highlightHost.frame = textHost.bounds
        highlight.frame = highlightHost.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.frame = highlightHost.bounds
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

    /// Re-applies colours after the theme changes.
    func applyTheme() {
        render()
        spinner.updateColor()
    }

    /// Re-applies the effect toggles (activity line, trace, animated logo).
    func applyEffects() {
        render()
        needsLayout = true
    }

    /// Redraws the trace so it scrolls with time.
    func tickTrace() {
        if traceVisible { trace.needsDisplay = true }
    }

    private func render() {
        let labelled = label != nil && !compact
        textHost.isHidden = !labelled
        spinner.isHidden = compact || labelled || phase != .working
        badge.isHidden = compact || labelled || phase == .working
        activityLabel.isHidden = !activityVisible
        trace.isHidden = !traceVisible
        trace.color = phase == .waiting ? Self.attention : ShimmerTheme.current.text.withAlphaComponent(1)
        logo.animating = Effects.current.animatedLogos && phase == .working
        logo.alphaValue = compact && phase == .done ? 0.7 : 1
        _ = updateTime(now: Date())

        if labelled {
            switch phase {
            case .unknown: text.textColor = .secondaryLabelColor
            case .working: text.textColor = ShimmerTheme.current.text
            case .waiting: text.textColor = Self.attention
            case .done: text.textColor = unseen ? .systemGreen : NSColor.labelColor.withAlphaComponent(Self.restingAlpha)
            }
            highlight.textColor = phase == .working ? ShimmerTheme.current.highlight : Self.unseenHighlight
            setShimmering(phase == .working || (phase == .done && unseen))   // green shimmer when unseen
            setPulsing(textHost, phase == .waiting)
            setPulsing(badge, false)
        } else {
            setShimmering(false)
            setPulsing(textHost, false)
            switch phase {
            case .unknown: badge.image = Self.symbol("questionmark.circle", .secondaryLabelColor)
            case .working: break
            case .waiting: badge.image = Self.symbol("exclamationmark.circle.fill", Self.attention)
            case .done: badge.image = Self.symbol("checkmark.circle.fill", .systemGreen)
            }
            setPulsing(badge, phase == .waiting)
        }
    }

    /// A white highlight sweeping over the (fully opaque) coloured text.
    private func setShimmering(_ on: Bool) {
        guard let host = highlightHost.layer else { return }
        highlightHost.isHidden = !on
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
    override func mouseDown(with event: NSEvent) { press.began() }
    override func mouseDragged(with event: NSEvent) { press.moved() }
    override func mouseUp(with event: NSEvent) {
        let wasDrag = press.ended()
        if !wasDrag, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(key) }
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

    func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = ShimmerTheme.current.text.withAlphaComponent(1).cgColor
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
