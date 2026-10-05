import Foundation

enum AgentError: LocalizedError {
    case notInApplications(String)
    var errorDescription: String? {
        switch self {
        case .notInApplications(let p):
            return "Move Model Cache Manager into /Applications or ~/Applications first (it is running from \(p))."
        }
    }
}

/// The background half: a launch agent runs this binary with `--agent` every 15 minutes.
/// Each run records which models are in use; once a day it applies the auto-delete rule if enabled.
enum Agent {
    static let label = "io.github.fredriklindstrom.modelcachemanager.agent"
    /// An unattended run never deletes more than this many models; larger batches need "Apply now…".
    static let maxUnattendedDeletes = 25

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    private static var domain: String { "gui/\(getuid())" }

    /// Only an installed copy may own the background agent: not a dev build, a download,
    /// or a translocated copy that macOS runs from a temporary path.
    static var executableIsInstalledCopy: Bool {
        guard let exe = Bundle.main.executableURL?.path else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return !exe.contains("/AppTranslocation/")
            && (exe.hasPrefix("/Applications/") || exe.hasPrefix(home + "/Applications/"))
    }

    /// The executable and cache path the installed agent currently uses, if any.
    static var installedConfig: (exe: String, cache: String?)? {
        guard let d = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let exe = (d["ProgramArguments"] as? [String])?.first else { return nil }
        return (exe, (d["EnvironmentVariables"] as? [String: String])?["HF_HUB_CACHE"])
    }

    /// Called at launch: only re-points the agent if the installed app moved, keeping the cache it was set up for.
    static func repointIfMoved() {
        guard isInstalled, executableIsInstalledCopy, let cfg = installedConfig,
              let exe = Bundle.main.executableURL?.path, cfg.exe != exe else { return }
        try? install(cachePath: cfg.cache)
    }

    static func install(cachePath: String? = nil) throws {
        let exe = Bundle.main.executableURL?.path ?? "?"
        guard executableIsInstalledCopy else { throw AgentError.notInApplications(exe) }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--agent"],
            "StartInterval": 900,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            // launchd doesn't inherit shell variables: pin the cache the app is looking at.
            "EnvironmentVariables": ["HF_HUB_CACHE": cachePath ?? CacheScanner.cacheRoot.path],
            "StandardOutPath": Store.dir.appendingPathComponent("agent.out").path,
            "StandardErrorPath": Store.dir.appendingPathComponent("agent.err").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        runCommand("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try data.write(to: plistURL, options: .atomic)
        runCommand("/bin/launchctl", ["bootstrap", domain, plistURL.path])
    }

    static func uninstall() {
        runCommand("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    static func days(_ s: AppState) -> Int { min(max(s.settings.days, 1), 365) }

    static func cutoff(_ s: AppState) -> Date {
        Date().addingTimeInterval(-Double(days(s)) * 86_400)
    }

    static func candidates(_ models: [CachedModel], _ s: AppState) -> [CachedModel] {
        let c = cutoff(s)
        return models.filter { !$0.isProtectedFromAuto && $0.autoClock < c }
    }

    /// Reasons not to auto-delete anything this run, or nil if it's safe to proceed.
    static func refusal(_ res: ScanResult, _ s: AppState, _ due: [CachedModel], forced: Bool) -> String? {
        if !res.usageReliable { return "the in-use check (ps / lsof) failed, so models in use can't be ruled out" }
        let soon = Date().addingTimeInterval(86_400)
        if s.firstSeen.values.contains(where: { $0 > soon }) || (s.lastAutoRun.map { $0 > soon } ?? false) {
            return "saved dates are in the future; the system clock may have changed"
        }
        if !forced && due.count > maxUnattendedDeletes {
            return "\(due.count) models are due at once, more than the unattended limit of \(maxUnattendedDeletes); review them and use Apply now"
        }
        return nil
    }

    /// One agent tick. `forceDelete` = the app's "Apply now" button.
    @discardableResult
    static func runOnce(forceDelete: Bool = false) -> [String] {
        let res = CacheScanner.scan(state: Store.load())
        let now = Date()
        let previousTick = Store.load().lastTick
        // A long gap between runs (Mac switched off, clock moved) would make every model look stale.
        // Delete nothing this run and restart the observation period instead.
        let gap = previousTick.map { now.timeIntervalSince($0) > 7 * 86_400 || $0 > now.addingTimeInterval(3600) } ?? false
        let state = Store.update { s in
            Tracker.record(res.models, into: &s)
            if gap { for m in res.models { s.firstSeen[m.id] = now } }
            if !forceDelete { s.lastTick = now }
        }
        let models = Tracker.merge(res.models, state)
        if !res.leftoverStaging.isEmpty {
            Store.log("Found \(res.leftoverStaging.count) interrupted delete(s) still holding files: \(res.leftoverStaging.joined(separator: ", "))")
        }
        if gap && !forceDelete {
            Store.log("Auto-delete paused: more than 7 days since the last check (or the clock moved). Observation period restarted.")
            return []
        }

        let due = state.lastAutoRun.map { Date().timeIntervalSince($0) > 23 * 3600 } ?? true
        guard forceDelete || (state.settings.autoDeleteEnabled && due) else { return [] }

        let targets = candidates(models, state)
        if let why = refusal(res, state, targets, forced: forceDelete) {
            Store.log("Auto-delete skipped: \(why)")
            return []
        }

        var done: [String] = []
        for m in targets {
            do {
                let outcome = try Deleter.delete(m, toTrash: state.settings.moveToTrash)
                let line = "Auto-deleted \(m.id) (\(formatBytes(outcome.freed))) to \(state.settings.moveToTrash ? "Trash" : "permanent delete"), last used \(m.lastUsed.formatted(date: .abbreviated, time: .omitted)) [\(m.lastUsedSource)]"
                Store.log(line); done.append(line)
            } catch {
                Store.log("Auto-delete failed for \(m.id): \(error.localizedDescription)")
            }
        }
        Store.update { $0.lastAutoRun = Date() }
        if done.isEmpty { Store.log("Auto-delete ran: nothing older than \(days(state)) days") }
        return done
    }
}
