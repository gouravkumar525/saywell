import AppKit
import Darwin
import LocalFlowCore
import SwiftUI

// MARK: - Socket

/// C6: listens on a Unix domain socket for `saywell-hook`. Only processes of
/// this user can connect (0600 socket in a 0700 folder, peer uid checked);
/// it is not a network socket, so nothing outside the Mac can reach it.
final class AgentServer {
    static var socketPath: String { Store.appSupportDirectory.appendingPathComponent("agent.sock").path }

    /// Called on the main thread. `fd` is the open connection for a permission
    /// request or question (answer with `reply`), nil for plain events.
    var onEvent: ((AgentProtocol.Event, Int32?) -> Void)?
    private var listener: Int32 = -1

    func start() {
        guard listener < 0 else { return }
        let dir = Store.appSupportDirectory.path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        let path = Self.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            Log.write("agents: socket failed (errno \(errno))")
            close(fd)
            return
        }
        listener = fd
        Log.write("agents: listening on \(path)")
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        unlink(Self.socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !data.contains(0x0A), data.count < 1_000_000 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        guard let line = data.split(separator: 0x0A).first, let event = AgentProtocol.parse(Data(line)) else {
            close(fd)
            return
        }
        if event.kind == .event { close(fd) }
        let keep: Int32? = event.kind == .event ? nil : fd
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event, keep) }
    }

    /// Sends the helper what to print (nothing → Claude Code asks in the terminal).
    static func reply(_ fd: Int32, output: String?) {
        var object: [String: Any] = [:]
        if let output { object["output"] = output }
        if var data = try? JSONSerialization.data(withJSONObject: object) {
            data.append(0x0A)
            data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        }
        close(fd)
    }
}

// MARK: - Sessions and requests

struct AgentSession: Identifiable, Equatable {
    var id: String
    var project: String
    var host: String?
    var step: String
    var working: Bool
    var updated: Date
}

/// A permission request or a question waiting in the notch.
final class AgentRequest: Identifiable {
    let id = UUID()
    let event: AgentProtocol.Event
    let fd: Int32
    let questions: [AgentProtocol.Question]
    let received = Date()
    var hangup: DispatchSourceRead?
    var answered = false

    init(event: AgentProtocol.Event, fd: Int32) {
        self.event = event
        self.fd = fd
        questions = event.kind == .ask ? AgentProtocol.questions(event) : []
    }

    var isQuestion: Bool { event.kind == .ask }
}

