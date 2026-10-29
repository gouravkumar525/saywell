import AppKit
import LocalFlowCore
import SwiftUI

/// C7: Saywell's main window ("the hub"). Opening Saywell.app shows it; it asks
/// your name the first time, then lands on Dictation: a greeting with Sprig,
/// your history, stats, and the Notetaker. Every setting lives here too.
/// No @State (the toolchain can't expand SwiftUI macros): state is in HubModel.

enum HubPage: String, CaseIterable, Identifiable {
    case dictation, notetaker, statistics, dictionary, snippets, styles
    case general, agents, privacy, training, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .notetaker: return "Notetaker"
        case .statistics: return "Statistics"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .styles: return "Styles"
        case .general: return "General"
        case .agents: return "Agents"
        case .privacy: return "Privacy"
        case .training: return "Training"
        case .shortcuts: return "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .dictation: return "mic"
        case .notetaker: return "record.circle"
        case .statistics: return "chart.bar"
        case .dictionary: return "book.closed"
        case .snippets: return "bolt"
        case .styles: return "textformat"
        case .general: return "gearshape"
        case .agents: return "terminal"
        case .privacy: return "lock.shield"
        case .training: return "brain"
        case .shortcuts: return "keyboard"
        }
    }

    static let flow: [HubPage] = [.dictation, .notetaker, .statistics, .dictionary, .snippets, .styles]
    static let app: [HubPage] = [.general, .agents, .privacy, .training, .shortcuts]
}

/// Reads and changes app settings for the General page. AppDelegate fills in
/// `read` and `apply` so the hub goes through the same code (and the same
/// download prompts) as the menu.
final class HubSettings: ObservableObject {
    @Published private(set) var values: [String: String] = [:]
    var read: () -> [String: String] = { [:] }
    var apply: (String, String) -> Void = { _, _ in }
    /// Options for pickers that depend on the Mac (languages).
    var options: (String) -> [(value: String, label: String)] = { _ in [] }

    func refresh() { values = read() }

    func value(_ key: String) -> String { values[key] ?? "" }

    func set(_ key: String, _ value: String) {
        apply(key, value)
        // Some changes ask first (downloads); read back what actually happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.refresh() }
    }

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.value(key) }, set: { self.set(key, $0) })
    }

    func toggle(_ key: String) -> Binding<Bool> {
        Binding(get: { self.value(key) == "on" }, set: { self.set(key, $0 ? "on" : "off") })
    }
}

final class HubModel: ObservableObject {
    let store: Store
    let settings: SettingsModel
    let hubSettings: HubSettings
    var notes: NotesViewModel?
    var agents: AgentsViewModel?

    @Published var page: HubPage = .dictation
    @Published var userName: String
    @Published var nameDraft = ""
    @Published var search = ""
    @Published var history: [Store.HistoryEntry] = []
    @Published var insights = UsageInsights()
    @Published var status = "Ready"

    var recordCall: () -> Void = {}
    var openSetup: () -> Void = {}

    /// Three Sprigs in the greeting.
    let heroSprigs = [SprigEngine(state: "idle"), SprigEngine(state: "listening"), SprigEngine(state: "writing")]

    init(store: Store, hubSettings: HubSettings) {
        self.store = store
        self.hubSettings = hubSettings
        settings = SettingsModel(store: store)
        userName = store.setting("user.name") ?? ""
    }

    var needsName: Bool { userName.isEmpty }

    func saveName() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.setSetting("user.name", name)
        userName = name
        Log.write("hub: name set")
    }

    func reload() {
        history = store.recentHistory(limit: 300)
        insights = UsageInsights.compute(store.usageRows(), watched: store.insightRows())
        settings.reload()
        hubSettings.refresh()
        notes?.taker.reloadNotes()
    }

    var filteredHistory: [Store.HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history }
        return history.filter { $0.cleaned.lowercased().contains(q) || $0.raw.lowercased().contains(q) }
    }

    /// History grouped as Today / Yesterday / date, newest first.
    var groupedHistory: [(day: String, entries: [Store.HistoryEntry])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        var groups: [(String, [Store.HistoryEntry])] = []
        for entry in filteredHistory {
            let day: String
            if calendar.isDateInToday(entry.created) { day = "Today" }
            else if calendar.isDateInYesterday(entry.created) { day = "Yesterday" }
            else { day = formatter.string(from: entry.created) }
            if groups.last?.0 == day { groups[groups.count - 1].1.append(entry) } else { groups.append((day, [entry])) }
        }
        return groups.map { (day: $0.0, entries: $0.1) }
    }

    func copy(_ entry: Store.HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.cleaned, forType: .string)
    }

    func delete(_ entry: Store.HistoryEntry) {
        store.deleteHistory(id: entry.id)
        history.removeAll { $0.id == entry.id }
    }
}

