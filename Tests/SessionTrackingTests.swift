import Foundation
import Darwin

@main
struct SessionTrackingTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            count += 1
            print("PASS \(label)")
        }
        let formatter = ISO8601DateFormatter()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func line(_ kind: String, _ payload: [String: Any], _ seconds: Double = 0) -> Data {
            var data = try! JSONSerialization.data(withJSONObject: ["type": kind, "payload": payload,
                "timestamp": formatter.string(from: now.addingTimeInterval(seconds))], options: [.sortedKeys])
            data.append(0x0A)
            return data
        }
        func event(_ type: String, _ seconds: Double = 0, turn: String = "a", extra: [String: Any] = [:]) -> Data {
            var payload = extra; payload["type"] = type; payload["turn_id"] = turn
            return line("event_msg", payload, seconds)
        }
        let meta = line("session_meta", ["id": "chat", "session_id": "chat", "cwd": "/tmp/test project", "thread_source": "user"])
        func file(_ name: String, _ data: Data) throws -> RolloutFile {
            let path = root.appendingPathComponent(name).path
            try (meta + data).write(to: URL(fileURLWithPath: path))
            return RolloutFile(path: path)
        }
        func append(_ f: RolloutFile, _ data: Data) throws {
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: f.path))
            try h.seekToEnd(); try h.write(contentsOf: data); try h.close()
            f.readNew()
        }

        check(ClaudeSource.registryState("shell") == .idle, "Claude background shells are idle")
        check(ClaudeSource.registryState("busy") == .working, "Claude active model remains working")
        check(ClaudeSource.registryState("waiting") == .waiting, "Claude input wait remains waiting")
        check(ClaudeSource.registryState("future-status") == .unknown, "Unknown Claude status is not completion")
        check(SessionEvidence.state(.working, lastActivity: now.addingTimeInterval(-7200), now: now) == .unknown,
              "Silent abandoned work does not run an endless clock")
        check(SessionEvidence.state(.working, lastActivity: now, now: now) == .working, "Recent work restores confidence")
        check(SessionEvidence.state(.waiting, lastActivity: now.addingTimeInterval(-180000), now: now) == .waiting,
              "Long explicit user waits do not expire")

        // CLI subagent rollouts contain copied parent metadata and history after their own header.
        let childMeta = line("session_meta", ["id": "child", "session_id": "chat", "thread_source": "subagent"])
        let childPath = root.appendingPathComponent("inherited-child")
        try (childMeta + meta + event("task_started", -20) + event("task_complete", -1)).write(to: childPath)
        let child = RolloutFile(path: childPath.path)
        check(child.isSubagent, "Copied parent metadata cannot turn a subagent into a main chat")
        let parent = try file("active-parent", event("task_started", -30))
        check(CodexSource.merge([parent, child], now: now).first?.state == .working,
              "A completed subagent cannot finish its working parent")
        check(CodexSource.merge([child], now: now).isEmpty, "Orphan subagents cannot impersonate completed parent chats")
        let long = try file("long-turn", event("task_started", -3600) + line("response_item", [
            "type": "function_call_output", "output": String(repeating: "x", count: 4_100_000)], -1))
        long.pid = getpid()
        check(long.turnStartedAt == now.addingTimeInterval(-3600), "Large logs retain the start and clock of a long turn")
        check(CodexSource.merge([long], now: now.addingTimeInterval(7200)).first?.state == .working,
              "An explicit active turn owned by a live process does not time out")

        long.ownerStartedAt = now.addingTimeInterval(1)
        check(CodexSource.merge([long], now: now.addingTimeInterval(7200)).first?.state == .unknown,
              "A newly restarted CLI process cannot resurrect an abandoned old turn")
        let missing = RolloutFile(path: root.appendingPathComponent("missing-log").path)
        check(CodexSource.merge([missing], now: now).first?.state == .unknown,
              "An unreadable log is unconfirmed, never completed")

        let old = try file("old", event("task_started", -180000))
        let done = try file("new", event("task_started", -30) + event("task_complete", -10))
        check(CodexSource.merge([old, done], now: now).first?.state == .idle,
              "New completion overrides 50-hour working continuation")
        check(CodexSource.merge([done, old], now: now).first?.state == .idle, "Continuation selection is deterministic")
        check(old.sessionID == "chat" && old.title == "test project", "JSON metadata supports spaces and key order")

        let split = event("task_complete", 1)
        let boundary = split.count / 2
        let partial = try file("partial", event("task_started") + split.prefix(boundary))
        check(partial.state == .working, "Partial completion is buffered at startup")
        try append(partial, Data(split.dropFirst(boundary)))
        check(partial.state == .idle, "Completion split across launch is not lost")
        check(RolloutFile(path: partial.path).state == .idle, "Restart agrees with incremental parsing")

        let big = try file("big", event("task_started"))
        try append(big, event("task_complete", 1, extra: ["last_agent_message": String(repeating: "x", count: 600_000)]))
        check(big.state == .idle, "Large completion payload is recognized")
        let final = try file("final", event("task_started"))
        try append(final, line("response_item", ["type": "message", "role": "assistant", "phase": "commentary"], 1))
        check(final.state == .working, "Commentary does not finish a turn")
        try append(final, line("response_item", ["type": "message", "role": "assistant", "phase": "final_answer"], 2))
        check(final.state == .working, "A final response cannot finish an explicitly active turn")
        try append(final, event("task_complete", 3))
        check(final.state == .idle, "Explicit completion finishes the active turn")
        let legacyFinal = try file("legacy-final", line("response_item", ["type": "message", "role": "assistant", "phase": "final_answer"], 2))
        check(legacyFinal.state == .idle, "Final response remains a fallback without an active lifecycle")

        let waiting = try file("waiting", event("task_started") + event("request_user_input", 1))
        try append(waiting, event("token_count", 2))
        check(waiting.state == .waiting, "Bookkeeping cannot answer a user prompt")
        try append(waiting, line("response_item", ["type": "function_call_output", "output": "ok"], 3))
        check(waiting.state == .working, "Tool result resumes a waiting turn")
        func asyncQuestion(_ id: String, count: Int = 1, qualified: Bool = false) -> Data {
            let args = try! JSONSerialization.data(withJSONObject: ["questions": Array(repeating: ["title": "Choose"], count: count)])
            return line("response_item", ["type": "function_call", "name": qualified ? "functions.request_user_input_async" : "request_user_input_async",
                "call_id": id, "arguments": String(data: args, encoding: .utf8)!], 4)
        }
        func answer(_ id: String, index: Int = 0) -> Data {
            let identity = try! JSONSerialization.data(withJSONObject: ["request_user_input_async", id, index])
            let replies = try! JSONSerialization.data(withJSONObject: [["answer": "Yes", "questionItemId": String(data: identity, encoding: .utf8)!]])
            let text = "<send_user_message_question_reply>\n" + String(data: replies, encoding: .utf8)! + "\n</send_user_message_question_reply>"
            return line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]], 8)
        }
        let async = try file("async", event("task_started"))
        let alerts = SessionStore()
        _ = alerts.reconcile(CodexSource.merge([async], now: now), showDoneFor: nil)
        try append(async, asyncQuestion("question", count: 2))
        try append(async, line("response_item", ["type": "function_call_output", "call_id": "question", "output": "{\"accepted\":true}"], 5))
        try append(async, line("response_item", ["type": "reasoning"], 6))
        try append(async, line("response_item", ["type": "function_call_output", "call_id": "unrelated", "output": "ok"], 7))
        check(async.state == .waiting, "Async question survives acknowledgement, reasoning, and unrelated tool output")
        let asyncRows = alerts.reconcile(CodexSource.merge([async], now: now), showDoneFor: nil)
        check(asyncRows.first?.phase == .waiting && alerts.inputRequiredKeys == ["codex:chat"],
              "Async question reaches the waiting row and Bottle sound trigger")
        try append(async, answer("other"))
        check(async.state == .waiting, "Unrelated answer cannot clear a pending question")
        try append(async, answer("question"))
        check(async.state == .waiting, "Partially answered question batch remains waiting")
        try append(async, answer("question", index: 1))
        check(async.state == .working, "Answering all async questions resumes work")
        try append(async, asyncQuestion("next", qualified: true))
        try append(async, line("response_item", ["type": "message", "role": "assistant", "phase": "final_answer"], 9))
        try append(async, event("task_complete", 10))
        check(async.state == .waiting, "Unanswered async question stays visible after task completion")
        check(RolloutFile(path: async.path).state == .waiting, "Reload reconstructs unanswered async questions")
        try append(async, answer("next"))
        check(async.state == .idle, "Answer after completion restores done state")
        check(RolloutFile(path: async.path).state == .idle, "Reload agrees after async answers")
        let mirror = try file("async-ui", event("task_started") + event("item_completed", 1, extra: ["item": [
            "type": "AgentMessage", "delivery": "async", "id": "ui-question", "questions": [["title": "Choose"]]]]))
        check(mirror.state == .waiting, "Async UI event recovers missing tool call")
        try append(mirror, event("turn_aborted", 2))
        check(mirror.state == .idle && mirror.interrupted, "Aborting clears pending async questions")

        let superseded = try file("superseded-question", event("task_started") + asyncQuestion("old-question") + event("task_complete", 5))
        check(superseded.state == .waiting, "An unanswered question remains visible after its task completes")
        try append(superseded, event("task_started", 6, turn: "new-task"))
        check(superseded.state == .waiting, "Automatic continuation alone cannot discard an unanswered question")
        try append(superseded, line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Continue with this new task"]]], 7))
        check(superseded.state == .working && !superseded.hasPendingQuestions,
              "A new user task supersedes an unanswered old question")
        let blocking = try file("blocking-question", event("task_started") + line("response_item", [
            "type": "function_call", "name": "request_user_input", "call_id": "blocking"], 1))
        try append(blocking, line("response_item", ["type": "function_call_output", "call_id": "other", "output": "ok"], 2))
        check(blocking.state == .waiting, "An unrelated tool output cannot clear a blocking CLI question")
        try append(blocking, line("response_item", ["type": "function_call_output", "call_id": "blocking", "output": "{\"answers\":{}}"], 3))
        check(blocking.state == .working, "The matching CLI question result resumes work")
        let scoped = try file("scoped-final", event("task_started", 0, turn: "new-task") + line("response_item", [
            "type": "message", "role": "assistant", "phase": "final_answer",
            "internal_chat_message_metadata_passthrough": ["turn_id": "old-task"]], 2))
        check(scoped.state == .working, "An old turn's final response cannot finish current work")

        let rejected = try file("rejected-question", event("task_started") + asyncQuestion("rejected"))
        try append(rejected, line("response_item", ["type": "function_call_output", "call_id": "rejected", "output": "{\"accepted\":false}"], 5))
        check(rejected.state == .working, "An async question that was not accepted cannot leave a stuck wait")
        let duplicate = try file("duplicate-question", event("task_started") + asyncQuestion("duplicate") + answer("duplicate"))
        try append(duplicate, event("item_completed", 9, extra: ["item": ["type": "AgentMessage", "delivery": "async", "id": "duplicate", "questions": [["title": "Choose"]]]]))
        check(duplicate.state == .working, "A delayed duplicate UI question cannot resurrect an answered prompt")
        check(RolloutFile(path: duplicate.path).state == .working, "Answered prompt remains cleared after a full reload")

        let newer = try file("newer", event("task_started", 0, turn: "b"))
        try append(newer, event("task_complete", 1, turn: "a"))
        check(newer.state == .working, "Late completion from an old turn cannot stop the new one")
        try append(newer, event("task_started", 2, turn: "b"))
        check(newer.turnStartedAt == now, "Duplicate starts preserve the real start")
        try append(newer, event("turn_aborted", 3, turn: "b"))
        check(newer.state == .idle && newer.interrupted, "Aborted turns do not become successful completions")

        let replaced = try file("replace", event("task_started"))
        try meta.write(to: URL(fileURLWithPath: replaced.path), options: .atomic)
        replaced.readNew()
        check(replaced.state == .unknown && replaced.turnStartedAt == nil, "Replacing a log clears old state")
        let truncated = try file("truncate", event("task_started"))
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: truncated.path))
        try h.truncate(atOffset: UInt64(meta.count)); try h.close(); truncated.readNew()
        check(truncated.state == .unknown && truncated.turnStartedAt == nil, "Truncating a log clears old state")
        check(CodexSource.merge([old], now: now).first?.state == .unknown, "Orphan start is unconfirmed after restart")
        try append(old, line("response_item", ["type": "reasoning"], 0))
        check(CodexSource.merge([old], now: now).first?.state == .working, "Fresh evidence restores a quiet turn")

        let store = SessionStore()
        let info = SessionInfo(project: "test", title: nil, pid: nil, deepLink: nil)
        func raw(_ state: RawState, _ id: String, _ start: Date) -> RawSession {
            RawSession(key: "test", agent: .codex, info: info, state: state, finishedAt: nil,
                       turnStartedAt: start, turnID: id)
        }
        _ = store.reconcile([raw(.working, "a", now.addingTimeInterval(-180000))], showDoneFor: 300)
        check(store.reconcile([raw(.working, "b", now)], showDoneFor: 300).first?.since == now,
              "Missed idle transition cannot carry a 50-hour clock into a new turn")
        check(store.reconcile([raw(.waiting, "b", now)], showDoneFor: 300).first?.since == now,
              "Approval waits preserve the same turn clock")
        check(store.reconcile([raw(.unknown, "b", now)], showDoneFor: 300).first?.since == nil,
              "Unconfirmed status has no running clock")
        check(store.reconcile([raw(.working, "b", now)], showDoneFor: 300).first?.since == now,
              "Recovery preserves actual start time")
        check(store.reconcile([], showDoneFor: 300).isEmpty, "Closed sessions are removed")
        for agent in Agent.allCases {
            let sounds = SessionStore()
            func soundRaw(_ state: RawState, interrupted: Bool = false) -> RawSession {
                RawSession(key: agent.rawValue, agent: agent, info: info, state: state,
                           finishedAt: Date(), interrupted: interrupted)
            }
            _ = sounds.reconcile([soundRaw(.idle)], showDoneFor: nil)
            check(sounds.completedKeys.isEmpty, "\(agent): startup completions stay silent")
            _ = sounds.reconcile([soundRaw(.working)], showDoneFor: nil)
            _ = sounds.reconcile([soundRaw(.waiting)], showDoneFor: nil)
            check(sounds.completedKeys.isEmpty, "\(agent): approval waits do not signal completion")
            check(sounds.inputRequiredKeys == [agent.rawValue], "\(agent): entering a wait signals input required")
            _ = sounds.reconcile([soundRaw(.waiting)], showDoneFor: nil)
            check(sounds.inputRequiredKeys.isEmpty, "\(agent): ongoing waits do not repeat the sound")
            _ = sounds.reconcile([soundRaw(.working)], showDoneFor: nil)
            _ = sounds.reconcile([soundRaw(.waiting)], showDoneFor: nil)
            check(sounds.inputRequiredKeys == [agent.rawValue], "\(agent): a later input request signals again")
            _ = sounds.reconcile([soundRaw(.idle)], showDoneFor: 0)
            check(sounds.completedKeys == [agent.rawValue], "\(agent): completion signals even with finished rows hidden")
            _ = sounds.reconcile([soundRaw(.idle)], showDoneFor: nil)
            check(sounds.completedKeys.isEmpty, "\(agent): refresh and visibility changes do not repeat completion")
            sounds.dismissFinished()
            _ = sounds.reconcile([soundRaw(.idle)], showDoneFor: nil)
            check(sounds.completedKeys.isEmpty, "\(agent): dismissing a row does not repeat completion")
            _ = sounds.reconcile([soundRaw(.working)], showDoneFor: nil)
            _ = sounds.reconcile([soundRaw(.idle, interrupted: true)], showDoneFor: nil)
            check(sounds.completedKeys.isEmpty, "\(agent): cancelled turns stay silent")
            _ = sounds.reconcile([soundRaw(.working)], showDoneFor: nil)
            _ = sounds.reconcile([soundRaw(.unknown)], showDoneFor: nil)
            check(sounds.completedKeys.isEmpty, "\(agent): stale work stays silent")
            _ = sounds.reconcile([soundRaw(.idle)], showDoneFor: nil)
            check(sounds.completedKeys == [agent.rawValue], "\(agent): completion after unconfirmed state signals")
            _ = sounds.reconcile([soundRaw(.working)], showDoneFor: nil)
            _ = sounds.reconcile([], showDoneFor: nil)
            check(sounds.completedKeys.isEmpty, "\(agent): closed sessions stay silent")
            _ = sounds.reconcile([soundRaw(.waiting)], showDoneFor: nil)
            check(sounds.inputRequiredKeys.isEmpty, "\(agent): existing waits loaded at startup stay silent")
        }
        // Exercise Claude's actual registry/transcript reader, including refresh and PID reuse.
        let claudeHome = root.appendingPathComponent("claude")
        let registryDir = claudeHome.appendingPathComponent("sessions")
        let transcriptDir = claudeHome.appendingPathComponent("projects/-tmp-test")
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let oldHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", claudeHome.path, 1)
        defer {
            if let oldHome { setenv("CLAUDE_CONFIG_DIR", oldHome, 1) }
            else { unsetenv("CLAUDE_CONFIG_DIR") }
        }
        let pid = getpid()
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        precondition(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, size) == size)
        let startFormat = DateFormatter()
        startFormat.locale = Locale(identifier: "en_US_POSIX")
        startFormat.timeZone = TimeZone(secondsFromGMT: 0)
        startFormat.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let identity = startFormat.string(from: Date(timeIntervalSince1970: Double(process.pbi_start_tvsec)))
        let registryPath = registryDir.appendingPathComponent("\(pid).json")
        let transcriptPath = transcriptDir.appendingPathComponent("session.jsonl")
        func registry(_ status: String, _ identity: String, _ age: Double = 0) throws {
            let ms = Date().addingTimeInterval(-age).timeIntervalSince1970 * 1000
            let obj: [String: Any] = ["pid": pid, "sessionId": "session", "cwd": "/tmp/test",
                "procStart": identity, "status": status, "statusUpdatedAt": ms, "startedAt": ms - 100_000]
            try JSONSerialization.data(withJSONObject: obj).write(to: registryPath)
        }
        func prompt(_ id: String) throws {
            let obj: [String: Any] = ["type": "user", "uuid": id, "timestamp": formatter.string(from: Date()),
                                      "message": ["content": "Test prompt"]]
            var data = try JSONSerialization.data(withJSONObject: obj)
            data.append(0x0A)
            try data.write(to: transcriptPath, options: .atomic)
        }
        let claude = ClaudeSource()
        try prompt("first")
        try registry("shell", identity)
        check(claude.sessions().first?.state == .idle, "Claude reader excludes background shells from running work")
        try registry("busy", identity)
        check(claude.sessions().first?.turnID == "first", "Claude reader identifies the current prompt")
        try prompt("later")
        check(claude.sessions().first?.turnID == "later", "Replaced same-size Claude transcript resets cached prompt")
        claude.reload()
        check(claude.sessions().first?.turnID == "later", "Refresh reconstructs Claude's actual turn")
        try registry("busy", "Mon Jan 1 00:00:00 2001")
        check(claude.sessions().isEmpty, "Reused PID cannot resurrect stale Claude registry")
        try FileManager.default.removeItem(at: transcriptPath)
        claude.reload()
        try registry("busy", identity, 7200)
        check(claude.sessions().first?.state == .unknown, "Stale Claude busy registry is unconfirmed without transcript evidence")
        try registry("waiting", identity, 7200)
        check(claude.sessions().first?.state == .waiting, "Claude registry keeps explicit waits even without a transcript")

        print("\(count) regression checks passed")
    }
}
