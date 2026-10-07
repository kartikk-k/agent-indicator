import AppKit
import QuartzCore

/// Optional visual effects, each toggled from the menu. Read by every row and the list.
struct Effects: Equatable {
    var animatedLogos = true      // Claude's spark spins, Codex's mark breathes while working
    var borderGlow = true         // a light travels around the list's edge
    var activityLine = true       // "Editing Overlay.swift" under the label
    var activityTrace = true      // tiny heartbeat of recent tool calls
    var collapseWhenIdle = true   // shrink to logos when nothing is happening

    static var current = Effects()
}

// MARK: - Logo that doubles as the loader

/// Claude: a white spark on a clay tile, spinning slowly while working.
/// Codex: the app icon, gently breathing while working.
final class LogoView: NSView {
    private let base = CALayer()
    private let spark = CALayer()
    private let agent: Agent

    var animating = false { didSet { if animating != oldValue { update() } } }

    init(agent: Agent) {
        self.agent = agent
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        switch agent {
        case .claude:
            base.backgroundColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor
            base.cornerRadius = 4
            spark.contents = Self.sparkImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            spark.contentsGravity = .resizeAspect
            spark.contentsScale = scale
            base.addSublayer(spark)
        case .codex:
            base.contents = AgentIcon.image(for: .codex).cgImage(forProposedRect: nil, context: nil, hints: nil)
            base.contentsGravity = .resizeAspect
            base.contentsScale = scale
        }
        layer?.addSublayer(base)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.bounds = CGRect(origin: .zero, size: bounds.size)
        base.position = CGPoint(x: bounds.midX, y: bounds.midY)
        spark.bounds = CGRect(x: 0, y: 0, width: bounds.width - 2, height: bounds.height - 2)
        spark.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        CATransaction.commit()
    }

    private func update() {
        let target = agent == .claude ? spark : base
        let key = "alive"
        guard animating else {
            // Ease back to rest from wherever the animation is, instead of snapping.
            let current = target.presentation()?.transform ?? CATransform3DIdentity
            target.removeAnimation(forKey: key)
            let settle = CABasicAnimation(keyPath: "transform")
            settle.fromValue = current
            settle.toValue = CATransform3DIdentity
            settle.duration = 0.35
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            target.add(settle, forKey: "settle")
            return
        }
        switch agent {
        case .claude:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 6
            spin.repeatCount = .infinity
            target.add(spin, forKey: key)
        case .codex:
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1
            breathe.toValue = 0.82
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            target.add(breathe, forKey: key)
        }
    }

    /// Claude's spark: twelve tapered rays of alternating length.
    private static let sparkImage = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.white.setFill()
        let c = NSPoint(x: rect.midX, y: rect.midY)
        // Bold enough to read at 16 px: wide-based rays with rounded tips.
        for i in 0..<12 {
            let a = CGFloat(i) * .pi / 6 + 0.12
            let len: CGFloat = i % 2 == 0 ? 29 : 22
            let ray = NSBezierPath()
            ray.move(to: NSPoint(x: c.x + cos(a + 0.3) * 8, y: c.y + sin(a + 0.3) * 8))
            ray.line(to: NSPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
            ray.line(to: NSPoint(x: c.x + cos(a - 0.3) * 8, y: c.y + sin(a - 0.3) * 8))
            ray.close()
            ray.lineWidth = 4
            ray.lineJoinStyle = .round
            NSColor.white.setStroke()
            ray.stroke()
            ray.fill()
        }
        NSBezierPath(ovalIn: NSRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)).fill()
        return true
    }
}

// MARK: - Activity trace

/// A tiny heartbeat line: each tool call is a blip, scrolling left over the last 90 seconds.
/// Busy agents draw a dense trace; a flat line means nothing has happened for a while.
final class TraceView: NSView {
    static let size = NSSize(width: 30, height: 12)
    var beats: [Date] = [] { didSet { if beats != oldValue { needsDisplay = true } } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let buckets = 15
        let span = Activity.traceWindow / Double(buckets)
        let now = Date()
        var counts = [CGFloat](repeating: 0, count: buckets)
        for b in beats {
            let age = now.timeIntervalSince(b)
            guard age >= 0, age < Activity.traceWindow else { continue }
            counts[buckets - 1 - Int(age / span)] += 1
        }
        let baseline = bounds.maxY - 1.5
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        let step = bounds.width / CGFloat(buckets - 1)
        for (i, n) in counts.enumerated() {
            let h = min(n, 4) / 4 * (bounds.height - 3)
            let p = NSPoint(x: CGFloat(i) * step, y: baseline - h)
            i == 0 ? path.move(to: p) : path.line(to: p)
        }
        color.setStroke()
        path.stroke()
    }