// MARK: - Window

final class HubWindowController: NSObject, NSWindowDelegate {
    let model: HubModel
    private var window: NSWindow?

    init(model: HubModel) {
        self.model = model
    }

    func show(page: HubPage? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Saywell"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Hub.window)
            w.minSize = NSSize(width: 960, height: 620)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: HubView(model: model))
            w.center()
            w.setFrameAutosaveName("SaywellHub")
            window = w
        }
        if let page { model.page = page }
        model.reload()
        // In the Dock and ⌘-Tab while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Log.write("hub: shown (\(model.needsName ? "name step" : model.page.rawValue)) visible=\(window?.isVisible == true) frame=\(window.map { NSStringFromRect($0.frame) } ?? "-")")
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar app.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Style

enum Hub {
    static let window = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let card = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white
    static let dim = Color.white.opacity(0.55)
    static let accent = Color(red: 0.96, green: 0.62, blue: 0.33)
}

struct HubCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Hub.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Hub.stroke))
    }
}

// MARK: - Root

struct HubView: View {
    @ObservedObject var model: HubModel

    var body: some View {
        Group {
            if model.needsName {
                NameStep(model: model)
            } else {
                HStack(spacing: 0) {
                    HubSidebar(model: model)
                        .frame(width: 220)
                    HubContent(model: model)
                        .padding(.vertical, 14)
                        .padding(.trailing, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Hub.window)
        .preferredColorScheme(.dark)
    }
}

/// First launch: "What should Sprig call you?"
struct NameStep: View {
    @ObservedObject var model: HubModel
    private let sprig = SprigEngine(state: "idle")

    var body: some View {
        VStack(spacing: 18) {
            SprigView(engine: sprig, scale: 0.24, ground: 0.9)
                .frame(width: 150, height: 150)
            Text("Hi, I'm Sprig").font(.system(size: 30, weight: .bold)).foregroundColor(Hub.text)
            Text("Saywell turns your voice into text and your calls into notes, all on this Mac.\nWhat should I call you?")
                .multilineTextAlignment(.center)
                .foregroundColor(Hub.dim)
            TextField("Your first name", text: $model.nameDraft, onCommit: model.saveName)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(12)
                .frame(width: 280)
                .background(RoundedRectangle(cornerRadius: 10).fill(Hub.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Hub.stroke))
            Button(action: model.saveName) {
                Text("Continue").font(.system(size: 14, weight: .semibold)).foregroundColor(.black)
                    .padding(.horizontal, 28).padding(.vertical, 10)
                    .background(Capsule().fill(Hub.accent))
            }
            .buttonStyle(.plain)
            .disabled(model.nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { sprig.play("jump") }
    }
}

// MARK: - Sidebar

struct HubSidebar: View {
    @ObservedObject var model: HubModel
    private let logo = SprigEngine(state: "idle")

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                SprigView(engine: logo, scale: 0.3, ground: 0.95).frame(width: 30, height: 30)
                Text("Saywell").font(.system(size: 17, weight: .bold)).foregroundColor(Hub.text)
            }
            .padding(.horizontal, 12)
            .padding(.top, 40)
            .padding(.bottom, 12)
            section("FLOW")
            ForEach(HubPage.flow) { row($0) }
            section("SAYWELL").padding(.top, 10)
            ForEach(HubPage.app) { row($0) }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(model.status).font(.system(size: 11)).foregroundColor(Hub.dim).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Hub.card))
            .padding(10)
        }
        .padding(.horizontal, 4)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .bold)).foregroundColor(Hub.dim)
            .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func row(_ page: HubPage) -> some View {
        Button { model.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).frame(width: 18)
                Text(page.title)
                Spacer()
            }
            .font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
            .foregroundColor(model.page == page ? Hub.text : Hub.text.opacity(0.75))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(model.page == page ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Content

struct HubContent: View {
    @ObservedObject var model: HubModel

    var body: some View {
        Group {
            switch model.page {
            case .dictation: DictationPage(model: model)
            case .notetaker:
                if let notes = model.notes {
                    page { NotesTab(model: notes, taker: notes.taker, record: model.recordCall) }
                }
            case .statistics: page { InsightsTab(model: model.settings) }
            case .dictionary: page { DictionaryTab(model: model.settings) }
            case .snippets: page { SnippetsTab(model: model.settings) }
            case .styles: page { ModesTab(model: model.settings) }
            case .general: GeneralPage(settings: model.hubSettings, model: model)
            case .agents:
                if let agents = model.agents { page { AgentsTab(model: agents, center: agents.center) } }
            case .privacy: page { PrivacyTab(model: model.settings) }
            case .training: page { TrainingTab(model: model.settings) }
            case .shortcuts: ShortcutsPage(settings: model.hubSettings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Hub.panel))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Hub.stroke))
    }

    /// An existing settings view, with the page title above it.
    private func page<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.page.title).font(.system(size: 22, weight: .bold)).foregroundColor(Hub.text)
            content()
        }
        .padding(24)
    }
}

