import SwiftUI
import AppKit

struct ModelCacheApp: App {
    @StateObject private var vm = ViewModel()

    var body: some Scene {
        WindowGroup("Model Cache Manager") {
            ContentView()
                .environmentObject(vm)
                .frame(minWidth: 1080, minHeight: 640)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) { AboutMenuItem() }
        }

        Window("About Model Cache Manager", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

enum AppInfo {
    static let name = "Model Cache Manager"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static let repo = URL(string: "https://github.com/fredriklindstrom/model-cache-manager")!
    static let license = URL(string: "https://github.com/fredriklindstrom/model-cache-manager/blob/main/LICENSE")!
}

struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About \(AppInfo.name)") { openWindow(id: "about") }
    }
}

struct AboutView: View {
    private var logo: NSImage {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png"), let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
                .frame(width: 260)
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
            Text("Version \(AppInfo.version)")
                .foregroundStyle(.secondary)
            Text("See what's in your Hugging Face model cache, delete the models you don't need, and auto-delete the ones you haven't used, without breaking files other models share.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                Text("© 2026 Fredrik Lindstrom")
                Text("Licensed under the Apache License, Version 2.0")
            }
            .font(.callout)
            HStack(spacing: 18) {
                LinkText(title: "Source on GitHub", url: AppInfo.repo)
                LinkText(title: "License", url: AppInfo.license)
            }
            Text("Not affiliated with or endorsed by Hugging Face.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 400)
    }
}

@MainActor
final class ViewModel: ObservableObject {
    @Published var models: [CachedModel] = []
    @Published var uniqueBytes: Int64 = 0
    @Published var selection = Set<CachedModel.ID>()
    @Published var sortOrder = [KeyPathComparator(\CachedModel.exclusiveBytes, order: .reverse)]
    @Published var scanning = false
    @Published var state = Store.load()
    @Published var trackingOn = Agent.isInstalled
    @Published var logLines: [String] = []
    @Published var search = ""
    @Published var message: String?

    init() {
        if trackingOn { try? Agent.install() }   // re-point the agent if the app was moved
        refresh()
    }

    var visible: [CachedModel] {
        let q = search.lowercased()
        return models.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.note.lowercased().contains(q) }
            .sorted(using: sortOrder)
    }
    var selected: [CachedModel] { models.filter { selection.contains($0.id) } }
    var deletable: [CachedModel] { selected.filter { !$0.isLocked } }
    var autoCandidates: [CachedModel] { Agent.candidates(models, state) }
    var freeBytes: Int64 {
        let v = try? CacheScanner.cacheRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func refresh() {
        scanning = true
        let st = Store.load()
        Task.detached(priority: .userInitiated) {
            let res = CacheScanner.scan(state: st)
            let newState = Store.update { Tracker.record(res.models, into: &$0) }
            let merged = Tracker.merge(res.models, newState)
            await MainActor.run {
                self.state = newState
                self.models = merged
                self.uniqueBytes = res.uniqueBytes
                self.selection = self.selection.intersection(Set(merged.map(\.id)))
                self.logLines = Store.recentLog(300)
                self.scanning = false
            }
        }
    }

    private func reloadState() {
        state = Store.load()
        models = Tracker.merge(models, state)
    }

    func setExcluded(_ id: String, _ on: Bool) {
        Store.update { if on { $0.excluded.insert(id) } else { $0.excluded.remove(id) } }
        Store.log("\(on ? "Excluded" : "Re-included") \(id) \(on ? "from" : "in") auto-delete")
        reloadState()
    }

    func setNote(_ id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (state.notes[id] ?? "") != t else { return }
        Store.update { $0.notes[id] = t.isEmpty ? nil : t }
        reloadState()
    }

    func updateSettings(_ change: @escaping (inout Settings) -> Void) {
        Store.update { change(&$0.settings) }
        reloadState()
    }

    func setTracking(_ on: Bool) {
        do {
            if on { try Agent.install() } else {
                Agent.uninstall()
                updateSettings { $0.autoDeleteEnabled = false }
            }
            Store.log(on ? "Background usage tracking switched on" : "Background usage tracking switched off")
        } catch { message = "Couldn't change background tracking: \(error.localizedDescription)" }
        trackingOn = Agent.isInstalled
        logLines = Store.recentLog(300)
    }

    func deleteSelected() {
        let targets = deletable
        let toTrash = state.settings.moveToTrash
        scanning = true
        Task.detached(priority: .userInitiated) {
            var freed: Int64 = 0
            var failed: [String] = []
            for m in targets {
                do {
                    freed += try Deleter.delete(m, toTrash: toTrash)
                    Store.log("Deleted \(m.id) (\(formatBytes(m.exclusiveBytes))) \(toTrash ? "to Trash" : "permanently")")
                } catch {
                    failed.append("\(m.name): \(error.localizedDescription)")
                    Store.log("Delete failed for \(m.id): \(error.localizedDescription)")
                }
            }
            let freedTotal = freed, failures = failed
            await MainActor.run {
                var text = "\(toTrash ? "Moved to Trash" : "Deleted"): \(targets.count - failures.count) model(s), \(formatBytes(freedTotal))."
                if toTrash { text += " Empty the Trash to free the space." }
                if !failures.isEmpty { text += "\nFailed: " + failures.joined(separator: "; ") }
                self.message = text
                self.selection.removeAll()
                self.refresh()
            }
        }
    }

    func applyAutoNow() {
        scanning = true
        Task.detached(priority: .userInitiated) {
            let done = Agent.runOnce(forceDelete: true)
            await MainActor.run {
                self.message = done.isEmpty ? "Nothing to delete." : "Auto-delete removed \(done.count) model(s)."
                self.refresh()
            }
        }
    }

    func autoStatus(_ m: CachedModel) -> String {
        if m.isLocked { return "Locked" }
        if m.excluded { return "Kept" }
        let due = m.autoClock.addingTimeInterval(Double(state.settings.days) * 86_400)
        if due <= Date() { return "Due now" }
        let days = Int(ceil(due.timeIntervalSinceNow / 86_400))
        return "In \(days) day\(days == 1 ? "" : "s")" + (m.inGracePeriod ? " · tracking" : "")
    }
}

struct ContentView: View {
    @EnvironmentObject var vm: ViewModel
    @State private var confirmDelete = false
    @State private var confirmAuto = false