/// C6: what Claude Code is doing, and the requests waiting for you.
final class AgentCenter: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var queue: [AgentRequest] = []
    /// Answers so far to the current question card: question → chosen labels.
    @Published var answers: [String: [String]] = [:]
    @Published var questionIndex = 0
    /// Show Claude Code's requests in the notch (Agents tab).
    @Published var cardsEnabled = true

    /// Called when the request at the front changes, or a session finishes.
    var onChange: (() -> Void)?
    var onFinished: (() -> Void)?

    static let maxQueue = 5
    /// Give up a little before the helper does, so Claude Code falls back cleanly.
    static let answerTimeout: TimeInterval = 115

    var current: AgentRequest? { queue.first }
    var isWorking: Bool { sessions.contains { $0.working && Date().timeIntervalSince($0.updated) < 1800 } }

    func handle(_ event: AgentProtocol.Event, fd: Int32?) {
        track(event)
        guard let fd else {
            // A tool that ran (or a new prompt) means its request was answered in the terminal.
            if ["PostToolUse", "UserPromptSubmit", "Stop", "SessionEnd"].contains(event.hookEvent) {
                for r in queue where r.event.sessionID == event.sessionID { finish(r, output: nil) }
            }
            return
        }
        guard cardsEnabled, queue.count < Self.maxQueue,
              event.kind == .permission || !AgentProtocol.questions(event).isEmpty else {
            AgentServer.reply(fd, output: nil)
            return
        }
        let request = AgentRequest(event: event, fd: fd)
        // The person answered in the terminal: the helper hangs up, the card goes.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self, weak request] in
            guard let self, let request, !request.answered else { return }
            var byte: UInt8 = 0
            if recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0 { self.finish(request, output: nil) }
        }
        source.resume()
        request.hangup = source
        queue.append(request)
        Log.write("agents: \(event.kind.rawValue) from \(event.project): \(event.toolName ?? "") \(event.summary ?? "")")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerTimeout) { [weak self, weak request] in
            guard let self, let request, !request.answered else { return }
            Log.write("agents: no answer in \(Int(Self.answerTimeout))s; Claude Code asks in the terminal")
            self.finish(request, output: nil)
        }
        if queue.count == 1 { resetAnswers() }
        onChange?()
    }

    private func track(_ event: AgentProtocol.Event) {
        let step = AgentProtocol.step(for: event)
        let working = !["Stop", "SessionEnd", "Notification"].contains(event.hookEvent)
        if let i = sessions.firstIndex(where: { $0.id == event.sessionID }) {
            sessions[i].step = step
            sessions[i].working = working
            sessions[i].updated = Date()
            if let host = event.host { sessions[i].host = host }
        } else if event.hookEvent != "SessionEnd" {
            sessions.insert(AgentSession(id: event.sessionID, project: event.project, host: event.host, step: step,
                                         working: working, updated: Date()), at: 0)
        }
        if event.hookEvent == "SessionEnd" { sessions.removeAll { $0.id == event.sessionID } }
        sessions.removeAll { Date().timeIntervalSince($0.updated) > 12 * 3600 }
        if event.hookEvent == "Stop" { onFinished?() }
        onChange?()
    }

    // MARK: Answers

    func decide(_ decision: AgentProtocol.Decision) {
        guard let r = current, !r.isQuestion else { return }
        Log.write("agents: \(decision) for \(r.event.toolName ?? "")")
        finish(r, output: AgentProtocol.permissionOutput(decision, event: r.event))
    }

    /// Picks an option; single-choice questions move on, the last one sends.
    func choose(_ option: String) {
        guard let r = current, r.isQuestion, questionIndex < r.questions.count else { return }
        let q = r.questions[questionIndex]
        if q.multiSelect {
            var chosen = answers[q.question] ?? []
            if let i = chosen.firstIndex(of: option) { chosen.remove(at: i) } else { chosen.append(option) }
            answers[q.question] = chosen
        } else {
            answers[q.question] = [option]
            next()
        }
    }

    /// Done with a multi-select question.
    func next() {
        guard let r = current, r.isQuestion else { return }
        if questionIndex + 1 < r.questions.count {
            questionIndex += 1
        } else {
            finish(r, output: AgentProtocol.answerOutput(event: r.event, answers: answers))
        }
    }

    /// "Reply in Terminal": Claude Code asks there instead.
    func toTerminal() {
        guard let r = current else { return }
        finish(r, output: nil)
        jumpToTerminal(host: r.event.host)
    }

    private func finish(_ r: AgentRequest, output: String?) {
        guard !r.answered else { return }
        r.answered = true
        r.hangup?.cancel()
        AgentServer.reply(r.fd, output: output)
        let wasCurrent = queue.first === r
        queue.removeAll { $0 === r }
        if wasCurrent { resetAnswers() }
        onChange?()
    }

    private func resetAnswers() {
        answers = [:]
        questionIndex = 0
    }

    // MARK: Terminal

    private static let terminals: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2", "WarpTerminal": "dev.warp.Warp-Stable",
        "ghostty": "com.mitchellh.ghostty", "vscode": "com.microsoft.VSCode", "WezTerm": "com.github.wez.wezterm",
        "kitty": "net.kovidgoyal.kitty", "Hyper": "co.zeit.hyper", "zed": "dev.zed.Zed",
    ]

    /// Brings the session's terminal or editor to the front.
    func jumpToTerminal(host: String?) {
        let ids = [host, host.flatMap { Self.terminals[$0] }].compactMap { $0 } + Array(Self.terminals.values)
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
                return
            }
        }
    }
}

// MARK: - Claude Code settings

/// Reads and writes ~/.claude/settings.json (only after the user confirms the
/// preview), and keeps a stable copy of the hook helper.
enum ClaudeHooks {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// A stable path for the helper, so moving the app doesn't break the hooks.
    static var helperURL: URL { Store.appSupportDirectory.appendingPathComponent("bin/\(AgentProtocol.helperName)") }

    static func installHelper() throws {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: AgentProtocol.helperName) else {
            throw NSError(domain: "Agents", code: 1, userInfo: [NSLocalizedDescriptionKey: "The hook helper is missing from Saywell.app"])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.contentsEqual(atPath: bundled.path, andPath: helperURL.path) { return }
        try? fm.removeItem(at: helperURL)
        try fm.copyItem(at: bundled, to: helperURL)
    }

    struct Plan {
        let original: Data?
        let before: [String: Any]
        let after: [String: Any]
        var beforeText: String { AgentProtocol.prettyJSON(before) }
        var afterText: String { AgentProtocol.prettyJSON(after) }
    }

    static func read() throws -> (Data?, [String: Any]) {
        guard let data = try? Data(contentsOf: settingsURL) else { return (nil, [:]) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentProtocol.SettingsError.unexpectedShape("settings.json is not a JSON object")
        }
        return (data, object)
    }

    static func isInstalled() -> Bool {
        (try? read()).map { AgentProtocol.isInstalled($0.1) } ?? false
    }

    static func plan(install: Bool) throws -> Plan {
        let (data, settings) = try read()
        let after = install ? try AgentProtocol.installingHooks(into: settings, helper: helperURL.path)
                            : try AgentProtocol.removingHooks(from: settings)
        return Plan(original: data, before: settings, after: after)
    }

