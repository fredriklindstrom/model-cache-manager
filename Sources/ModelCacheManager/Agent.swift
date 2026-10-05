import Foundation

/// The background half: a launch agent runs this binary with `--agent` every 15 minutes.
/// Each run records which models are in use; once a day it applies the auto-delete rule if enabled.
enum Agent {
    static let label = "io.github.fredriklindstrom.modelcachemanager.agent"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    private static var domain: String { "gui/\(getuid())" }

    static func install() throws {
        guard let exe = Bundle.main.executableURL?.path else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--agent"],
            "StartInterval": 900,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "StandardOutPath": Store.dir.appendingPathComponent("agent.out").path,
            "StandardErrorPath": Store.dir.appendingPathComponent("agent.err").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = runCommand("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try data.write(to: plistURL, options: .atomic)
        _ = runCommand("/bin/launchctl", ["bootstrap", domain, plistURL.path])
    }

    static func uninstall() {
        _ = runCommand("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    static func cutoff(_ s: AppState) -> Date {
        Date().addingTimeInterval(-Double(s.settings.days) * 86_400)
    }

    static func candidates(_ models: [CachedModel], _ s: AppState) -> [CachedModel] {
        let c = cutoff(s)
        return models.filter { !$0.isProtectedFromAuto && $0.autoClock < c }
    }

    /// One agent tick. `forceDelete` = the app's "Apply now" button.
    @discardableResult
    static func runOnce(forceDelete: Bool = false) -> [String] {
        let res = CacheScanner.scan(state: Store.load())
        let state = Store.update { Tracker.record(res.models, into: &$0) }
        let models = Tracker.merge(res.models, state)

        let due = state.lastAutoRun.map { Date().timeIntervalSince($0) > 23 * 3600 } ?? true
        guard forceDelete || (state.settings.autoDeleteEnabled && due) else { return [] }

        var done: [String] = []
        for m in candidates(models, state) {
            do {
                try Deleter.delete(m, toTrash: state.settings.moveToTrash)
                let line = "Auto-deleted \(m.id) (\(formatBytes(m.exclusiveBytes))) to \(state.settings.moveToTrash ? "Trash" : "permanent delete"), last used \(m.lastUsed.formatted(date: .abbreviated, time: .omitted)) [\(m.lastUsedSource)]"
                Store.log(line); done.append(line)
            } catch {
                Store.log("Auto-delete failed for \(m.id): \(error.localizedDescription)")
            }
        }
        Store.update { $0.lastAutoRun = Date() }
        if done.isEmpty { Store.log("Auto-delete ran: nothing older than \(state.settings.days) days") }
        return done
    }
}
