import Foundation

/// Reads the live session registry Claude Code maintains at ~/.claude/sessions/<pid>.json.
/// Each running session rewrites its file whenever its status changes
/// ("busy" | "shell" | "waiting" | "idle"), and deletes it on exit.
final class ClaudeSource {
    let directory: URL
    private let projects: URL
    private var titles: [String: CachedTitle] = [:]

    private struct CachedTitle {
        var title: String?
        var mtime: Date
        var checkedAt: Date
    }

    init() {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        directory = base.appendingPathComponent("sessions")
        projects = base.appendingPathComponent("projects")
    }

    func sessions() -> [RawSession] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [RawSession] = []

        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(5)), processAlive(pid),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let kind = obj["kind"] as? String ?? "interactive"
            if kind.hasPrefix("daemon") { continue }

            let state: RawState
            switch obj["status"] as? String {
            case "busy", "shell": state = .working
            case "waiting": state = .waiting
            default: state = .idle
            }

            var finishedAt: Date?
            if state == .idle,
               let changed = obj["statusUpdatedAt"] as? Double,
               let started = obj["startedAt"] as? Double,
               changed - started > 5_000 {      // idle written at startup isn't a finished turn
                finishedAt = Date(timeIntervalSince1970: changed / 1000)
            }

            let cwd = obj["cwd"] as? String ?? ""
            var title: String?
            if obj["nameSource"] as? String == "user", let n = obj["name"] as? String, !n.isEmpty {
                title = n                                        // set with /rename
            } else if let sid = obj["sessionId"] as? String {
                title = aiTitle(sessionID: sid, cwd: cwd)
            }

            let info = SessionInfo(project: URL(fileURLWithPath: cwd).lastPathComponent,
                                   title: title, pid: pid, deepLink: nil)
            out.append(RawSession(key: "claude:\(pid)", agent: .claude, info: info,
                                  state: state, finishedAt: finishedAt))
        }
        return out
    }

    private func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The short title Claude Code generates for a chat, stored as "ai-title" entries in its transcript.
    private func aiTitle(sessionID: String, cwd: String) -> String? {
        let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let path = projects.appendingPathComponent(folder).appendingPathComponent("\(sessionID).jsonl").path
        let now = Date()
        if let c = titles[sessionID], now.timeIntervalSince(c.checkedAt) < 5 { return c.title }

        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return titles[sessionID]?.title }
        if let c = titles[sessionID], c.mtime == mtime {
            titles[sessionID]?.checkedAt = now
            return c.title
        }

        let title = lastTitle(inTailOf: path) ?? titles[sessionID]?.title
        titles[sessionID] = CachedTitle(title: title, mtime: mtime, checkedAt: now)
        return title
    }

    private func lastTitle(inTailOf path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 1_000_000 ? size - 1_000_000 : 0)
        guard let data = try? h.readToEnd() else { return nil }
        let marker = Data(#""type":"ai-title""#.utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let t = obj["aiTitle"] as? String, !t.isEmpty {
                return t
            }
        }
        return nil
    }
}
