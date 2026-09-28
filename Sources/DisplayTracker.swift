import AppKit

/// Tracks the display you're working on: the one the pointer moves onto, or the one holding the
/// front window of the app you just switched to. Whichever happened most recently wins.
/// Needs no permissions (window bounds come from CGWindowList, which doesn't include titles).
final class DisplayTracker {
    var onChange: ((NSScreen) -> Void)?
    private(set) var screen: NSScreen?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    func start() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) {
            [weak self] _ in self?.pointerMoved()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Give the app a moment to bring its window forward before we look.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.update(Self.screenOfFrontWindow(pid: app.processIdentifier))
            }
        }
        pointerMoved()
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        mouseMonitor = nil
        activationObserver = nil
        screen = nil
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if let screen, NSMouseInRect(point, screen.frame, false) { return }   // cheap common case
        update(NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) })
    }

    private func update(_ new: NSScreen?) {
        guard let new, new.number != screen?.number else { return }
        screen = new
        onChange?(new)
    }

    private static func screenOfFrontWindow(pid: pid_t) -> NSScreen? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }

        // Front-to-back order: the first normal-level window of the app is its front window.
        for w in windows where (w[kCGWindowOwnerPID as String] as? pid_t) == pid
                              && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict), cg.width > 50, cg.height > 50 else { continue }
            // CoreGraphics measures from the top-left of the primary display; AppKit from the bottom-left.
            let rect = NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            return NSScreen.screens.max { a, b in
                a.frame.intersection(rect).area < b.frame.intersection(rect).area
            }
        }
        return nil
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

extension NSScreen {
    var number: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