// MARK: - Dictation (home)

struct DictationPage: View {
    @ObservedObject var model: HubModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroCard(model: model)
                HStack(alignment: .top, spacing: 18) {
                    HistoryColumn(model: model)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 18) {
                        StatsCard(insights: model.insights)
                        NotetakerCard { model.page = .notetaker }
                    }
                    .frame(width: 270)
                }
            }
            .padding(24)
        }
    }
}

struct HeroCard: View {
    @ObservedObject var model: HubModel

    var body: some View {
        ZStack(alignment: .leading) {
            HeroBackground()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hello \(model.userName)").font(.system(size: 30, weight: .bold)).foregroundColor(Hub.text)
                    Text(holdHint).font(.system(size: 14)).foregroundColor(Hub.text.opacity(0.75))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Button(action: model.recordCall) {
                        HStack(spacing: 8) {
                            Circle().fill(Color.black).frame(width: 8, height: 8)
                            Text("Record a call").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Hub.accent))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 26) {
                    ForEach(Array(model.heroSprigs.enumerated()), id: \.offset) { i, sprig in
                        SprigView(engine: sprig, scale: 0.27, ground: 0.95, pointer: { HeroCard.pointer() })
                            .frame(width: [130, 104, 96][i], height: [130, 104, 96][i])
                    }
                }
                .frame(minWidth: 300)
            }
            .padding(26)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Hub.stroke))
    }

    private var holdHint: String {
        let key = HoldKey(rawValue: model.hubSettings.value("holdKey")) ?? .fn
        return key == .off ? "Press ⌃⌥D anywhere, speak, press it again: it's typed."
                           : "Hold \(key.label) anywhere, speak, let go: it's typed.\nTap it twice for hands-free."
    }

    /// The eyes follow the pointer across the window.
    static func pointer() -> (Double, Double) {
        guard let frame = NSApp.keyWindow?.frame else { return (0, 0) }
        let m = NSEvent.mouseLocation
        let anchor = CGPoint(x: frame.maxX - 220, y: frame.maxY - 140)
        return (tanh((m.x - anchor.x) / 300), tanh(-(m.y - anchor.y) / 220))
    }
}

