import Foundation

/// C6: Claude Code in the notch. Claude Code runs Saywell's tiny hook helper
/// (`saywell-hook`) on its events; the helper passes each event to the app over
/// a local Unix socket and, for a permission request or a question, prints the
/// answer the user picked in the notch. Approach adapted from Coucou's
/// HookServer (MIT). Everything here is pure (tested in AgentProtocolTests).
public enum AgentProtocol {

    // MARK: Events

    public struct Event: Equatable {
        public enum Kind: String { case event, permission, ask }
        public var kind: Kind
        public var hookEvent: String
        public var sessionID: String
        public var cwd: String?
        public var toolName: String?
        /// One line about the tool call: the command, the file, the URL…
        public var summary: String?
        public var message: String?
        /// The terminal or editor the session runs in (TERM_PROGRAM or bundle id).
        public var host: String?
        /// `tool_input` and `permission_suggestions` as raw JSON values (passed back unchanged).
        public var toolInput: [String: Any]
        public var suggestions: Any?

        public static func == (a: Event, b: Event) -> Bool {
            a.kind == b.kind && a.hookEvent == b.hookEvent && a.sessionID == b.sessionID && a.cwd == b.cwd
                && a.toolName == b.toolName && a.summary == b.summary && a.message == b.message && a.host == b.host
        }

        /// The project name: the last folder of the working directory.
        public var project: String {
            guard let cwd, !cwd.isEmpty else { return "Claude Code" }
            return (cwd as NSString).lastPathComponent
        }
    }