    /// Writes the plan if settings.json hasn't changed since it was made; keeps a backup.
    static func apply(_ plan: Plan) throws {
        let current = try? Data(contentsOf: settingsURL)
        guard current == plan.original else {
            throw NSError(domain: "Agents", code: 2, userInfo: [NSLocalizedDescriptionKey: "settings.json changed meanwhile; try again"])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try current.write(to: settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.saywell-backup-\(stamp)"))
        }
        try plan.afterText.write(to: settingsURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Notch card

/// The request at the front of the queue, in the notch or the bottom pill.
struct AgentCardView: View {
    @ObservedObject var center: AgentCenter

    var body: some View {
        if let r = center.current {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Claude Code · \(r.event.project)")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                    if center.queue.count > 1 {
                        Text("+\(center.queue.count - 1)").font(.system(size: 10, weight: .bold)).foregroundColor(.orange)
                    }
                }
                if r.isQuestion { question(r) } else { permission(r) }
            }
        }
    }

    private func permission(_ r: AgentRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(r.event.toolName ?? "Tool").font(.system(size: 12, weight: .bold)).foregroundColor(.orange)
                Text(r.event.summary ?? "")
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                    .lineLimit(2).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                CardButton(title: "Deny", tint: .red) { center.decide(.deny) }
                CardButton(title: "Allow", tint: .green, prominent: true) { center.decide(.allow) }
                if r.event.suggestions != nil { CardButton(title: "Always", tint: .blue) { center.decide(.always) } }
                Spacer()
                CardButton(title: "Terminal", tint: .gray) { center.toTerminal() }
            }
        }
    }

    @ViewBuilder
    private func question(_ r: AgentRequest) -> some View {
        let i = min(center.questionIndex, max(0, r.questions.count - 1))
        if r.questions.indices.contains(i) {
            let q = r.questions[i]
            VStack(alignment: .leading, spacing: 6) {
                Text((r.questions.count > 1 ? "\(i + 1)/\(r.questions.count) " : "") + q.question)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(2)
                HStack(spacing: 6) {
                    ForEach(q.options, id: \.self) { option in
                        let picked = center.answers[q.question]?.contains(option) == true
                        CardButton(title: (q.multiSelect && picked ? "✓ " : "") + option, tint: .cyan, prominent: picked) {
                            center.choose(option)
                        }
                    }
                    if q.multiSelect { CardButton(title: "Done", tint: .green, prominent: true) { center.next() } }
                    Spacer()
                    CardButton(title: "Terminal", tint: .gray) { center.toTerminal() }
                }
            }
        }
    }
}

struct CardButton: View {
    var title: String
    var tint: Color
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundColor(prominent ? .black : tint)
                .background(Capsule().fill(prominent ? tint : tint.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Agents tab

final class AgentsViewModel: ObservableObject {
    let center: AgentCenter
    @Published var installed = ClaudeHooks.isInstalled()
    @Published var preview: ClaudeHooks.Plan?
    @Published var previewInstall = true
    @Published var message = ""

    init(center: AgentCenter) { self.center = center }

    func prepare(install: Bool) {
        do {
            if install { try ClaudeHooks.installHelper() }
            preview = try ClaudeHooks.plan(install: install)
            previewInstall = install
            message = ""
        } catch {
            message = "Can't change settings.json: \(error.localizedDescription)"
        }
    }

    func confirm() {
        guard let plan = preview else { return }
        do {
            try ClaudeHooks.apply(plan)
            installed = ClaudeHooks.isInstalled()
            message = installed ? "Connected. New Claude Code sessions report to Saywell." : "Disconnected."
            Log.write("agents: Claude Code hooks \(installed ? "installed" : "removed")")
        } catch {
            message = error.localizedDescription
        }
        preview = nil
    }
}

struct AgentsTab: View {
    @ObservedObject var model: AgentsViewModel
    @ObservedObject var center: AgentCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Code asks for permission and questions in the notch: Allow, Deny, Always, or reply in the terminal. Events reach Saywell over a local socket; nothing leaves your Mac.")
                .font(.callout).foregroundColor(.secondary)
            HStack {
                Text(model.installed ? "Claude Code: connected" : "Claude Code: not connected").bold()
                Spacer()
                Button(model.installed ? "Disconnect…" : "Connect Claude Code…") { model.prepare(install: !model.installed) }
            }
            Toggle("Show Claude Code requests in the notch", isOn: $center.cardsEnabled)
            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundColor(.secondary) }
            if let plan = model.preview {
                Text(model.previewInstall ? "Saywell will write this to ~/.claude/settings.json (a backup is kept):"
                                          : "Saywell will remove only its own hooks (a backup is kept):")
                    .font(.caption)
                ScrollView {
                    Text(plan.afterText).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .border(Color.secondary.opacity(0.3))
                HStack {
                    Button("Cancel") { model.preview = nil }
                    Button(model.previewInstall ? "Write settings.json" : "Remove hooks") { model.confirm() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            Text("Sessions").font(.headline)
            if center.sessions.isEmpty {
                Text("No Claude Code sessions yet. Start one in a terminal after connecting.").foregroundColor(.secondary)
            }
            List(center.sessions) { s in
                HStack {
                    Circle().fill(s.working ? Color.blue : Color.green).frame(width: 7, height: 7)
                    VStack(alignment: .leading) {
                        Text(s.project).bold()
                        Text(s.step).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Terminal") { center.jumpToTerminal(host: s.host) }
                }
            }
        }
    }
}
