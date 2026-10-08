import Foundation
import Darwin

/// Follows Codex rollout logs (~/.codex/sessions/**/rollout-*.jsonl). A session counts as
/// open while a Codex process (CLI or desktop app) holds its rollout file open; its state
/// comes from the last turn event appended to the file.
final class CodexSource {
    let directory: URL
    private let realRoot: String
    private var files: [String: RolloutFile] = [:]
    private let indexPath: String
    private var threadNames: [String: String] = [:]
    private var indexMTime: Date?

    init() {
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        directory = base.appendingPathComponent("sessions")
        realRoot = realPath(directory.path) + "/"
        indexPath = base.appendingPathComponent("session_index.jsonl").path
    }

    func reload() {
        files.removeAll()
        threadNames.removeAll()
        indexMTime = nil
    }

    /// Re-read the files FSEvents reported as changed. Returns false if one of them is a
    /// rollout we aren't tracking yet (a new session), so the caller should run discovery.
    func filesChanged(_ paths: [String]) -> Bool {
        var allKnown = true
        for p in paths {
            if let f = files[p] { f.readNew() } else { allKnown = false }
        }
        return allKnown
    }

    /// With `discover`, finds which rollouts are open (libproc) and drops closed ones.
    func sessions(discover: Bool) -> [RawSession] {
        if discover {
            let open = openRolloutPaths()
            for (path, pid) in open {
                let f = files[path] ?? RolloutFile(path: path)
                f.pid = pid
                files[path] = f
            }
            for path in Array(files.keys) where open[path] == nil {
                files[path] = nil
            }
            for f in files.values { f.readNew() }
            loadThreadNames()
        }

        return Self.merge(Array(files.values), threadNames: threadNames)
    }

    /// Continuations describe successive versions of one conversation, not competing
    /// statuses. The newest main-thread lifecycle event wins, including completion.
    static func merge(_ files: [RolloutFile], threadNames: [String: String] = [:], now: Date = Date()) -> [RawSession] {
        let chats = Dictionary(grouping: files) { $0.sessionID ?? $0.path }
        return chats.map { id, parts in
            let mains = parts.filter { !$0.isSubagent }
            let candidates = mains.isEmpty ? parts : mains
            let main = candidates.max {
                let a = $0.stateChangedAt ?? .distantPast, b = $1.stateChangedAt ?? .distantPast
                return a == b ? $0.path < $1.path : a < b
            }!
            // Only activity belonging to the selected turn can keep it alive.
            let currentParts = parts.filter {
                $0 === main || (main.turnID != nil && $0.turnID == main.turnID)
            }
            let evidence = currentParts.compactMap(\.lastEvidenceAt).max()
            let state = SessionEvidence.state(main.state, lastActivity: evidence, now: now)
            let latest = currentParts.max { ($0.activityAt ?? .distantPast) < ($1.activityAt ?? .distantPast) }
            let horizon = now.addingTimeInterval(-Activity.traceWindow)
            let beats = currentParts.flatMap(\.beats).filter { $0 > horizon }.sorted()
            let activity = state == .unknown ? "No recent activity · status unconfirmed"
                : state == .waiting ? (main.hasPendingQuestions ? "Needs your input · Shift+←" : "Needs your input") : latest?.activity
            let info = SessionInfo(project: main.title, title: threadNames[id], pid: main.pid,
                                   deepLink: URL(string: "codex://threads/\(id)"))
            return RawSession(key: "codex:\(id)", agent: .codex, info: info, state: state,
                              finishedAt: main.finishedAt, interrupted: main.interrupted,
                              turnStartedAt: main.turnStartedAt, activity: activity, beats: beats, turnID: main.turnID)
        }
    }