/// A warm gradient with drifting specks, like a night sky over a sunrise.
struct HeroBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.06, green: 0.05, blue: 0.05), Color(red: 0.28, green: 0.16, blue: 0.07)]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: size.height)))
                context.fill(Path(ellipseIn: CGRect(x: size.width * 0.55, y: size.height * 0.2, width: size.width * 0.6, height: size.height * 1.4)),
                             with: .radialGradient(Gradient(colors: [Hub.accent.opacity(0.22), .clear]),
                                                   center: CGPoint(x: size.width * 0.85, y: size.height * 0.9), startRadius: 0, endRadius: size.width * 0.4))
                let t = timeline.date.timeIntervalSinceReferenceDate
                for i in 0..<46 {
                    let seed = Double(i) * 12.9898
                    let x = (sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let y = (sin(seed * 1.7) * 24634.6345).truncatingRemainder(dividingBy: 1)
                    let px = abs(x) * size.width
                    let py = (abs(y) * size.height - t * (3 + Double(i % 5))).truncatingRemainder(dividingBy: size.height)
                    let alpha = 0.25 + 0.35 * abs(sin(t * 0.8 + seed))
                    let r = 0.8 + Double(i % 3) * 0.5
                    context.fill(Path(ellipseIn: CGRect(x: px, y: py < 0 ? py + size.height : py, width: r * 2, height: r * 2)),
                                 with: .color(Hub.accent.opacity(alpha)))
                }
            }
        }
    }
}

struct HistoryColumn: View {
    @ObservedObject var model: HubModel

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("HISTORY").font(.system(size: 11, weight: .bold)).foregroundColor(Hub.dim)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(Hub.dim)
                    TextField("Search dictations", text: $model.search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(width: 230)
                .background(RoundedRectangle(cornerRadius: 8).fill(Hub.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Hub.stroke))
            }
            if model.groupedHistory.isEmpty {
                HubCard {
                    Text(model.search.isEmpty ? "Your dictations appear here. Hold the key anywhere and speak."
                                              : "No dictation matches \"\(model.search)\".")
                        .foregroundColor(Hub.dim)
                }
            }
            ForEach(model.groupedHistory, id: \.day) { group in
                Text(group.day).font(.system(size: 12, weight: .semibold)).foregroundColor(Hub.text.opacity(0.8))
                    .padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(group.entries) { entry in
                        HistoryRow(entry: entry, time: Self.time.string(from: entry.created), model: model)
                        if entry.id != group.entries.last?.id { Divider().background(Hub.stroke) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(Hub.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Hub.stroke))
            }
        }
    }
}

struct HistoryRow: View {
    let entry: Store.HistoryEntry
    let time: String
    let model: HubModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(time).font(.system(size: 11)).foregroundColor(Hub.dim)
                Text(InsightsTab.appName(entry.app))
                    .font(.system(size: 10, weight: .medium)).foregroundColor(Hub.text.opacity(0.7))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
            }
            .frame(width: 84, alignment: .leading)
            Text(entry.cleaned).font(.system(size: 13)).foregroundColor(Hub.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                iconButton("doc.on.doc", help: "Copy") { model.copy(entry) }
                iconButton("trash", help: "Delete") { model.delete(entry) }
            }
        }
        .padding(14)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundColor(Hub.dim)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct StatsCard: View {
    let insights: UsageInsights

    var body: some View {
        HubCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                stat("\(insights.wordsAllTime)", "words dictated")
                stat(insights.wordsPerMinute.map { "\(Int($0))" } ?? "–", "words/min")
                stat("\(insights.streakDays)", insights.streakDays == 1 ? "day in a row" : "days in a row")
                stat(InsightsTab.duration(minutes: insights.minutesSaved), "saved vs typing")
                Divider().background(Hub.stroke)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").foregroundColor(.green)
                    Text("Private and offline").font(.system(size: 13, weight: .semibold)).foregroundColor(.green)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(size: 28, weight: .bold)).foregroundColor(Hub.text)
            Text(label).font(.system(size: 13)).foregroundColor(Hub.dim)
        }
    }
}

struct NotetakerCard: View {
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
                Text("The Notetaker").font(.system(size: 15, weight: .bold)).foregroundColor(Hub.text)
                Text("Your calls transcribed person by person, cleaned up, with a summary, decisions and action items. No bot in the meeting.")
                    .font(.system(size: 12)).foregroundColor(Hub.dim)
                Button(action: open) {
                    Text("Open the Notetaker →").font(.system(size: 13, weight: .semibold)).foregroundColor(Hub.accent)
                }
                .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeroBackground().opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Hub.stroke))
    }
}

// MARK: - General (all settings)