    var body: some View {
        VStack(spacing: 0) {
            table
            Divider()
            HStack(alignment: .top, spacing: 12) {
                autoPanel.frame(maxWidth: .infinity)
                activityPanel.frame(width: 380)
            }
            .padding(12)
            Divider()
            footer
        }
        .searchable(text: $vm.search, prompt: "Filter by name or note")
        .toolbar {
            ToolbarItem {
                Button { vm.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(vm.scanning)
            }
            ToolbarItem {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .disabled(vm.deletable.isEmpty || vm.scanning)
                .help("Delete the selected models and the blobs only they use")
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(vm.state.settings.moveToTrash ? "Move to Trash" : "Delete Permanently", role: .destructive) { vm.deleteSelected() }
        } message: { Text(deleteMessage) }
        .confirmationDialog("Apply auto-delete now?", isPresented: $confirmAuto, titleVisibility: .visible) {
            Button("Delete \(vm.autoCandidates.count) model(s)", role: .destructive) { vm.applyAutoNow() }
        } message: {
            Text(vm.autoCandidates.map { "\($0.name)  \(formatBytes($0.exclusiveBytes))" }.joined(separator: "\n"))
        }
        .alert("Model Cache Manager", isPresented: Binding(get: { vm.message != nil }, set: { if !$0 { vm.message = nil } })) {
            Button("OK") { vm.message = nil }
        } message: { Text(vm.message ?? "") }
    }

    private var table: some View {
        Table(vm.visible, selection: $vm.selection, sortOrder: $vm.sortOrder) {
            TableColumn("Model", value: \.name) { m in
                HStack(spacing: 8) {
                    Image(systemName: m.isLocked ? "lock.fill" : (m.excluded ? "checkmark.shield.fill" : "shippingbox"))
                        .foregroundStyle(m.isLocked ? Color.orange : (m.excluded ? Color.green : Color.secondary))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).lineLimit(1)
                        Text(m.inUseReason ?? m.kind)
                            .font(.caption)
                            .foregroundStyle(m.isLocked ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 240, ideal: 300)

            TableColumn("Size", value: \.exclusiveBytes) { m in
                Text(formatBytes(m.exclusiveBytes)).monospacedDigit()
                    .help(m.totalBytes != m.exclusiveBytes ? "\(formatBytes(m.totalBytes)) including files shared with other models" : "")
            }
            .width(80)

            TableColumn("Last used", value: \.lastUsed) { m in
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.lastUsed == .distantPast ? "Never" : m.lastUsed.formatted(.relative(presentation: .named)))
                    Text(m.lastUsedSource).font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(130)

            TableColumn("Keep") { m in
                Toggle("", isOn: Binding(get: { m.excluded }, set: { vm.setExcluded(m.id, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Exclude from auto-delete")
            }
            .width(40)

            TableColumn("Auto-delete") { m in
                Text(vm.autoStatus(m))
                    .foregroundStyle(vm.autoStatus(m) == "Due now" ? Color.red : Color.secondary)
            }
            .width(130)

            TableColumn("Note") { m in
                NoteField(id: m.id, initial: m.note)
            }
            .width(min: 220, ideal: 320)
        }
    }

    private var autoPanel: some View {
        GroupBox("Auto-delete") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Track model usage in the background (checks every 15 minutes)",
                       isOn: Binding(get: { vm.trackingOn }, set: { vm.setTracking($0) }))
                HStack {
                    Toggle("Auto-delete models not used for",
                           isOn: Binding(get: { vm.state.settings.autoDeleteEnabled },
                                         set: { v in vm.updateSettings { $0.autoDeleteEnabled = v } }))
                        .disabled(!vm.trackingOn)
                    Stepper(value: Binding(get: { vm.state.settings.days },
                                           set: { v in vm.updateSettings { $0.days = v } }), in: 1...365) {
                        Text("\(vm.state.settings.days) days").monospacedDigit()
                    }
                    .fixedSize()
                }
                Picker("Deleted models go to", selection: Binding(get: { vm.state.settings.moveToTrash },
                                                                   set: { v in vm.updateSettings { $0.moveToTrash = v } })) {
                    Text("Trash (recoverable)").tag(true)
                    Text("Delete permanently").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                HStack {
                    let c = vm.autoCandidates
                    Text(c.isEmpty ? "Right now nothing is due for auto-delete."
                         : "Due now: \(c.count) model(s), \(formatBytes(c.reduce(0) { $0 + $1.exclusiveBytes })).")
                    Spacer()
                    Button("Apply now…") { confirmAuto = true }.disabled(c.isEmpty || vm.scanning)
                }
                Text("macOS doesn't record when model files are read, so \"last used\" is the latest of: download date, file access, the last time the background tracker saw a process using the model, and when tracking started. A model is never auto-deleted until it has been tracked for the full period. Models used by a launch agent or a running process are locked; ticked \"Keep\" models are never auto-deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private var activityPanel: some View {
        GroupBox("Activity") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if vm.logLines.isEmpty { Text("No activity yet.").foregroundStyle(.secondary) }
                    ForEach(Array(vm.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
        }
    }

    private var footer: some View {
        HStack {
            if vm.scanning { ProgressView().controlSize(.small) }
            Text("\(vm.models.count) models · \(formatBytes(vm.uniqueBytes)) in cache · \(formatBytes(vm.freeBytes)) free on disk")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show Cache in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([CacheScanner.cacheRoot])
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var deleteTitle: String {
        "\(vm.state.settings.moveToTrash ? "Move" : "Permanently delete") \(vm.deletable.count) model(s), \(formatBytes(vm.deletable.reduce(0) { $0 + $1.exclusiveBytes }))?"
    }

    private var deleteMessage: String {
        var lines = vm.deletable.map { "• \($0.name)\($0.excluded ? "  (marked Keep)" : "")" }
        let locked = vm.selected.filter(\.isLocked)
        if !locked.isEmpty { lines.append("\nSkipped (in use): " + locked.map(\.name).joined(separator: ", ")) }
        if vm.deletable.contains(where: \.excluded) { lines.append("\nSome of these are marked Keep.") }
        if !vm.state.settings.moveToTrash { lines.append("\nThis cannot be undone.") }
        return lines.joined(separator: "\n")
    }
}

/// Inline note editor: keeps its own text while typing, saves on Return or when focus leaves.
struct NoteField: View {
    let id: String
    let initial: String
    @EnvironmentObject var vm: ViewModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Add a note", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { text = initial }
            .onChange(of: initial) { _, v in if !focused { text = v } }
            .onSubmit { vm.setNote(id, text) }
            .onChange(of: focused) { _, f in if !f { vm.setNote(id, text) } }
    }
}

/// A plain-SwiftUI link (renders everywhere, including the README snapshot).
struct LinkText: View {
    let title: String
    let url: URL
    var body: some View {
        Text(title)
            .foregroundStyle(Color.accentColor)
            .underline()
            .onTapGesture { NSWorkspace.shared.open(url) }
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .help(url.absoluteString)
    }
}
