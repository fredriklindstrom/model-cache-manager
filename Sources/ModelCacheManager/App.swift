import SwiftUI
import AppKit

struct ModelCacheApp: App {
    @StateObject private var vm = ViewModel()

    var body: some Scene {
        WindowGroup("Model Cache Manager") {
            ContentView()
                .environmentObject(vm)
                .frame(minWidth: 1180, minHeight: 640)
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

enum SidebarItem: Hashable { case all, unassigned, project(String) }

@MainActor
final class ViewModel: ObservableObject {
    @Published var sidebar: SidebarItem? = .all
    @Published var models: [CachedModel] = []
    @Published var uniqueBytes: Int64 = 0
    @Published var leftoverStaging: [String] = []
    @Published var selection = Set<CachedModel.ID>()
    @Published var sortOrder = [KeyPathComparator(\CachedModel.exclusiveBytes, order: .reverse)]
    @Published var scanning = false
    @Published var state = Store.load()
    @Published var trackingOn = Agent.isInstalled
    @Published var logLines: [String] = []
    @Published var search = ""
    @Published var message: String?

    init(manageAgent: Bool = true) {
        // Re-point the agent if the installed app moved; never from a dev build or download.
        if manageAgent { Agent.repointIfMoved() }
        refresh()
    }

    var sortedProjects: [Project] {
        state.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    var currentProject: Project? {
        if case .project(let id) = sidebar { return state.projects.first { $0.id == id } }
        return nil
    }
    func models(in p: Project) -> [CachedModel] { models.filter { p.models.contains($0.id) } }

    var visible: [CachedModel] {
        let q = search.lowercased()
        return models.filter { m in
            switch sidebar ?? .all {
            case .all: return true
            case .unassigned: return m.projectNames.isEmpty
            case .project(let id): return state.projects.first { $0.id == id }?.models.contains(m.id) ?? false
            }
        }
        .filter { m in
            q.isEmpty || m.name.lowercased().contains(q) || m.note.lowercased().contains(q)
                || m.projectNames.contains { $0.lowercased().contains(q) }
        }
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
                self.leftoverStaging = res.leftoverStaging
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

    // MARK: Projects

    @discardableResult
    func createProject(_ name: String, adding ids: [String]) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        if state.projects.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            message = "A project called “\(n)” already exists."
            return false
        }
        let p = Project(name: n, models: Set(ids))
        Store.update { $0.projects.append(p) }
        Store.log("Created project “\(n)”" + (ids.isEmpty ? "" : " with \(ids.count) model(s)"))
        reloadState()
        sidebar = .project(p.id)
        return true
    }

    @discardableResult
    func renameProject(_ id: String, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        if state.projects.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            message = "A project called “\(n)” already exists."
            return false
        }
        Store.update { s in if let i = s.projects.firstIndex(where: { $0.id == id }) { s.projects[i].name = n } }
        reloadState()
        return true
    }

    func deleteProject(_ id: String) {
        let name = state.projects.first { $0.id == id }?.name ?? ""
        Store.update { $0.projects.removeAll { $0.id == id } }
        Store.log("Deleted project “\(name)” (its models were not touched)")
        if sidebar == .project(id) { sidebar = .all }
        reloadState()
    }

    func setProjectKeep(_ id: String, _ on: Bool) {
        Store.update { s in if let i = s.projects.firstIndex(where: { $0.id == id }) { s.projects[i].keep = on } }
        let name = state.projects.first { $0.id == id }?.name ?? ""
        Store.log(on ? "Project “\(name)”: all models kept out of auto-delete" : "Project “\(name)”: models back under auto-delete")
        reloadState()
    }

    func add(_ ids: [String], to id: String) {
        Store.update { s in if let i = s.projects.firstIndex(where: { $0.id == id }) { s.projects[i].models.formUnion(ids) } }
        reloadState()
    }

    func remove(_ ids: [String], from id: String) {
        Store.update { s in if let i = s.projects.firstIndex(where: { $0.id == id }) { s.projects[i].models.subtract(ids) } }
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
        let ids = deletable.map(\.id)
        let toTrash = state.settings.moveToTrash
        scanning = true
        Task.detached(priority: .userInitiated) {
            // Re-scan right before deleting: the table can be hours old. A model that started being
            // used, or that now shares files with a newer download, is judged on its current state.
            let fresh = CacheScanner.scan(state: Store.load())
            var freed: Int64 = 0
            var failed: [String] = []
            var targets: [CachedModel] = []
            if !fresh.usageReliable {
                failed.append("the in-use check (ps / lsof) failed, so nothing was deleted; try again")
            }
            for id in ids where fresh.usageReliable {
                guard let m = fresh.models.first(where: { $0.id == id }) else { failed.append("\(id): no longer in the cache"); continue }
                if let r = m.inUseReason { failed.append("\(m.name): \(r)"); continue }
                targets.append(m)
            }
            for m in targets {
                do {
                    let outcome = try Deleter.delete(m, toTrash: toTrash)
                    freed += outcome.freed
                    Store.log("Deleted \(m.id) (\(formatBytes(outcome.freed))) \(toTrash ? "to Trash" : "permanently")"
                              + (outcome.trashLocation.map { " as \(($0 as NSString).lastPathComponent)" } ?? ""))
                } catch {
                    failed.append("\(m.name): \(error.localizedDescription)")
                    Store.log("Delete failed for \(m.id): \(error.localizedDescription)")
                }
            }
            let freedTotal = freed, failures = failed
            await MainActor.run {
                var text = "\(toTrash ? "Moved to Trash" : "Deleted"): \(ids.count - failures.count) model(s), \(formatBytes(freedTotal))."
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
        if m.projectKept { return "Kept (project)" }
        let due = m.autoClock.addingTimeInterval(Double(Agent.days(state)) * 86_400)
        if due <= Date() { return "Due now" }
        let days = Int(ceil(due.timeIntervalSinceNow / 86_400))
        return "In \(days) day\(days == 1 ? "" : "s")" + (m.inGracePeriod ? " · tracking" : "")
    }
}

/// What the project-name sheet is doing: creating (optionally with models) or renaming.
struct ProjectSheet: Identifiable {
    let id = UUID()
    var renaming: Project?
    var adding: [String] = []
}

struct ContentView: View {
    @EnvironmentObject var vm: ViewModel
    @State private var confirmDelete = false
    @State private var confirmAuto = false
    @State private var projectSheet: ProjectSheet?
    @State private var projectToDelete: Project?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .searchable(text: $vm.search, prompt: "Filter by name, note or project")
        .sheet(item: $projectSheet) { sheet in
            ProjectNameSheet(sheet: sheet).environmentObject(vm)
        }
        .confirmationDialog("Delete project “\(projectToDelete?.name ?? "")”?",
                            isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }),
                            titleVisibility: .visible, presenting: projectToDelete) { p in
            Button("Delete Project", role: .destructive) { vm.deleteProject(p.id) }
        } message: { _ in
            Text("Only the grouping is removed. The models stay in the cache.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $vm.sidebar) {
            sidebarRow("All Models", icon: "square.stack.3d.up", models: vm.models)
                .tag(SidebarItem.all)
            sidebarRow("Not in a Project", icon: "tray", models: vm.models.filter { $0.projectNames.isEmpty })
                .tag(SidebarItem.unassigned)
            Section("Projects") {
                ForEach(vm.sortedProjects) { p in
                    sidebarRow(p.name, icon: "folder", models: vm.models(in: p), kept: p.keep)
                        .tag(SidebarItem.project(p.id))
                        .dropDestination(for: String.self) { items, _ in
                            let ids = items.flatMap { $0.split(separator: "\n").map(String.init) }
                            vm.add(ids, to: p.id)
                            return !ids.isEmpty
                        }
                        .contextMenu {
                            Button("Rename…") { projectSheet = ProjectSheet(renaming: p) }
                            Button(p.keep ? "Let Auto-delete Include These Models" : "Keep All Models (no auto-delete)") {
                                vm.setProjectKeep(p.id, !p.keep)
                            }
                            Divider()
                            Button("Delete Project…", role: .destructive) { projectToDelete = p }
                        }
                }
                if vm.state.projects.isEmpty {
                    Text("Group models by what they're for, e.g. “Local Video Generation”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { projectSheet = ProjectSheet() } label: { Label("New Project", systemImage: "plus") }
                .buttonStyle(.borderless)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sidebarRow(_ title: String, icon: String, models: [CachedModel], kept: Bool = false) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon).lineLimit(1)
            if kept {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green).font(.caption)
                    .help("All models in this project are kept out of auto-delete")
            }
            Spacer()
            Text(formatBytes(models.reduce(0) { $0 + $1.exclusiveBytes }))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help("\(models.count) model\(models.count == 1 ? "" : "s")")
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            if let p = vm.currentProject { projectHeader(p); Divider() }
            table
                .overlay {
                    if vm.currentProject != nil && vm.visible.isEmpty && vm.search.isEmpty {
                        Text("Drag models here from All Models, or right-click a model and choose Add to Project.")
                            .foregroundStyle(.secondary)
                            .padding(40)
                    }
                }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                autoPanel.frame(maxWidth: .infinity)
                activityPanel.frame(width: 380)
            }
            .padding(12)
            Divider()
            footer
        }
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

    private func projectHeader(_ p: Project) -> some View {
        let ms = vm.models(in: p)
        return HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(p.name).font(.headline)
            Text("\(ms.count) model\(ms.count == 1 ? "" : "s") · \(formatBytes(ms.reduce(0) { $0 + $1.exclusiveBytes }))")
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Keep all models in this project", isOn: Binding(get: { p.keep }, set: { vm.setProjectKeep(p.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Exclude every model in this project from auto-delete")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Drag payload: all selected rows when dragging a selected row, otherwise just this one.
    private func dragPayload(_ m: CachedModel) -> String {
        vm.selection.contains(m.id) ? vm.selection.sorted().joined(separator: "\n") : m.id
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<String>) -> some View {
        let list = ids.sorted()
        if !list.isEmpty {
            Menu("Add to Project") {
                ForEach(vm.sortedProjects) { p in
                    Button(p.name) { vm.add(list, to: p.id) }
                }
                if !vm.state.projects.isEmpty { Divider() }
                Button("New Project…") { projectSheet = ProjectSheet(adding: list) }
            }
            let member = vm.sortedProjects.filter { !$0.models.isDisjoint(with: ids) }
            if !member.isEmpty {
                Menu("Remove from Project") {
                    ForEach(member) { p in Button(p.name) { vm.remove(list, from: p.id) } }
                }
            }
            Divider()
            Button("Keep (exclude from auto-delete)") { list.forEach { vm.setExcluded($0, true) } }
            Button("Stop Keeping") { list.forEach { vm.setExcluded($0, false) } }
            Divider()
            Button("Delete…", role: .destructive) {
                vm.selection = ids
                confirmDelete = true
            }
        }
    }

    private var table: some View {
        Table(of: CachedModel.self, selection: $vm.selection, sortOrder: $vm.sortOrder) {
            TableColumn("Model", value: \.name) { m in
                HStack(spacing: 8) {
                    let kept = m.excluded || m.projectKept
                    Image(systemName: m.isLocked ? "lock.fill" : (kept ? "checkmark.shield.fill" : "shippingbox"))
                        .foregroundStyle(m.isLocked ? Color.orange : (kept ? Color.green : Color.secondary))
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
            .width(min: 200, ideal: 260)

            TableColumn("Projects") { m in
                Text(m.projectNames.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(m.projectNames.joined(separator: "\n"))
            }
            .width(min: 80, ideal: 130)

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
            .width(110)

            TableColumn("Note") { m in
                NoteField(id: m.id, initial: m.note)
            }
            .width(min: 160, ideal: 220)
        } rows: {
            ForEach(vm.visible) { m in
                TableRow(m).draggable(dragPayload(m))
            }
        }
        .contextMenu(forSelectionType: CachedModel.ID.self) { ids in
            rowMenu(ids)
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
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            if !vm.leftoverStaging.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(vm.leftoverStaging.map { URL(fileURLWithPath: $0) })
                } label: {
                    Label("\(vm.leftoverStaging.count) interrupted delete\(vm.leftoverStaging.count == 1 ? "" : "s") still holding files", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
                .help("A delete was interrupted. Its files are in a hidden folder in the cache: move them back or to the Trash.")
            }
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
        var lines = vm.deletable.map { "• \($0.name)\($0.excluded ? "  (marked Keep)" : "")\($0.projectKept ? "  (in a kept project)" : "")" }
        let locked = vm.selected.filter(\.isLocked)
        if !locked.isEmpty { lines.append("\nSkipped (in use): " + locked.map(\.name).joined(separator: ", ")) }
        if vm.deletable.contains(where: { $0.excluded || $0.projectKept }) { lines.append("\nSome of these are kept out of auto-delete; deleting by hand still removes them.") }
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

/// Name entry for creating or renaming a project.
struct ProjectNameSheet: View {
    let sheet: ProjectSheet
    @EnvironmentObject var vm: ViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sheet.renaming == nil ? "New Project" : "Rename Project").font(.headline)
            if sheet.renaming == nil && !sheet.adding.isEmpty {
                Text("\(sheet.adding.count) selected model\(sheet.adding.count == 1 ? "" : "s") will be added.")
                    .foregroundStyle(.secondary)
            }
            TextField("e.g. Local Video Generation", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sheet.renaming == nil ? "Create" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = sheet.renaming?.name ?? "" }
    }

    private func save() {
        let ok = sheet.renaming.map { vm.renameProject($0.id, to: name) } ?? vm.createProject(name, adding: sheet.adding)
        if ok { dismiss() }
    }
}
