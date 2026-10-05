import Foundation

struct Settings: Codable {
    var autoDeleteEnabled = false
    var days = 30
    var moveToTrash = true
}

/// A user-defined group of models, e.g. "Local Video Generation". A model can be in several projects.
struct Project: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var keep = false               // keep every model in this project out of auto-delete
    var models: Set<String> = []   // repo ids; remembered even while a model isn't downloaded
}

/// Everything the app remembers between launches. Shared with the background agent.
struct AppState: Codable {
    var settings = Settings()
    var excluded: Set<String> = []          // never auto-deleted
    var notes: [String: String] = [:]       // free-text comment per model
    var projects: [Project] = []
    var firstSeen: [String: Date] = [:]     // when tracking of a model started
    var lastSeenInUse: [String: Date] = [:] // last time a process or open file was seen using it
    var lastAutoRun: Date?
    var lastTick: Date?                     // last background-agent run; detects long gaps / clock jumps

    init() {}

    // Tolerant decoding, so adding fields later never wipes someone's notes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = (try? c.decode(Settings.self, forKey: .settings)) ?? Settings()
        settings.days = min(max(settings.days, 1), 365)   // never trust the file for the safety window
        excluded = (try? c.decode(Set<String>.self, forKey: .excluded)) ?? []
        notes = (try? c.decode([String: String].self, forKey: .notes)) ?? [:]
        projects = (try? c.decode([Project].self, forKey: .projects)) ?? []
        firstSeen = (try? c.decode([String: Date].self, forKey: .firstSeen)) ?? [:]
        lastSeenInUse = (try? c.decode([String: Date].self, forKey: .lastSeenInUse)) ?? [:]
        lastAutoRun = try? c.decode(Date.self, forKey: .lastAutoRun)
        lastTick = try? c.decode(Date.self, forKey: .lastTick)
    }
}

enum Store {
    static let dir: URL = {
        let env = ProcessInfo.processInfo.environment["MCC_STATE_DIR"]
        let d = env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelCacheManager")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var stateURL: URL { dir.appendingPathComponent("state.json") }
    static var logURL: URL { dir.appendingPathComponent("activity.log") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    static func load() -> AppState {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? decoder.decode(AppState.self, from: data) else { return AppState() }
        return s
    }

    /// Load, change, save — re-reading first so the app and the agent don't overwrite each other.
    @discardableResult
    static func update(_ change: (inout AppState) -> Void) -> AppState {
        var s = load()
        change(&s)
        if let data = try? encoder.encode(s) { try? data.write(to: stateURL, options: .atomic) }
        return s
    }

    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
        // Repo names come from folder names on disk: escape control characters so log lines can't be forged.
        let clean = line.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : String($0) }.joined()
        let text = "\(stamp)  \(clean)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: logURL)
        }
    }

    static func recentLog(_ n: Int) -> [String] {
        guard let s = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return Array(s.split(separator: "\n").suffix(n).map(String.init).reversed())
    }
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
