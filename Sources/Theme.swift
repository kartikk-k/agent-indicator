import AppKit

/// Colour of in-progress text and the highlight that sweeps across it.
/// Only the working state changes with the theme; waiting, finished and unseen keep their colours.
enum ShimmerTheme: String, CaseIterable {
    case silver, ocean, sky, lavender, rose, mint, claude

    /// The theme currently applied to every row.
    static var current: ShimmerTheme = .silver

    var title: String {
        switch self {
        case .silver: return "Silver"
        case .ocean: return "Ocean"
        case .sky: return "Sky"
        case .lavender: return "Lavender"
        case .rose: return "Rose"
        case .mint: return "Mint"
        case .claude: return "Clay"
        }
    }

    /// Working text. Each theme has a lighter tone for the dark material and a deeper one for the light.
    var text: NSColor {
        switch self {
        case .silver: return Self.adaptive(dark: .white.withAlphaComponent(0.55), light: .black.withAlphaComponent(0.5))
        case .ocean: return Self.adaptive(dark: Self.hex(0x0088F5), light: Self.hex(0x0071D6))
        case .sky: return Self.adaptive(dark: Self.hex(0x6CCBFF), light: Self.hex(0x0A84C9))
        case .lavender: return Self.adaptive(dark: Self.hex(0xB9A2FF), light: Self.hex(0x7353E0))
        case .rose: return Self.adaptive(dark: Self.hex(0xFF8FB3), light: Self.hex(0xD63F74))
        case .mint: return Self.adaptive(dark: Self.hex(0x63E6C8), light: Self.hex(0x0E9F83))
        case .claude: return Self.adaptive(dark: Self.hex(0xE8906F), light: Self.hex(0xC15F3C))
        }
    }

    /// The sweeping band. Silver brightens to full white (or deepens to black on light);
    /// coloured themes get a soft white glint.
    var highlight: NSColor {
        switch self {
        case .silver: return Self.adaptive(dark: .white, light: .black.withAlphaComponent(0.9))
        case .claude: return Self.adaptive(dark: Self.hex(0xFFE2D4, alpha: 0.85), light: .white.withAlphaComponent(0.6))
        default: return .white.withAlphaComponent(0.6)
        }
    }

    /// A small dot for the menu, in the theme's working colour.
    var swatch: NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            self.text.withAlphaComponent(1).setFill()
            dot.fill()
            NSColor.separatorColor.setStroke()   // keeps Silver visible on a light menu
            dot.lineWidth = 0.5
            dot.stroke()
            return true
        }
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                 blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}