    /// The helper's message: {"kind": …, "payload": {hook JSON}, "env": {…}}.
    public static func parse(_ line: Data) -> Event? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else { return nil }
        let env = json["env"] as? [String: String] ?? [:]
        let kind = Event.Kind(rawValue: json["kind"] as? String ?? "") ?? .event
        let tool = payload["tool_name"] as? String
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        return Event(kind: kind,
                     hookEvent: payload["hook_event_name"] as? String ?? "",
                     sessionID: payload["session_id"] as? String ?? "unknown",
                     cwd: payload["cwd"] as? String ?? env["PWD"],
                     toolName: tool,
                     summary: tool.map { summary(tool: $0, input: input) },
                     message: payload["message"] as? String,
                     host: env["__CFBundleIdentifier"] ?? env["TERM_PROGRAM"],
                     toolInput: input,
                     suggestions: payload["permission_suggestions"])
    }

    /// What the tool is about to do, in one short line.
    public static func summary(tool: String, input: [String: Any]) -> String {
        let s: String
        switch tool {
        case "Bash": s = input["command"] as? String ?? ""
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            s = (input["file_path"] as? String ?? input["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        case "WebFetch": s = input["url"] as? String ?? ""
        case "WebSearch": s = input["query"] as? String ?? ""
        case "Grep", "Glob": s = input["pattern"] as? String ?? ""
        case "Task", "Agent": s = input["description"] as? String ?? ""
        case "ExitPlanMode": s = "Approve the plan"
        default:
            s = input.keys.sorted().compactMap { input[$0] as? String }.first ?? ""
        }
        let line = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 160 ? String(line.prefix(157)) + "…" : line
    }

    /// What Sprig and the sessions list show for an event.
    public static func step(for event: Event) -> String {
        switch event.hookEvent {
        case "UserPromptSubmit": return "Working on your prompt"
        case "PreToolUse":
            let verb: String
            switch event.toolName ?? "" {
            case "Bash": verb = "Runs"
            case "Edit", "MultiEdit", "Write", "NotebookEdit": verb = "Edits"
            case "Read": verb = "Reads"
            case "Grep", "Glob": verb = "Searches"
            case "WebFetch", "WebSearch": verb = "Browses"
            default: verb = event.toolName ?? "Uses a tool"
            }
            return [verb, event.summary ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        case "PermissionRequest": return "Needs your OK"
        case "Notification": return event.message ?? "Needs you"
        case "Stop": return "Done"
        case "SessionStart": return "Started"
        case "SessionEnd": return "Ended"
        default: return event.hookEvent
        }
    }

    // MARK: Answers

    public enum Decision: Equatable {
        case allow, always, deny
        /// No answer: Claude Code asks in the terminal.
        case terminal
    }

    /// The text the helper prints for a PermissionRequest; nil prints nothing.
    public static func permissionOutput(_ decision: Decision, event: Event) -> String? {
        var d: [String: Any]
        switch decision {
        case .terminal: return nil
        case .allow: d = ["behavior": "allow"]
        case .always:
            d = ["behavior": "allow"]
            if let suggestions = event.suggestions { d["updatedPermissions"] = suggestions }
        case .deny: d = ["behavior": "deny", "message": "Denied from Saywell"]
        }
        if event.toolName == "ExitPlanMode", decision != .deny { d["updatedInput"] = event.toolInput }
        return json(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]])
    }

    public struct Question: Equatable {
        public var question: String
        public var header: String
        public var options: [String]
        public var multiSelect: Bool
    }

    /// AskUserQuestion's questions (1–4, each with 2–4 options).
    public static func questions(_ event: Event) -> [Question] {
        (event.toolInput["questions"] as? [[String: Any]] ?? []).prefix(4).compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            guard !options.isEmpty else { return nil }
            return Question(question: text, header: String((q["header"] as? String ?? "").prefix(12)),
                            options: Array(options.prefix(4)), multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// The text the helper prints for an answered AskUserQuestion: the tool runs
    /// with the answers filled in. Multi-select answers are joined with ", ".
    public static func answerOutput(event: Event, answers: [String: [String]]) -> String? {
        guard !answers.isEmpty else { return nil }
        var input = event.toolInput
        input["answers"] = answers.mapValues { $0.joined(separator: ", ") }
        return json(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                            "updatedInput": input]])
    }

    static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Claude Code settings

    /// Events Saywell listens to, with the hook timeout in seconds.
    public static let hookEvents: [(event: String, timeout: Int)] = [
        ("SessionStart", 10), ("SessionEnd", 10), ("UserPromptSubmit", 10), ("PreToolUse", 10),
        ("PostToolUse", 10), ("PermissionRequest", 120), ("Notification", 10), ("Stop", 10),
    ]

    public static let helperName = "saywell-hook"

    public enum SettingsError: Error, Equatable {
        case unexpectedShape(String)
    }

    /// `settings` with Saywell's hooks added (any old Saywell entries replaced).
    /// Refuses settings it doesn't understand rather than overwriting them.
    public static func installingHooks(into settings: [String: Any], helper: String) throws -> [String: Any] {
        var out = try removingHooks(from: settings)
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        let command = "\"\(helper)\""
        for (event, timeout) in hookEvents {
            var groups = hooks[event] as? [Any] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": timeout]]])
            hooks[event] = groups
        }
        var pre = hooks["PreToolUse"] as? [Any] ?? []
        pre.append(["matcher": "AskUserQuestion",
                    "hooks": [["type": "command", "command": "\(command) --ask", "timeout": 130]]])
        hooks["PreToolUse"] = pre
        out["hooks"] = hooks
        return out
    }

    /// `settings` without Saywell's hook entries. Other hooks are kept; a group
    /// or event is dropped only when nothing else is left in it.
    public static func removingHooks(from settings: [String: Any]) throws -> [String: Any] {
        var out = settings
        guard let raw = settings["hooks"] else { return out }
        guard var hooks = raw as? [String: Any] else { throw SettingsError.unexpectedShape("hooks") }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { throw SettingsError.unexpectedShape("hooks.\(event)") }
            var kept: [Any] = []
            for group in groups {
                guard var g = group as? [String: Any], let entries = g["hooks"] as? [Any] else {
                    kept.append(group)
                    continue
                }
                let others = entries.filter { entry in
                    !((entry as? [String: Any])?["command"] as? String ?? "").contains(helperName)
                }
                if others.count == entries.count { kept.append(group); continue }
                if !others.isEmpty {
                    g["hooks"] = others
                    kept.append(g)
                }
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        out["hooks"] = hooks.isEmpty ? nil : hooks
        return out
    }

    public static func isInstalled(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [Any] ?? []).contains { group in
                ((group as? [String: Any])?["hooks"] as? [Any] ?? []).contains {
                    ((($0 as? [String: Any])?["command"] as? String) ?? "").contains(helperName)
                }
            }
        }
    }

    /// Pretty JSON for writing settings.json and for the preview.
    public static func prettyJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text + "\n"
    }
}