struct GeneralPage: View {
    @ObservedObject var settings: HubSettings
    @ObservedObject var model: HubModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General").font(.system(size: 22, weight: .bold)).foregroundColor(Hub.text)
                group("You") {
                    row("Your name") {
                        TextField("Name", text: Binding(get: { model.userName }, set: {
                            model.userName = $0
                            model.store.setSetting("user.name", $0.isEmpty ? nil : $0)
                        }))
                        .frame(width: 220)
                    }
                    row("Permissions and first-run setup") { Button("Open Setup…", action: model.openSetup) }
                }
                group("Dictation") {
                    picker("Hold key to talk", "holdKey", HoldKey.allCases.map { ($0.rawValue, $0.label) })
                    picker("Speech recognizer", "recognizer", [("apple", "Apple (built in)"), ("parakeet", "Parakeet v3 (most accurate, 460 MB)")])
                    picker("Language", "language", settings.options("language"))
                    picker("Auto-stop hands-free after silence", "autoStop", [("0", "Off"), ("5", "5 s"), ("10", "10 s"), ("20", "20 s")])
                    toggle("Clean sentences while you talk", "streaming")
                    toggle("Keep the mic ready (catches the first word)", "keepMicReady")
                    toggle("Keep dictation on the clipboard", "keepClipboard")
                    toggle("Use names on screen for spelling", "screenNames")
                }
                group("AI cleanup") {
                    picker("Cleanup", "level", CleanupLevel.allCases.map { ($0.rawValue, $0.label) })
                    picker("Model", "engine", CleanupEngine.allCases.map { ($0.rawValue, $0.label) })
                    picker("Unload the local model when idle", "idleUnload", [("5", "After 5 min"), ("15", "After 15 min"), ("60", "After 1 hour"), ("0", "Never")])
                }
                group("Notetaker") {
                    picker("Auto-record meetings (Zoom, Teams, Webex)", "autoRecord", [("off", "Off"), ("ask", "Ask me in the notch"), ("always", "Always record")])
                }
                group("Look and sound") {
                    picker("Pill position", "pillPosition", PillPosition.allCases.map { ($0.rawValue, $0.label) })
                    toggle("Show Sprig", "showSprig")
                    toggle("Start and stop sounds", "sounds")
                    toggle("Pause music while dictating", "pauseMusic")
                }
            }
            .padding(24)
        }
        .onAppear { settings.refresh() }
    }

    private func group<V: View>(_ title: String, @ViewBuilder _ rows: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).foregroundColor(Hub.dim)
            HubCard { VStack(alignment: .leading, spacing: 10) { rows() } }
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ control: () -> V) -> some View {
        HStack {
            Text(label).foregroundColor(Hub.text)
            Spacer()
            control()
        }
    }

    private func picker(_ label: String, _ key: String, _ options: [(value: String, label: String)]) -> some View {
        row(label) {
            Picker("", selection: settings.binding(key)) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .frame(width: 260)
        }
    }

    private func toggle(_ label: String, _ key: String) -> some View {
        row(label) { Toggle("", isOn: settings.toggle(key)).labelsHidden().toggleStyle(.switch) }
    }
}

// MARK: - Shortcuts

struct ShortcutsPage: View {
    @ObservedObject var settings: HubSettings

    var body: some View {
        let key = (HoldKey(rawValue: settings.value("holdKey")) ?? .fn).label
        VStack(alignment: .leading, spacing: 14) {
            Text("Shortcuts").font(.system(size: 22, weight: .bold)).foregroundColor(Hub.text)
            HubCard {
                VStack(alignment: .leading, spacing: 10) {
                    line("Hold \(key)", "Dictate while held; let go to type it")
                    line("Tap \(key) twice", "Hands-free; tap once more to finish")
                    line("Esc", "Cancel the dictation")
                    line("⌃⌥D", "Start or stop dictation")
                    line("⌃⌥Z", "Replace the last insert with what you said (raw)")
                    line("⌃⌘V", "Paste the last dictation again")
                    line("Select text, then dictate", "\"Make this more formal\", \"translate to Spanish\"…")
                }
            }
            Text("Change the hold key in General.").font(.caption).foregroundColor(Hub.dim)
        }
        .padding(24)
    }

    private func line(_ keys: String, _ what: String) -> some View {
        HStack {
            Text(keys).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(Hub.text)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                .frame(width: 210, alignment: .leading)
            Text(what).foregroundColor(Hub.dim)
        }
    }
}
