import Foundation
import Darwin

/// Reads the live session registry Claude Code maintains at ~/.claude/sessions/<pid>.json.
/// Each running session rewrites its file whenever its status changes
/// ("busy" | "shell" | "waiting" | "idle"), and deletes it on exit.
final class ClaudeSource {
    let directory: URL
    private let projects: URL
    private var transcripts: [String: Transcript] = [:]

    /// What we've learned from a session's transcript, re-read whenever the file grows.
    private struct Transcript {
        var size: UInt64 = 0
        var modifiedAt: Date?
        var fileIdentity: UInt64?
        var title: String?
        var activity: String?
        var beats: [Date] = []
        var lastActivityAt: Date?
        var turnStartedAt: Date?
        var turnID: String?
    }

    /// Transcripts live here; the app watches it so activity updates as it's written.
    var projectsDirectory: URL { projects }

    init() {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        directory = base.appendingPathComponent("sessions")
        projects = base.appendingPathComponent("projects")
    }

    func reload() { transcripts.removeAll() }

    /// `shell` is emitted when the model is idle but a background bash task remains.
    /// A dev server is not an unfinished agent turn.
    static func registryState(_ status: String?) -> RawState {
        switch status {
        case "busy": return .working
        case "waiting": return .waiting
        case "idle", "shell": return .idle
        default: return .unknown
        }
    }

    func sessions() -> [RawSession] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [RawSession] = []

        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(5)),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  processMatches(pid, registry: obj)
            else { continue }

            let kind = obj["kind"] as? String ?? "interactive"
            if kind.hasPrefix("daemon") { continue }

            var state = Self.registryState(obj["status"] as? String)

            var finishedAt: Date?
            if state == .idle,
               let changed = obj["statusUpdatedAt"] as? Double,
               let started = obj["startedAt"] as? Double,
               changed - started > 5_000 {      // idle written at startup isn't a finished turn
                finishedAt = Date(timeIntervalSince1970: changed / 1000)
            }

            let cwd = obj["cwd"] as? String ?? ""
            let transcript = (obj["sessionId"] as? String).map { readTranscript(sessionID: $0, cwd: cwd) }
            let statusAt = (obj["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            state = SessionEvidence.state(state, lastActivity: [statusAt, transcript?.lastActivityAt].compactMap { $0 }.max())
            var title = transcript?.title
            if obj["nameSource"] as? String == "user", let n = obj["name"] as? String, !n.isEmpty {
                title = n                                        // set with /rename
            }
            var activity = transcript?.activity
            if state == .waiting { activity = (obj["waitingFor"] as? String).map { "Needs \($0)" } ?? "Needs your input" }
            if state == .unknown { activity = "No recent activity · status unconfirmed" }

            // statusUpdatedAt is when it last became busy; a close enough turn start for a fresh launch.
            let turnStartedAt = state == .idle ? nil : transcript?.turnStartedAt ?? statusAt

            let info = SessionInfo(project: URL(fileURLWithPath: cwd).lastPathComponent,
                                   title: title, pid: pid, deepLink: nil)
            let identity = obj["sessionId"] as? String ?? String(describing: obj["startedAt"] ?? "")
            out.append(RawSession(key: "claude:\(pid):\(identity)", agent: .claude, info: info,
                                  state: state, finishedAt: finishedAt, turnStartedAt: turnStartedAt,
                                  activity: activity, beats: transcript?.beats ?? [], turnID: transcript?.turnID))
        }
        return out
    }

    private func processMatches(_ pid: Int32, registry: [String: Any]) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        // A stale registry file must not attach to an unrelated process that reused its PID.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        if let recorded = registry["procStart"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            if let start = formatter.date(from: recorded) {
                return abs(start.timeIntervalSince1970 - Double(info.pbi_start_tvsec)) < 1
            }
        }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &name, UInt32(name.count)) > 0 && String(cString: name).lowercased().contains("claude")
    }

    /// Title ("ai-title" entries), current activity and recent tool-call times from the
    /// session's transcript. Only the tail is read, and only when the file has grown.
    private func readTranscript(sessionID: String, cwd: String) -> Transcript {
        let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let path = projects.appendingPathComponent(folder).appendingPathComponent("\(sessionID).jsonl").path
        var t = transcripts[sessionID] ?? Transcript()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return t }
        let modifiedAt = attrs[.modificationDate] as? Date
        let identity = attrs[.systemFileNumber] as? UInt64
        guard size != t.size || modifiedAt != t.modifiedAt || identity != t.fileIdentity,
              let h = FileHandle(forReadingAtPath: path) else { return t }
        if size < t.size || identity != t.fileIdentity { t = Transcript() }
        defer { try? h.close() }

        let window: UInt64 = t.size == 0 ? 1_500_000 : 400_000   // first read looks further back for a title
        try? h.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? h.readToEnd() else { return t }
        t.size = size
        t.modifiedAt = modifiedAt
        t.fileIdentity = identity

        let titleMarker = Data(#""type":"ai-title""#.utf8)
        let assistant = Data(#""type":"assistant""#.utf8)
        let user = Data(#""type":"user""#.utf8)
        let horizon = Date().addingTimeInterval(-Activity.traceWindow)
        var foundTitle = false, foundActivity = false, foundPrompt = false, beats: [Date] = []

        for line in data.split(separator: 0x0A).reversed() {
            let isTitle = !foundTitle && line.range(of: titleMarker) != nil
            let isAssistant = line.range(of: assistant) != nil
            let isUser = line.range(of: user) != nil
            guard isTitle || isAssistant || isUser, line.count < 1_000_000,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }

            if isTitle, let title = obj["aiTitle"] as? String, !title.isEmpty {
                t.title = title; foundTitle = true
                continue
            }
            let date = EventDate.parse(obj["timestamp"] as? String)
            if let date { t.lastActivityAt = max(t.lastActivityAt ?? .distantPast, date) }
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let tools = content.filter { $0["type"] as? String == "tool_use" }
            if obj["type"] as? String == "user", !foundPrompt, obj["isMeta"] as? Bool != true,
               !content.contains(where: { $0["type"] as? String == "tool_result" }), let date {
                foundPrompt = true
                t.turnStartedAt = date
                t.turnID = obj["uuid"] as? String ?? String(date.timeIntervalSince1970)
            }

            if obj["type"] as? String == "assistant" {
                if let date, date > horizon { beats.append(contentsOf: Array(repeating: date, count: tools.count)) }
                if !foundActivity {
                    foundActivity = true
                    if let last = tools.last, let name = last["name"] as? String {
                        t.activity = Activity.claudeTool(name, last["input"] as? [String: Any] ?? [:])
                    } else {
                        t.activity = content.last?["type"] as? String == "thinking" ? "Thinking" : "Writing a reply"
                    }
                }
            } else if obj["type"] as? String == "user", !foundActivity {
                foundActivity = true
                t.activity = "Thinking"      // a new prompt or tool results: the model's up next
            }
            if foundActivity && foundTitle && foundPrompt, let date, date < horizon { break }
        }
        t.beats = beats.sorted()
        transcripts[sessionID] = t
        return t
    }
}