    override var isFlipped: Bool { true }
}

// MARK: - Light travelling around the edge

/// Draws on top of the list, following its rounded outline:
/// - working: a faint ring with a bright comet circling it
/// - waiting: the whole ring pulses in the attention colour
/// - a chat finishes: one green lap, then back to whatever's current
final class BeamView: NSView {
    enum Mode: Equatable { case off, working(NSColor), waiting(NSColor) }

    /// Horizontal lists are capsules; vertical ones use a fixed corner radius.
    var capsule = false { didSet { needsLayout = true } }
    private(set) var mode: Mode = .off

    private let ring = CAShapeLayer()
    private let tail = CAShapeLayer()
    private let head = CAShapeLayer()
    private var celebrating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [ring, tail, head] {
            l.fillColor = nil
            l.lineCap = .round
            l.opacity = 0
            layer?.addSublayer(l)
        }
        ring.lineWidth = 1
        tail.lineWidth = 1.5
        head.lineWidth = 2
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // purely decorative

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePaths()
    }

    override func layout() {
        super.layout()
        updatePaths()
    }

    /// The comet runs along the outline drawn twice, so it can loop by animating 0 → 0.5
    /// in normalised units. That keeps its speed even and survives the window resizing mid-lap.
    private func updatePaths() {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        guard rect.width > 4, rect.height > 4 else { return }
        let r = min(capsule ? rect.height / 2 : 10.25, rect.height / 2, rect.width / 2)
        let outline = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        let twice = CGMutablePath()
        twice.addPath(outline)
        twice.addPath(outline)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [ring, tail, head] { l.frame = bounds }
        ring.path = outline
        tail.path = twice
        head.path = twice
        CATransaction.commit()
    }

    func set(_ new: Mode) {
        guard new != mode else { return }
        mode = new
        if !celebrating { apply() }
    }

    /// One green lap when a chat finishes.
    func celebrate() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        celebrating = true
        reset()
        let green = NSColor.systemGreen.cgColor
        tail.strokeColor = NSColor.systemGreen.withAlphaComponent(0.45).cgColor
        head.strokeColor = green
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.celebrating = false
            self?.apply()
        }
        runComet(duration: 1.3, repeats: false)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.75, 1]
        fade.duration = 1.3
        tail.add(fade, forKey: "fade")
        head.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private func reset() {
        for l in [ring, tail, head] {
            l.removeAllAnimations()
            l.opacity = 0
        }
    }

    private func apply() {
        reset()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch mode {
            case .off:
                break
            case .working(let color):
                ring.strokeColor = color.withAlphaComponent(0.18).cgColor
                tail.strokeColor = color.withAlphaComponent(0.4).cgColor
                head.strokeColor = color.cgColor
                ring.opacity = 1; tail.opacity = 1; head.opacity = 1
                runComet(duration: 3.2, repeats: true)
            case .waiting(let color):
                ring.strokeColor = color.cgColor
                ring.lineWidth = 1.5
                ring.opacity = 1
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.2
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ring.add(pulse, forKey: "pulse")
            }
        }
        if case .waiting = mode {} else { ring.lineWidth = 1 }
    }

    /// Tail is 11% of the outline, head the last 2% of it; both move one lap per `duration`.
    private func runComet(duration: CFTimeInterval, repeats: Bool) {
        func lap(_ layer: CAShapeLayer, start: CGFloat, length: CGFloat) {
            let s = CABasicAnimation(keyPath: "strokeStart")
            s.fromValue = start; s.toValue = start + 0.5
            let e = CABasicAnimation(keyPath: "strokeEnd")
            e.fromValue = start + length; e.toValue = start + length + 0.5
            let group = CAAnimationGroup()
            group.animations = [s, e]
            group.duration = duration
            group.repeatCount = repeats ? .infinity : 1
            group.isRemovedOnCompletion = !repeats
            layer.add(group, forKey: "comet")
            layer.strokeStart = start; layer.strokeEnd = start + length
        }
        lap(tail, start: 0, length: 0.055)
        lap(head, start: 0.045, length: 0.01)
        if !repeats { tail.opacity = 1; head.opacity = 1 }
    }
}
