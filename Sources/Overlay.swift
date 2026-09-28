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

    var corner: Corner = .topRight { didSet { relayout() } }
    var layout: Layout = .vertical { didSet { relayout() } }
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
        container.autoresizingMask = [.width, .height]
        background.addSubview(container)
        panel.contentView = background

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.relayout() }
    }

    func show(_ sessions: [Session], labels: [String: String]) {
        let keys = Set(sessions.map(\.key))
        for (key, row) in rows where !keys.contains(key) {
            row.removeFromSuperview()
            rows[key] = nil
        }
        for s in sessions {
            let row = rows[s.key] ?? {
                let r = RowView(key: s.key, agent: s.agent)
                r.onClick = { [weak self] key in self?.onClick?(key) }
                container.addSubview(r)
                rows[s.key] = r
                return r
            }()
            row.phase = s.phase
            row.label = labels[s.key]
        }
        order = sessions.map(\.key)

        if sessions.isEmpty {
            panel.orderOut(nil)
        } else {
            relayout()
            panel.orderFrontRegardless()
        }
    }

    private func relayout() {
        guard let screen = NSScreen.screens.first else { return }   // the menu-bar screen
        let list = order.compactMap { rows[$0] }
        let rowHeight = RowView.height
        var width: CGFloat, height: CGFloat

        switch layout {
        case .vertical:
            let rowWidth = list.map(\.preferredWidth).max() ?? RowView.minWidth
            for (i, row) in list.enumerated() {
                row.frame = NSRect(x: inset, y: inset + CGFloat(i) * rowHeight, width: rowWidth, height: rowHeight)
            }
            width = rowWidth + inset * 2
            height = CGFloat(max(1, list.count)) * rowHeight + inset * 2
        case .horizontal:
            var x = inset
            for row in list {
                row.frame = NSRect(x: x, y: inset, width: row.preferredWidth, height: rowHeight)
                x += row.preferredWidth
            }
            width = max(x, RowView.minWidth + inset) + inset
            height = rowHeight + inset * 2
        }

        let area = screen.visibleFrame
        let x = (corner == .topLeft || corner == .bottomLeft) ? area.minX + margin : area.maxX - margin - width
        let y = (corner == .topLeft || corner == .topRight) ? area.maxY - margin - height : area.minY + margin
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        container.frame = background.bounds
        let radius = layout == .horizontal ? height / 2 : 11
        background.maskImage = .roundedRect(width: width, height: height, radius: radius)
        panel.invalidateShadow()
    }
}

// MARK: - One session: logo + label (or a status icon when labels are off)

/// With a label: working text shimmers, waiting text turns orange, finished text is dimmed.
/// Without one (Icons Only): a spinner, orange "!" or green check next to the logo.
private final class RowView: NSView {
    static let height: CGFloat = 24
    static let minWidth: CGFloat = 6 + 16 + 5 + 13 + 6
    private static let maxLabelWidth: CGFloat = 150

    let key: String
    var onClick: ((String) -> Void)?
    var phase: Phase = .done { didSet { if phase != oldValue { render() } } }
    var label: String? {
        didSet {
            guard label != oldValue else { return }
            text.stringValue = label ?? ""
            render()
            needsLayout = true
        }
    }

    private let logo = NSImageView()
    private let textHost = NSView()           // masked by the shimmer gradient
    private let text = NSTextField(labelWithString: "")
    private let shimmer = CAGradientLayer()
    private let spinner = SpinnerView()
    private let badge = NSImageView()
    private var hovered = false { didSet { updateHighlight() } }

    var preferredWidth: CGFloat {
        guard label != nil else { return Self.minWidth }
        let measured = (text.stringValue as NSString).size(withAttributes: [.font: text.font!]).width
        return 28 + min(ceil(measured) + 4, Self.maxLabelWidth) + 8
    }

    init(key: String, agent: Agent) {
        self.key = key
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 7

        logo.image = AgentIcon.image(for: agent)
        logo.imageScaling = .scaleProportionallyUpOrDown
        text.font = .systemFont(ofSize: 12, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        textHost.wantsLayer = true
        textHost.addSubview(text)
        badge.imageScaling = .scaleProportionallyUpOrDown

        // A bright band sweeping left to right over dimmed text.
        let dim = CGColor(gray: 0, alpha: 0.4), full = CGColor(gray: 0, alpha: 1)
        shimmer.colors = [dim, full, dim]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [0, 0.15, 0.3]

        for v in [logo, textHost, spinner, badge] as [NSView] { addSubview(v) }
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
        let textHeight = ceil(text.intrinsicContentSize.height)
        textHost.frame = NSRect(x: 28, y: midY - textHeight / 2, width: max(0, bounds.maxX - 8 - 28), height: textHeight)
        text.frame = textHost.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.frame = textHost.bounds
        CATransaction.commit()
    }

    private func render() {
        let labelled = label != nil
        textHost.isHidden = !labelled
        spinner.isHidden = labelled || phase != .working
        badge.isHidden = labelled || phase == .working

        if labelled {
            switch phase {
            case .working: text.textColor = .labelColor
            case .waiting: text.textColor = .systemOrange
            case .done: text.textColor = NSColor.labelColor.withAlphaComponent(0.6)
            }
            setShimmering(phase == .working)
        } else {
            setShimmering(false)
            switch phase {
            case .working: break
            case .waiting: badge.image = Self.symbol("exclamationmark.circle.fill", .systemOrange)
            case .done: badge.image = Self.symbol("checkmark.circle.fill", .systemGreen)
            }
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
