import AppKit
import Darwin

/// Brings a session to the front: the exact tab in Terminal / iTerm2, the thread in the
/// Codex app, or otherwise the app that hosts the session's process.
enum Focuser {
    static func focus(_ session: Session) {
        let info = session.info
        guard let pid = info.pid, let host = hostApp(of: pid) else {
            if let link = info.deepLink { NSWorkspace.shared.open(link) }
            return
        }

        // Desktop apps with a deep link go straight to the thread.
        if let link = info.deepLink, host.bundleIdentifier == "com.openai.codex" {
            NSWorkspace.shared.open(link)
            return
        }

        if let tty = ttyPath(of: pid) {
            switch host.bundleIdentifier {
            case "com.apple.Terminal":
                if runScript(terminalScript(tty: tty)) { return }
            case "com.googlecode.iterm2":
                if runScript(itermScript(tty: tty)) { return }
            default:
                break
            }
        }
        activate(host)
    }

    // MARK: - Process tree

    /// The first GUI app among the process's ancestors (Terminal, iTerm2, VS Code, Codex app, …).
    private static func hostApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular, app.bundleIdentifier != nil {
                return app
            }
            guard let parent = kinfo(current)?.kp_eproc.e_ppid, parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// sysctl rather than libproc: it also works for root-owned ancestors such as `login`.
    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// "/dev/ttys004" for a process attached to a terminal.
    private static func ttyPath(of pid: pid_t) -> String? {
        guard let dev = kinfo(pid)?.kp_eproc.e_tdev, dev != -1, dev != 0,
              let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    // MARK: - Activation

    private static func activate(_ app: NSRunningApplication) {
        // Going through LaunchServices works even though we're a background app; a plain
        // NSRunningApplication.activate() is often ignored on macOS 14+.
        guard let url = app.bundleURL else { app.activate(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// Runs AppleScript; the script returns "ok" when it found the tab.
    private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Agent Indicator: AppleScript failed: \(error)") }
        return result?.stringValue == "ok"
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        try
                            set miniaturized of w to false
                        end try
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }
}