    /// Chat titles Codex generates, appended to session_index.jsonl (last entry per id wins).
    private func loadThreadNames() {
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: indexPath))?[.modificationDate] as? Date,
              mtime != indexMTime, let data = FileManager.default.contents(atPath: indexPath) else { return }
        indexMTime = mtime
        for line in data.split(separator: 0x0A) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let id = obj["id"] as? String, let name = obj["thread_name"] as? String, !name.isEmpty {
                threadNames[id] = name
            }
        }
    }

    // MARK: - Open file discovery via libproc

    /// Rollout files currently held open, mapped to the process holding them.
    private func openRolloutPaths() -> [String: pid_t] {
        var result: [String: pid_t] = [:]
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return result }

        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            guard proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0,
                  String(cString: nameBuf).lowercased().contains("codex") else { continue }

            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
            guard got > 0 else { continue }

            for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                if path.hasPrefix(realRoot), path.hasSuffix(".jsonl") { result[path] = pid }
            }
        }
        return result
    }
}

/// realpath(3). Unlike URL.resolvingSymlinksInPath it keeps "/private", matching kernel vnode paths.
func realPath(_ path: String) -> String {
    guard let p = realpath(path, nil) else { return path }
    defer { free(p) }
    return String(cString: p)
}

/// Incrementally tails one rollout file.
final class RolloutFile {
    let path: String
    private(set) var title = "Codex"
    private(set) var sessionID: String?
    private(set) var isSubagent = false
    var pid: pid_t?
    private var reportedState: RawState = .idle
    /// Async questions remain actionable while the agent continues working or finishes.
    private var pendingQuestions: [String: Set<Int>] = [:]
    var hasPendingQuestions: Bool { !pendingQuestions.isEmpty }
    private(set) var state: RawState {
        get { pendingQuestions.isEmpty ? reportedState : .waiting }
        set { reportedState = newValue }
    }
    private(set) var finishedAt: Date?
    private(set) var turnStartedAt: Date?
    private(set) var activity: String?
    private(set) var activityAt: Date?
    private(set) var beats: [Date] = []
    private(set) var interrupted = false
    private(set) var stateChangedAt: Date?
    private(set) var lastEvidenceAt: Date?
    private(set) var turnID: String?
    private var fileIdentity: UInt64?
    private var fileModifiedAt: Date?
    private var offset: UInt64 = 0
    private var partial = Data()

    private static let marker = Data("event_msg".utf8)
    init(path: String) {
        self.path = path
        load()
    }

    private func load() {
        title = "Codex"; sessionID = nil; isSubagent = false
        pendingQuestions.removeAll()
        state = .idle; finishedAt = nil; turnStartedAt = nil; turnID = nil
        stateChangedAt = nil; lastEvidenceAt = nil; activity = nil; activityAt = nil
        beats.removeAll(); interrupted = false; offset = 0; partial.removeAll()
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        fileIdentity = attrs?[.systemFileNumber] as? UInt64
        fileModifiedAt = attrs?[.modificationDate] as? Date
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }

        // Parse actual JSON so whitespace, escaping and nested metadata cannot change identity.
        if let head = try? h.read(upToCount: 64 * 1024),
           let line = head.split(separator: 0x0A).first,
           let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
           obj["type"] as? String == "session_meta", let meta = obj["payload"] as? [String: Any] {
            sessionID = meta["session_id"] as? String ?? meta["id"] as? String
            isSubagent = meta["thread_source"] as? String == "subagent"
                || (meta["source"] as? [String: Any])?["subagent"] != nil
            if let cwd = meta["cwd"] as? String { title = URL(fileURLWithPath: cwd).lastPathComponent }
        }

        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 4_000_000 ? size - 4_000_000 : 0
        try? h.seek(toOffset: start)
        var tail = (try? h.readToEnd()) ?? Data()
        offset = start + UInt64(tail.count)
        if start > 0 {
            if let nl = tail.firstIndex(of: 0x0A) { tail = Data(tail[(nl + 1)...]) }
            else { tail.removeAll() }
        }
        consume(tail)
        // A truncated history or a log mtime alone cannot prove that a task is running.
        if stateChangedAt == nil, start > 0 || lastEvidenceAt != nil { state = .unknown }
    }

    func readNew() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let identity = attrs?[.systemFileNumber] as? UInt64
        let size = attrs?[.size] as? UInt64 ?? 0
        let modifiedAt = attrs?[.modificationDate] as? Date
        if identity != fileIdentity || size < offset || (size == offset && modifiedAt != fileModifiedAt) { load(); return }
        fileModifiedAt = modifiedAt
        guard size > offset, let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        guard let chunk = try? h.readToEnd() else { return }
        offset += UInt64(chunk.count)
        consume(chunk)
    }

    private func consume(_ chunk: Data) {
        partial.append(chunk)
        guard let lastNL = partial.lastIndex(of: 0x0A) else { return }
        let complete = partial[partial.startIndex..<lastNL]
        partial = Data(partial[(lastNL + 1)...])
        for line in complete.split(separator: 0x0A) { apply(Data(line)) }
    }

    /// Returns true if the line was a turn-level event that set the state.
    private static let activityMarkers = ["\"function_call\"", "\"custom_tool_call\"", "\"local_shell_call\"",
                                          "\"reasoning\"", "\"message\"", "\"web_search_call\""].map { Data($0.utf8) }

    /// Tool calls, reasoning and replies → the "doing now" line and the activity trace.
    private func noteActivity(_ line: Data) {
        // The payload type sits near the start of the line; check it before parsing big lines.
        let head = line.prefix(400)
        guard head.range(of: Data("response_item".utf8)) != nil,
              Self.activityMarkers.contains(where: { head.range(of: $0) != nil }),
              line.count < 4_000_000,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any], let type = payload["type"] as? String else { return }
        guard let date = EventDate.parse(obj["timestamp"] as? String) else { return }

        switch type {
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = payload["name"] as? String ?? "shell"
            let input = payload["input"] as? String ?? payload["arguments"] as? String
                ?? (payload["action"].map { "\($0)" } ?? "")
            activity = Activity.codexCall(name: name, input: String(input.prefix(4000)))
            beats.append(date)
        case "web_search_call":
            activity = "Searching the web"
            beats.append(date)
        case "reasoning":
            activity = "Thinking"
        case "message" where payload["role"] as? String == "assistant":
            activity = "Writing a reply"
        default:
            return
        }
        activityAt = date
        let horizon = Date().addingTimeInterval(-Activity.traceWindow)
        if let first = beats.first, first < horizon { beats.removeAll { $0 < horizon } }
    }

    private func registerQuestions(_ payload: [String: Any], id: String?) {
        guard let id, let questions = payload["questions"] as? [[String: Any]], !questions.isEmpty else { return }
        // The tool call and its UI event describe the same question batch.
        if pendingQuestions[id] == nil { pendingQuestions[id] = Set(questions.indices) }
    }

    private func answerQuestions(_ content: Any?) -> Bool {
        guard let content = content as? [[String: Any]] else { return false }
        var changed = false
        for part in content {
            guard let text = part["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let opening = "<send_user_message_question_reply>"
            let closing = "</send_user_message_question_reply>"
            guard trimmed.hasPrefix(opening), trimmed.hasSuffix(closing) else { continue }
            let body = trimmed.dropFirst(opening.count).dropLast(closing.count)
            guard let replies = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]] else { continue }
            for reply in replies {
                guard let item = reply["questionItemId"] as? String,
                      let identity = try? JSONSerialization.jsonObject(with: Data(item.utf8)) as? [Any],
                      identity.count == 3,
                      let tool = identity[0] as? String, tool.split(separator: ".").last == "request_user_input_async",
                      let call = identity[1] as? String, let index = identity[2] as? Int,
                      pendingQuestions[call]?.remove(index) != nil else { continue }
                changed = true
                if pendingQuestions[call]?.isEmpty == true { pendingQuestions[call] = nil }
            }
        }
        return changed
    }

    @discardableResult
    private func apply(_ line: Data) -> Bool {
        noteActivity(line)
        // Completion events may include a very large final answer. Never discard them
        // because of the answer's length (the old 512 KB cap left turns working forever).
        guard line.range(of: Self.marker) != nil || line.range(of: Data("response_item".utf8)) != nil
                || line.range(of: Data("session_meta".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return false }
        if obj["type"] as? String == "session_meta" {
            sessionID = payload["session_id"] as? String ?? payload["id"] as? String
            isSubagent = payload["thread_source"] as? String == "subagent"
                || (payload["source"] as? [String: Any])?["subagent"] != nil
            if let cwd = payload["cwd"] as? String { title = URL(fileURLWithPath: cwd).lastPathComponent }
            return false
        }
        guard let type = payload["type"] as? String else { return false }
        let date = EventDate.parse(obj["timestamp"] as? String)
        let eventTurn = payload["turn_id"] as? String
        let matchesTurn = eventTurn == nil || turnID == nil || eventTurn == turnID

        if obj["type"] as? String == "response_item" {
            if type == "function_call",
               (payload["name"] as? String)?.split(separator: ".").last == "request_user_input_async" {
                if let arguments = payload["arguments"] as? String,
                   let questions = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] {
                    registerQuestions(questions, id: payload["call_id"] as? String)
                }
                stateChangedAt = date; lastEvidenceAt = date
                return true
            }
            if type == "message", payload["role"] as? String == "user",
               answerQuestions(payload["content"]) {
                stateChangedAt = date; lastEvidenceAt = date
                return true
            }
            if type == "function_call", ["request_user_input", "functions.request_user_input"].contains(payload["name"] as? String ?? "") {
                state = .waiting; stateChangedAt = date; lastEvidenceAt = date
                return true
            }
            // A final-channel response is explicit completion evidence, unlike commentary.
            if type == "message", payload["role"] as? String == "assistant",
               ["final", "final_answer"].contains(payload["phase"] as? String ?? "") {
                state = .idle; interrupted = false; finishedAt = date
                stateChangedAt = date; lastEvidenceAt = date
                return true
            }
            let progress = ["reasoning", "function_call", "custom_tool_call", "local_shell_call",
                            "function_call_output", "custom_tool_call_output", "web_search_call"].contains(type)
                || (type == "message" && payload["role"] as? String == "assistant")
            if progress {
                lastEvidenceAt = date
                if reportedState == .waiting { state = .working }
                if state == .unknown { state = .working }
            }
            return false
        }
        guard obj["type"] as? String == "event_msg" else { return false }
        switch type {
        case "item_completed":
            guard matchesTurn, let item = payload["item"] as? [String: Any] else { return false }
            if item["type"] as? String == "AgentMessage", item["delivery"] as? String == "async" {
                registerQuestions(item, id: item["id"] as? String)
            } else if item["type"] as? String == "UserMessage" {
                guard answerQuestions(item["content"]) else { return false }
            } else {
                lastEvidenceAt = date
                return false
            }
        case "task_started", "turn_started":
            // Duplicate starts must not reset a running turn's clock.
            if eventTurn == nil || eventTurn != turnID { turnStartedAt = date }
            turnID = eventTurn ?? date.map { String($0.timeIntervalSince1970) }
            state = .working; interrupted = false; finishedAt = nil
            activity = nil; activityAt = nil; beats.removeAll()
        case "task_complete", "turn_complete":
            guard matchesTurn else { return false }
            turnID = turnID ?? eventTurn
            state = .idle; interrupted = false; finishedAt = date
        case "turn_aborted":
            guard matchesTurn else { return false }
            pendingQuestions.removeAll()
            turnID = turnID ?? eventTurn
            state = .idle; interrupted = true; finishedAt = nil
        case "exec_approval_request", "apply_patch_approval_request",
             "request_user_input", "elicitation_request":
            guard matchesTurn else { return false }
            state = .waiting
        default:
            if matchesTurn && ["token_count", "agent_reasoning", "agent_message", "item_completed"].contains(type) {
                lastEvidenceAt = date
            }
            return false
        }
        stateChangedAt = date
        lastEvidenceAt = date
        return true
    }
}

/// Agent logs occur both with and without fractional seconds; invalid timestamps are
/// unknown evidence, never silently replaced with the current time on each restart.
enum EventDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractional.date(from: value) ?? whole.date(from: value)
    }
}
