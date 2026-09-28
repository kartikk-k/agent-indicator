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

        // One item per chat: subagent threads and continuation files share the chat's
        // session_id, so fold them together. Working beats waiting beats idle.
        let chats = Dictionary(grouping: files.values) { $0.sessionID ?? $0.path }
        return chats.map { id, parts in
            let rank: (RawState) -> Int = { $0 == .working ? 2 : $0 == .waiting ? 1 : 0 }
            let top = parts.max { rank($0.state) < rank($1.state) }!
            let main = parts.first { !$0.isSubagent } ?? parts[0]
            let finished = parts.compactMap(\.finishedAt).max()
            let info = SessionInfo(project: main.title, title: threadNames[id], pid: main.pid,
                                   deepLink: URL(string: "codex://threads/\(id)"))
            return RawSession(key: "codex:\(id)", agent: .codex, info: info, state: top.state,
                              finishedAt: finished, interrupted: top.state == .idle && main.interrupted)
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
    private(set) var state: RawState = .idle
    private(set) var finishedAt: Date?
    private(set) var interrupted = false
    private var offset: UInt64 = 0
    private var partial = Data()

    private static let marker = Data("event_msg".utf8)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(path: String) {
        self.path = path
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }

        // session_meta at the top of the file: chat id, working directory (title), thread kind.
        if let head = try? h.read(upToCount: 64 * 1024),
           let s = String(data: head, encoding: .utf8) {
            func field(_ name: String) -> String? {
                guard let r = s.range(of: "\"\(name)\":\""),
                      let end = s[r.upperBound...].firstIndex(of: "\"") else { return nil }
                return String(s[r.upperBound..<end])
            }
            sessionID = field("session_id") ?? field("id")
            isSubagent = field("thread_source") == "subagent"
            if let cwd = field("cwd") { title = URL(fileURLWithPath: cwd).lastPathComponent }
        }

        // Initial state: scan the tail for the most recent turn event.
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 4_000_000 ? size - 4_000_000 : 0
        try? h.seek(toOffset: start)
        var tail = (try? h.readToEnd()) ?? Data()
        if start > 0, let nl = tail.firstIndex(of: 0x0A) { tail = tail[(nl + 1)...] }
        offset = size

        var sawTurnEvent = false
        for line in tail.split(separator: 0x0A) where apply(Data(line)) { sawTurnEvent = true }
        if !sawTurnEvent {
            // A very long turn may have pushed task_started out of the tail window.
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            state = Date().timeIntervalSince(mtime) < 30 ? .working : .idle
        }
    }

    func readNew() {
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial.removeAll() }   // truncated / replaced
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        guard let chunk = try? h.readToEnd() else { return }
        offset += UInt64(chunk.count)

        partial.append(chunk)
        guard let lastNL = partial.lastIndex(of: 0x0A) else { return }
        let complete = partial[partial.startIndex..<lastNL]
        partial = Data(partial[(lastNL + 1)...])

        for line in complete.split(separator: 0x0A) {
            if !apply(Data(line)), state == .waiting {
                state = .working  // anything else happening means the approval was answered
            }
        }
    }

    /// Returns true if the line was a turn-level event that set the state.
    @discardableResult
    private func apply(_ line: Data) -> Bool {
        guard line.count < 512 * 1024, line.range(of: Self.marker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              let type = payload["type"] as? String
        else { return false }

        switch type {
        case "task_started", "turn_started":
            state = .working; interrupted = false; finishedAt = nil
        case "task_complete", "turn_complete":
            state = .idle; interrupted = false
            finishedAt = (obj["timestamp"] as? String).flatMap(Self.iso.date(from:)) ?? Date()
        case "turn_aborted":
            state = .idle; interrupted = true; finishedAt = nil
        case "exec_approval_request", "apply_patch_approval_request",
             "request_user_input", "elicitation_request":
            state = .waiting
        default:
            return false
        }
        return true
    }
}
