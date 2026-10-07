import Foundation

/// Turns the agents' raw tool calls into a short "what it's doing right now" phrase,
/// e.g. "Editing Overlay.swift", "Running tests", "Searching code".
enum Activity {
    /// How far back the activity trace looks.
    static let traceWindow: TimeInterval = 90

    // MARK: Claude Code

    static func claudeTool(_ name: String, _ input: [String: Any]) -> String {
        func file(_ key: String = "file_path") -> String {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "file"
        }
        switch name {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing \(file(name == "NotebookEdit" ? "notebook_path" : "file_path"))"
        case "Read": return "Reading \(file())"
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return d }
            return command(input["command"] as? String ?? "")
        case "Grep": return "Searching code"
        case "Glob": return "Finding files"
        case "WebFetch": return "Reading \((input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "the web")"
        case "WebSearch": return "Searching the web"
        case "Task", "Agent": return (input["description"] as? String).map { "Agent: \($0)" } ?? "Running an agent"
        case "TodoWrite": return "Updating the plan"
        case "Skill": return "Using a skill"
        default:
            if name.hasPrefix("mcp__") {
                let server = name.split(separator: "_", omittingEmptySubsequences: true).dropFirst().first ?? "tool"
                return "Using \(server)"
            }
            return "Using \(name)"
        }
    }

    // MARK: Codex

    /// A Codex tool call (`function_call` / `custom_tool_call`). The desktop app wraps everything
    /// in an `exec` call whose input is code like `tools.exec_command({cmd:"…"})`.
    static func codexCall(name: String, input: String) -> String {
        switch name {
        case "exec":
            guard let tool = firstMatch(#"tools\.([A-Za-z0-9_]+)"#, in: input) else { return "Running code" }
            return codexTool(tool, input)
        default:
            return codexTool(name, input)
        }
    }

    private static func codexTool(_ tool: String, _ input: String) -> String {
        switch tool {
        case "exec_command", "shell", "local_shell", "container.exec":
            let cmd = firstMatch(#""-lc"\s*,\s*"((?:[^"\\]|\\.)*)""#, in: input)       // ["bash","-lc","…"]
                ?? firstMatch(#"cmd\\?"?\s*:\s*\\?"((?:[^"\\]|\\.)*)"#, in: input)
                ?? firstMatch(#""command"\s*:\s*\[?\s*"((?:[^"\\]|\\.)*)""#, in: input)
            return cmd.map { command(unescape($0)) } ?? "Running a command"
        case "apply_patch":
            let path = firstMatch(#"\*\*\* (?:Update|Add|Delete) File: ([^\\\n"]+)"#, in: input)
            return path.map { "Editing \(URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces)).lastPathComponent)" }
                ?? "Editing files"
        case "write_stdin": return "Waiting on a command"
        case "view_image": return "Looking at an image"
        case "web__run", "web_search": return "Browsing the web"
        case "spawn_agent", "send_message", "wait_agent", "wait": return "Coordinating agents"
        case "update_plan": return "Updating the plan"
        default:
            if tool.hasPrefix("mcp__") {
                let server = tool.split(separator: "_", omittingEmptySubsequences: true).dropFirst().first ?? "tool"
                return "Using \(server)"
            }
            return "Using \(tool.replacingOccurrences(of: "_", with: " "))"
        }
    }

    // MARK: Shell commands

    /// "cd app && npm test -- --watch" → "Running tests"; "rg foo" → "Searching code"; "git status" → "git status".
    static func command(_ raw: String) -> String {
        // Drop leading `cd … &&` / `export …;` noise and take the first real command.
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: "&;|\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("cd ") && !$0.hasPrefix("export ") && !$0.hasPrefix("source ") }
        let words = (parts.first ?? raw).split(separator: " ").map(String.init)
            .drop { $0.contains("=") && !$0.hasPrefix("-") }          // FOO=bar cmd
        guard let first = words.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return "Running a command" }
        let second = words.dropFirst().first ?? ""
        let line = words.joined(separator: " ")

        if line.range(of: #"\b(test|tests|pytest|jest|vitest|xctest|rspec)\b"#, options: .regularExpression) != nil {
            return "Running tests"
        }
        switch first {
        case "rg", "grep", "ag", "ack", "fd", "find": return "Searching code"
        case "cat", "head", "tail", "less", "sed", "awk", "nl", "wc", "bat": return "Reading files"
        case "ls", "tree", "stat": return "Looking around"
        case "git", "gh": return [first, second].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        case "npm", "pnpm", "yarn", "bun", "npx", "bunx":
            return "\(first) \(second == "run" ? words.dropFirst(2).first ?? "run" : second)".trimmingCharacters(in: .whitespaces)
        case "swift", "swiftc", "xcodebuild", "cargo", "go", "make", "tsc", "gradle", "mvn": return "Building"
        case "python", "python3", "node", "ruby", "deno": return "Running \(first)"
        case "curl", "wget": return "Fetching from the web"
        case "mkdir", "cp", "mv", "rm", "touch", "chmod", "ln": return "Managing files"
        default: return "Running \(first)"
        }
    }

    // MARK: Helpers

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\")
    }
}
