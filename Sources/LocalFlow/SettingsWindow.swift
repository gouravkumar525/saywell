import AppKit
import Contacts
import LocalFlowCore
import SwiftUI

/// Dictionary, learned corrections, snippets, and history.
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: Store
    private var model: SettingsModel?
    /// C5: the Notes tab.
    var notes: NotesViewModel?
    var agents: AgentsViewModel?
    var record: () -> Void = {}

    init(store: Store) { self.store = store }

    func show(tab: String? = nil) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Saywell"
            window.isReleasedWhenClosed = false
            let model = SettingsModel(store: store)
            self.model = model
            window.contentView = NSHostingView(rootView: SettingsView(model: model, notes: notes, agents: agents, record: { [weak self] in self?.record() }))
            window.center()
            self.window = window
        }
        if let tab { model?.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsModel: ObservableObject {
    let store: Store
    @Published var terms: [String] = []
    @Published var tab = "insights"
    @Published var candidates: [Store.Candidate] = []
    @Published var snippets: [(trigger: String, expansion: String)] = []
    @Published var history: [Store.HistoryEntry] = []
    // Form drafts live here: @State is a macro this toolchain can't expand.
    @Published var newTerm = ""
    @Published var trigger = ""
    @Published var expansion = ""
    @Published var samples: [Store.Sample] = []
    @Published var exportableCount = 0
    @Published var captureTraining = true {
        didSet { store.setSetting("training.capture", captureTraining ? "on" : "off") }
    }
    /// 0 = keep forever.
    @Published var retentionDays = SettingsModel.defaultRetentionDays {
        didSet { store.setSetting("training.retention.days", String(retentionDays)) }
    }

    /// Privacy tab: comma-separated bundle IDs never stored.
    @Published var denyApps = ""
    @Published var confirmDelete = false
    @Published var contactsStatus = ""

    /// Modes tab (B9): the saved modes and the draft being edited.
    @Published var modes: [WritingMode] = []
    @Published var modeName = ""
    @Published var modeApps = ""
    @Published var modeWebsites = ""
    @Published var modeTrigger = ""
    /// "" = inherit.
    @Published var modeLevel = ""
    @Published var modeStyle = ""
    @Published var modeInstructions = ""

    /// Insights tab (B15).
    @Published var insights = UsageInsights()

    static let defaultRetentionDays = 365
    static let retentionChoices = [30, 90, 365, 0]

    /// Retention from settings; nil means keep forever.
    static func retentionDays(in store: Store) -> Int? {
        let days = Int(store.setting("training.retention.days") ?? "") ?? defaultRetentionDays
        return days > 0 ? days : nil
    }

    init(store: Store) {
        self.store = store
        captureTraining = store.setting("training.capture") != "off"
        retentionDays = SettingsModel.retentionDays(in: store) ?? 0
        denyApps = PrivacyPolicy.denyApps(in: store).joined(separator: ", ")
        reload()
    }

    func saveDenyApps() {
        PrivacyPolicy.setDenyApps(denyApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, in: store)
        denyApps = PrivacyPolicy.denyApps(in: store).joined(separator: ", ")
    }

    func deleteAll() {
        store.deleteAllHistory()
        confirmDelete = false
        reload()
    }

    /// G6 opt-in: first and last names from Contacts become dictionary terms.
    func importContacts() {
        let contacts = CNContactStore()
        contacts.requestAccess(for: .contacts) { granted, _ in
            guard granted else {
                DispatchQueue.main.async { self.contactsStatus = "Contacts access denied" }
                return
            }
            var names = Set<String>()
            let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor,
                                                              CNContactFamilyNameKey as CNKeyDescriptor])
            try? contacts.enumerateContacts(with: request) { contact, _ in
                for name in [contact.givenName, contact.familyName] where name.count >= 3 { names.insert(name) }
            }
            DispatchQueue.main.async {
                let before = Set(self.store.dictionaryTerms())
                for name in names { self.store.addTerm(name, source: "contacts") }
                self.contactsStatus = "Added \(names.subtracting(before).count) names from Contacts"
                self.reload()
            }
        }
    }

    func saveModeDraft() {
        let name = modeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        func list(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let trigger = modeTrigger.trimmingCharacters(in: .whitespaces)
        let mode = WritingMode(name: name, apps: list(modeApps), websites: list(modeWebsites),
                               trigger: trigger.isEmpty ? nil : trigger,
                               level: CleanupLevel(rawValue: modeLevel), style: AppStyle(rawValue: modeStyle),
                               instructions: modeInstructions.isEmpty ? nil : modeInstructions)
        var all = WritingMode.decodeList(store.setting("modes")).filter { $0.name != name }
        all.append(mode)
        store.setSetting("modes", WritingMode.encodeList(all))
        clearModeDraft()
        reload()
    }

    func editMode(_ mode: WritingMode) {
        modeName = mode.name
        modeApps = mode.apps.joined(separator: ", ")
        modeWebsites = mode.websites.joined(separator: ", ")
        modeTrigger = mode.trigger ?? ""
        modeLevel = mode.level?.rawValue ?? ""
        modeStyle = mode.style?.rawValue ?? ""
        modeInstructions = mode.instructions ?? ""
    }

    func deleteMode(_ mode: WritingMode) {
        let all = WritingMode.decodeList(store.setting("modes")).filter { $0.name != mode.name }
        store.setSetting("modes", WritingMode.encodeList(all))
        reload()
    }

    func clearModeDraft() {
        modeName = ""; modeApps = ""; modeWebsites = ""; modeTrigger = ""
        modeLevel = ""; modeStyle = ""; modeInstructions = ""
    }

    /// Adds the bundle ID of the app you most recently dictated into (not already listed).
    func addRecentApp() {
        let ids = store.recentHistory().map(\.app).filter { !$0.isEmpty && $0 != "?" }
        guard let id = ids.first(where: { !modeApps.contains($0) }) else { return }
        modeApps = modeApps.isEmpty ? id : modeApps + ", " + id
    }

    func reload() {
        modes = WritingMode.decodeList(store.setting("modes"))
        insights = UsageInsights.compute(store.usageRows(), watched: store.insightRows())
        terms = store.dictionaryTerms()
        candidates = store.candidates()
        snippets = store.snippets().map { ($0.key, $0.value) }.sorted { $0.trigger < $1.trigger }
        history = store.recentHistory()
        samples = store.recentSamples(limit: 100)
        exportableCount = store.trainingSampleCount()
    }

    func label(_ sample: Store.Sample, _ label: String) {
        // Clicking the active label again clears it.
        store.setSampleLabel(id: sample.id, label: sample.label == label ? nil : label)
        reload()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var notes: NotesViewModel?
    var agents: AgentsViewModel?
    var record: () -> Void = {}

    var body: some View {
        TabView(selection: $model.tab) {
            InsightsTab(model: model).tabItem { Text("Insights") }.tag("insights")
            if let notes {
                NotesTab(model: notes, taker: notes.taker, record: record).tabItem { Text("Notes") }.tag("notes")
            }
            if let agents {
                AgentsTab(model: agents, center: agents.center).tabItem { Text("Agents") }.tag("agents")
            }
            DictionaryTab(model: model).tabItem { Text("Dictionary") }.tag("dictionary")
            SnippetsTab(model: model).tabItem { Text("Snippets") }.tag("snippets")
            ModesTab(model: model).tabItem { Text("Modes") }.tag("modes")
            HistoryTab(model: model).tabItem { Text("History") }.tag("history")
            TrainingTab(model: model).tabItem { Text("Training") }.tag("training")
            PrivacyTab(model: model).tabItem { Text("Privacy") }.tag("privacy")
        }
        .padding()
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { model.reload() }
    }
}

/// B15: local usage stats, headlined by the no-edit rate.
struct InsightsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let i = model.insights
        VStack(alignment: .leading, spacing: 10) {
            Text("Computed on this Mac from word counts of your dictations; nothing is sent anywhere.")
                .font(.callout).foregroundColor(.secondary)
            HStack(spacing: 22) {
                stat("No-edit rate", noEditText(i))
                stat("Words today", "\(i.wordsToday)")
                stat("This week", "\(i.wordsThisWeek)")
                stat("All time", "\(i.wordsAllTime)")
            }
            HStack(spacing: 22) {
                stat("Pace", i.wordsPerMinute.map { String(format: "%.0f wpm", $0) } ?? "–")
                stat("Removed by cleanup", "\(i.wordsRemoved) words")
                stat("Streak", "\(i.streakDays) day\(i.streakDays == 1 ? "" : "s")")
                stat("Time saved", Self.duration(minutes: i.minutesSaved))
                stat("Dictations", "\(i.dictations)")
            }
            Text("No-edit rate by week (dictations you didn't fix afterwards)").font(.headline)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(i.weeks, id: \.start) { week in
                    VStack(spacing: 2) {
                        Text(week.noEditRate.map { String(format: "%.0f%%", $0 * 100) } ?? "–").font(.caption2)
                        Rectangle()
                            .fill(Color.accentColor.opacity(week.noEditRate == nil ? 0.15 : 0.8))
                            .frame(width: 34, height: max(2, CGFloat(week.noEditRate ?? 0) * 70))
                        Text(Self.weekFormatter.string(from: week.start)).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 100, alignment: .bottom)
            Text("Top apps").font(.headline)
            ForEach(i.topApps, id: \.app) { entry in
                HStack {
                    Text(Self.appName(entry.app))
                    Spacer()
                    Text("\(entry.words) words").foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    /// "1 h 25 min", "12 min", "< 1 min" (typing at 45 wpm vs. talking).
    static func duration(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 1 { return "< 1 min" }
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    private static let weekFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    private func noEditText(_ i: UsageInsights) -> String {
        let watched = i.weeks.suffix(4).reduce(0) { $0 + $1.watched }
        let rate = model.store.metrics(days: 28).noEditRate
        return rate.map { String(format: "%.0f%% (%d)", $0 * 100, watched) } ?? "–"
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title3).bold()
            Text(title).font(.caption).foregroundColor(.secondary)
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// B9: modes by app, website, or spoken trigger, with custom instructions.
struct ModesTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A mode applies in the listed apps or websites, or when you start a dictation with its trigger (\"email mode, hi John…\"). Trigger → website → app.")
                .font(.callout).foregroundColor(.secondary)
            List {
                ForEach(model.modes) { mode in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(mode.name).bold()
                            Text(summary(mode)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { model.editMode(mode) }.buttonStyle(.borderless)
                        Button("Delete") { model.deleteMode(mode) }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 90)
            HStack {
                TextField("Name", text: $model.modeName)
                TextField("Trigger words (optional)", text: $model.modeTrigger)
            }
            HStack {
                TextField("Apps: bundle IDs, comma-separated", text: $model.modeApps)
                Button("Add Last Used App", action: model.addRecentApp)
            }
            TextField("Websites: e.g. mail.google.com/mail, github.com", text: $model.modeWebsites)
            HStack {
                Picker("Level", selection: $model.modeLevel) {
                    Text("Inherit").tag("")
                    ForEach(CleanupLevel.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Style", selection: $model.modeStyle) {
                    Text("Inherit").tag("")
                    ForEach(AppStyle.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
            }
            Text("Instructions (\(model.modeInstructions.count)/\(WritingMode.maxInstructions)), formatting and tone only, e.g. \"Use British spelling\" or \"One sentence per line\" (cleanup still never adds content)")
                .font(.caption).foregroundColor(.secondary)
            TextEditor(text: $model.modeInstructions)
                .frame(height: 50)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Save Mode", action: model.saveModeDraft)
                    .disabled(model.modeName.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.modeInstructions.count > WritingMode.maxInstructions)
                Button("Clear", action: model.clearModeDraft)
            }
        }
    }

    private func summary(_ m: WritingMode) -> String {
        var parts: [String] = []
        if let t = m.trigger { parts.append("says \"\(t)\"") }
        if !m.websites.isEmpty { parts.append(m.websites.joined(separator: ", ")) }
        if !m.apps.isEmpty { parts.append(m.apps.joined(separator: ", ")) }
        if let l = m.level { parts.append(l.rawValue) }
        if let s = m.style { parts.append(s.rawValue) }
        if let i = m.cleanInstructions { parts.append("“\(i.prefix(40))”") }
        return parts.joined(separator: " · ")
    }
}

struct DictionaryTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Names and terms to spell exactly. They're used as hints for speech recognition and for cleanup.")
                .font(.callout).foregroundColor(.secondary)
            HStack {
                TextField("Add a word or name", text: $model.newTerm).onSubmit(add)
                Button("Add", action: add).disabled(model.newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Import Contacts…", action: model.importContacts)
            }
            if !model.contactsStatus.isEmpty {
                Text(model.contactsStatus).font(.caption).foregroundColor(.secondary)
            }
            List {
                ForEach(model.terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button("Remove") { model.store.removeTerm(term); model.reload() }
                            .buttonStyle(.borderless)
                    }
                }
            }
            if !model.candidates.isEmpty {
                Text("Auto-learned (pending, \(model.candidates.count)): corrections you made after dictating. Names and jargon are added after one fix; ordinary words after \(Store.promotionThreshold).")
                    .font(.callout).foregroundColor(.secondary)
                List(model.candidates) { c in
                    HStack {
                        Text("heard \"\(c.original)\" → \"\(c.corrected)\"")
                        Spacer()
                        Text("×\(c.count)").foregroundColor(.secondary)
                        Button("Accept") { model.store.acceptCandidate(original: c.original, corrected: c.corrected); model.reload() }
                            .buttonStyle(.borderless)
                        Button("Reject") { model.store.rejectCandidate(original: c.original, corrected: c.corrected); model.reload() }
                            .buttonStyle(.borderless)
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func add() {
        model.store.addTerm(model.newTerm)
        model.newTerm = ""
        model.reload()
    }
}

struct SnippetsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Say the trigger phrase while dictating and it's replaced with the expansion, word for word.")
                .font(.callout).foregroundColor(.secondary)
            HStack {
                TextField("Trigger (e.g. my email)", text: $model.trigger).frame(width: 180)
                TextField("Expansion", text: $model.expansion)
                Button("Save") {
                    model.store.setSnippet(trigger: model.trigger, expansion: model.expansion)
                    model.trigger = ""; model.expansion = ""
                    model.reload()
                }
                .disabled(model.trigger.trimmingCharacters(in: .whitespaces).isEmpty || model.expansion.isEmpty)
            }
            List {
                ForEach(model.snippets, id: \.trigger) { s in
                    HStack(alignment: .top) {
                        Text(s.trigger).bold().frame(width: 160, alignment: .leading)
                        Text(s.expansion).lineLimit(2)
                        Spacer()
                        Button("Remove") { model.store.removeSnippet(trigger: s.trigger); model.reload() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

struct HistoryTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        List(model.history) { entry in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.created, style: .time).foregroundColor(.secondary)
                    Text(entry.app).foregroundColor(.secondary)
                    Spacer()
                    Text(entry.method).font(.caption).foregroundColor(.secondary)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.cleaned, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
                Text(entry.cleaned).textSelection(.enabled)
                if entry.raw != entry.cleaned {
                    Text("heard: \(entry.raw)").font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct TrainingTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Save dictations for training", isOn: $model.captureTraining)
                Spacer()
                Picker("Keep for", selection: $model.retentionDays) {
                    ForEach(SettingsModel.retentionChoices, id: \.self) { days in
                        Text(days == 0 ? "Forever" : "\(days) days").tag(days)
                    }
                }
                .frame(width: 170)
            }
            Text("\(model.exportableCount) samples ready to export. Stored only on this Mac; password fields are never saved. Older samples are removed at launch.")
                .font(.callout).foregroundColor(.secondary)
            List(model.samples) { sample in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(sample.created, style: .time).foregroundColor(.secondary)
                        Text(sample.engine).font(.caption).foregroundColor(.secondary)
                        Text(acceptedLabel(sample)).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        ForEach(Store.sampleLabels, id: \.self) { label in
                            Button(label.capitalized) { model.label(sample, label) }
                                .buttonStyle(.borderless)
                                .fontWeight(sample.label == label ? .bold : .regular)
                                .foregroundColor(sample.label == label ? .accentColor : .secondary)
                        }
                    }
                    Text(sample.inserted).textSelection(.enabled)
                    if sample.edited, let final = sample.finalText {
                        Text("edited to: \(final)").font(.caption).foregroundColor(.orange).lineLimit(3)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func acceptedLabel(_ s: Store.Sample) -> String {
        switch s.accepted {
        case .some(true): return "accepted"
        case .some(false): return "rejected\(s.rejectReason.map { ": \($0)" } ?? "")"
        case .none: return "rules only"
        }
    }
}

struct PrivacyTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Saywell keeps").font(.headline)
            Text("""
                • Dictation audio is never written to disk: it lives in memory only while you speak.                 A call you record (Notes) is written to disk only until its transcript is ready, then deleted.
                • Speech recognition and AI cleanup run on this Mac. The only network use is a model \
                download you approve (from huggingface.co).
                • Context comes from the text field itself (up to 400 characters before the cursor, \
                held in memory) — never screenshots.
                • History and training samples stay in ~/Library/Application Support/Saywell. \
                Password fields and the apps below are never stored.
                """)
                .font(.callout).foregroundColor(.secondary)
            Text("Never store dictations from these apps (bundle IDs, comma-separated):")
            HStack {
                TextField("com.1password.1password, …", text: $model.denyApps).onSubmit(model.saveDenyApps)
                Button("Save", action: model.saveDenyApps)
            }
            Divider()
            HStack {
                if model.confirmDelete {
                    Text("Delete all history and training samples? This can't be undone.").foregroundColor(.red)
                    Button("Delete Everything", action: model.deleteAll)
                    Button("Cancel") { model.confirmDelete = false }
                } else {
                    Button("Delete All History…") { model.confirmDelete = true }
                    Text("\(model.history.count) recent entries, \(model.samples.count) samples")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }
}
