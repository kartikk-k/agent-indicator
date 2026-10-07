import Foundation

enum Agent: String, CaseIterable {
    case claude, codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// What a source reports about one session right now.
enum RawState {
    case working
    case waiting      // blocked on the user (permission prompt, question)
    case idle
    case unknown     // session is open, but there is no recent evidence of work
}

/// Everything needed to label a session and jump to it.
struct SessionInfo: Equatable {
    var project: String          // working-directory name, e.g. "agent-indicator"
    var title: String?           // the agent's short chat title, when it has one
    var pid: pid_t?              // process running the session (for finding its terminal tab)
    var deepLink: URL?           // used when the session lives in a desktop app that has one
}

struct RawSession {
    let key: String
    let agent: Agent
    let info: SessionInfo
    let state: RawState
    /// For sessions seen for the first time while idle: when the last turn finished, if known.
    let finishedAt: Date?
    /// The last turn was cancelled by the user rather than completing.
    var interrupted = false
    /// For sessions seen for the first time mid-turn: when the turn started, if known.
    var turnStartedAt: Date? = nil
    /// What the agent is doing right now ("Editing Overlay.swift"), when known.
    var activity: String? = nil
    /// When recent tool calls happened, for the activity trace.
    var beats: [Date] = []
    /// Stable identity of the agent turn; changes even if an idle transition was missed.
    var turnID: String? = nil
}

enum Phase: Equatable {
    case working, waiting, done, unknown
}

struct Session: Equatable {
    let key: String
    let agent: Agent
    let info: SessionInfo
    let phase: Phase
    /// When the current turn started (working or waiting), for the elapsed-time label.
    let since: Date?
    var activity: String? = nil
    var beats: [Date] = []
}

/// Turns raw source state into what the overlay shows, remembering when turns finished.
final class SessionStore {
    private var lastState: [String: RawState] = [:]
    private var doneAt: [String: Date] = [:]
    private var turnStart: [String: Date] = [:]
    private var firstSeen: [String: Int] = [:]
    private var counter = 0
    private var turnIDs: [String: String] = [:]

    /// Hide finished sessions (all, or the given ones). They reappear only after their next turn finishes.
    func dismissFinished(_ keys: Set<String>? = nil) {
        for (key, state) in lastState where state == .idle && keys?.contains(key) ?? true {
            doneAt[key] = nil
        }
    }

    func reconcile(_ raw: [RawSession], showDoneFor window: TimeInterval?) -> [Session] {
        let now = Date()
        var live = Set<String>()
        var out: [Session] = []

        for r in raw {
            live.insert(r.key)
            if firstSeen[r.key] == nil { counter += 1; firstSeen[r.key] = counter }
            let previous = lastState[r.key]
            lastState[r.key] = r.state

            switch r.state {
            case .working, .waiting:
                doneAt[r.key] = nil
                if let id = r.turnID, id != turnIDs[r.key] {
                    turnStart[r.key] = r.turnStartedAt ?? now
                }
                if turnStart[r.key] == nil {
                    // Waiting for a permission is part of the same turn, so the clock keeps running.
                    turnStart[r.key] = r.turnStartedAt ?? now
                }
            case .unknown:
                doneAt[r.key] = nil
            case .idle:
                turnStart[r.key] = nil
                if r.interrupted {
                    doneAt[r.key] = nil
                } else if let previous, previous != .idle {
                    doneAt[r.key] = r.finishedAt ?? now
                } else if previous == nil, let f = r.finishedAt {
                    doneAt[r.key] = f
                }
            }

            turnIDs[r.key] = r.turnID

            let phase: Phase
            switch r.state {
            case .working: phase = .working
            case .waiting: phase = .waiting
            case .unknown: phase = .unknown
            case .idle:
                guard let d = doneAt[r.key] else { continue }
                if let window, now.timeIntervalSince(d) > window { continue }
                phase = .done
            }
            out.append(Session(key: r.key, agent: r.agent, info: r.info, phase: phase,
                               since: phase == .done || phase == .unknown ? nil : turnStart[r.key],
                               activity: r.activity, beats: r.beats))
        }

        for key in Array(lastState.keys) where !live.contains(key) {
            lastState[key] = nil; doneAt[key] = nil; firstSeen[key] = nil; turnStart[key] = nil; turnIDs[key] = nil
        }

        // Stable order: by agent, then by when we first saw the session. Nothing jumps around.
        return out.sorted {
            if $0.agent != $1.agent { return $0.agent.rawValue < $1.agent.rawValue }
            return firstSeen[$0.key, default: 0] < firstSeen[$1.key, default: 0]
        }
    }
}

/// How rows are labelled in the overlay.
enum LabelMode: String, CaseIterable {
    case project, title, none

    var menuTitle: String {
        switch self {
        case .project: return "Project Name"
        case .title: return "Chat Title"
        case .none: return "Icons Only"
        }
    }

    /// Labels for the visible sessions. In project mode, sessions sharing a project get the
    /// first words of their chat title appended so they can be told apart.
    func labels(for sessions: [Session]) -> [String: String] {
        var out: [String: String] = [:]
        switch self {
        case .none:
            break
        case .title:
            for s in sessions { out[s.key] = s.info.title ?? s.info.project }
        case .project:
            let counts = Dictionary(grouping: sessions, by: \.info.project).mapValues(\.count)
            for s in sessions {
                var label = s.info.project
                if counts[label, default: 0] > 1, let t = s.info.title {
                    label += " · " + t.split(separator: " ").prefix(2).joined(separator: " ")
                }
                out[s.key] = label
            }
        }
        return out
    }
}

/// Silence cannot prove completion: stop claiming work without fabricating a finish.
/// Explicit user waits are exempt. New activity automatically restores the working state.
enum SessionEvidence {
    static let silenceWindow: TimeInterval = 10 * 60

    static func state(_ reported: RawState, lastActivity: Date?, now: Date = Date()) -> RawState {
        guard reported == .working else { return reported }
        guard let lastActivity, now.timeIntervalSince(lastActivity) <= silenceWindow else { return .unknown }
        return .working
    }
}
