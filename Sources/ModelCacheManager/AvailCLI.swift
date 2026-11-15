import Foundation

/// The `llmavail` command: run the app's binary under that name (a symlink), or as `ModelCacheManager llmavail …`.
enum LLMAvailCLI {
    static let usage = """
    llmavail: which models are on this Mac, complete and ready to run. Read-only.

    usage: llmavail [TERM …] [options]

      TERM               only models whose name or id contains every TERM (case-insensitive)
      --format F         safetensors, mlx, gguf, ollama, pytorch, onnx, none
      --source S         hf, ollama, lmstudio, folder
      --incomplete       only models with something missing ("unverified" ones are in neither list)
      --complete         only complete models
      --path DIR         also list models in DIR (like a watched folder, for this run only; repeatable)
      --verify           hash every file against the hash it was downloaded under (reads every byte:
                         minutes per 100 GB; LM Studio and plain folders record no hashes)
      --access           ask huggingface.co whether each repo is gated and whether your login has access;
                         with --verify, also compare sizes and hashes with the Hub's list for the cached
                         revision (the only option that uses the network; the token is never printed)
      --no-usage         skip the in-use checks (ps / lsof): faster, but "in use" isn't reported
      --json             machine-readable output
      -h, --help         this help

    Exit status: 0 = at least one model listed, 1 = nothing matched, 2 = bad arguments.
    """

    struct Parsed {
        var terms: [String] = []
        var format: String?
        var source: String?
        var incomplete = false
        var complete = false
        var paths: [String] = []
        var access = false
        var verify = false
        var usage = true
        var json = false
        var help = false
    }

    struct UsageError: Error { let message: String }

    static func parse(_ args: [String]) -> Result<Parsed, UsageError> {
        var p = Parsed()
        var i = 0
        func value(_ flag: String) -> String? {
            if i + 1 < args.count { i += 1; return args[i] }
            return nil
        }
        while i < args.count {
            let a = args[i]
            var flag = a, inline: String?
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                flag = String(a[..<eq]); inline = String(a[a.index(after: eq)...])
            }
            switch flag {
            case "--json": p.json = true
            case "--incomplete": p.incomplete = true
            case "--complete": p.complete = true
            case "--access": p.access = true
            case "--verify": p.verify = true
            case "--no-usage": p.usage = false
            case "-h", "--help": p.help = true
            case "--format", "--source", "--path":
                guard let v = inline ?? value(flag), !v.isEmpty else { return .failure(UsageError(message: "\(flag) needs a value")) }
                if flag == "--format" { p.format = v.lowercased() }
                else if flag == "--source" { p.source = v.lowercased() }
                else { p.paths.append(v) }
            default:
                if a.hasPrefix("-") { return .failure(UsageError(message: "unknown option \(a)")) }
                p.terms.append(a.lowercased())
            }
            i += 1
        }
        if p.incomplete && p.complete { return .failure(UsageError(message: "--incomplete and --complete exclude each other")) }
        let formats = ["safetensors", "mlx", "gguf", "ollama", "pytorch", "onnx", "none"]
        if let f = p.format, !formats.contains(f) { return .failure(UsageError(message: "--format must be one of \(formats.joined(separator: ", "))")) }
        let sources = ["hf", "ollama", "lmstudio", "folder"]
        if let s = p.source, !sources.contains(s) { return .failure(UsageError(message: "--source must be one of \(sources.joined(separator: ", "))")) }
        return .success(p)
    }

    static func filter(_ rows: [Avail.Row], _ p: Parsed) -> [Avail.Row] {
        rows.filter { r in
            let hay = (r.name + " " + r.id).lowercased()
            return p.terms.allSatisfy { hay.contains($0) }
                && (p.format.map { r.format == $0 } ?? true)
                && (p.source.map { r.source == $0 } ?? true)
                && (!p.incomplete || r.status == "incomplete")
                && (!p.complete || r.complete)
        }
    }

    static func run(_ args: [String]) -> Int32 {
        let p: Parsed
        switch parse(args) {
        case .failure(let why): FileHandle.standardError.write(Data("llmavail: \(why.message)\n\n\(usage)\n".utf8)); return 2
        case .success(let v): p = v
        }
        if p.help { print(usage); return 0 }

        var opts = Avail.Options()
        opts.usage = p.usage
        for raw in p.paths {
            let real = realPath((raw as NSString).expandingTildeInPath)
            guard Deleter.isRealDirectory(real) else {
                FileHandle.standardError.write(Data(printable("llmavail: not a folder: \(raw)\n").utf8)); return 2
            }
            opts.extraFolders.append(real)
        }
        let c = Avail.collect(opts, state: Store.load())
        var rows = filter(c.rows, p)
        var login: HFAccess.Login?
        if p.access, let off = ProcessInfo.processInfo.environment["HF_HUB_OFFLINE"], ["1", "true", "yes", "on"].contains(off.lowercased()) {
            FileHandle.standardError.write(Data("llmavail: HF_HUB_OFFLINE is set, so --access won't contact huggingface.co\n".utf8)); return 2
        }
        let token = p.access ? HFAccess.readToken() : nil
        if p.access && rows.contains(where: { $0.source == "hf" }) {
            login = HFAccess.annotate(&rows, token: token)
        }
        if p.verify {
            AvailVerify.run(&rows, hub: p.access, token: token, login: login)
        }
        if p.json { print(json(rows, c, login: login)) }
        else { print(text(rows, c, login: login, access: p.access, verify: p.verify)) }
        return rows.isEmpty ? 1 : 0
    }

    // MARK: Output

    /// "verified", "partly verified (3/5)", "MISMATCH", "no reference hash"; "+hub" / "hub differs" with --access.
    static func verifyText(_ v: AvailVerify.Summary?) -> String {
        guard let v = v else { return "-" }
        var t = v.status == "mismatch" ? "MISMATCH" : v.status
        if v.status == "partly verified" { t += " (\(v.matched)/\(v.files + v.unreferenced))" }
        if let h = v.hub { t += h.hasPrefix("matches") ? ", hub ok" : h == "differs" ? ", HUB DIFFERS" : ", hub not checked" }
        return t
    }

    static func loginText(_ l: HFAccess.Login) -> String {
        switch l {
        case .none: return "no login"
        case .ok: return "ok"
        case .rejected: return "token rejected"
        case .unknown(let why): return "unknown (\(why))"
        }
    }

    static func json(_ rows: [Avail.Row], _ c: Avail.Collection, login: HFAccess.Login?) -> String {
        let iso = ISO8601DateFormatter()
        func opt(_ v: String?) -> Any { v.map { $0 as Any } ?? NSNull() }
        let models: [[String: Any]] = rows.map { r in [
            "source": r.source, "id": r.id, "name": r.name, "revision": opt(r.revision),
            "format": r.format, "quant": opt(r.quant), "size_bytes": r.bytes, "size": r.bytes > 0 ? formatBytes(r.bytes) : "0 bytes",
            "complete": r.unverified && r.problems.isEmpty ? NSNull() : r.complete as Any, "status": r.status,
            "problems": r.problems, "unchecked": r.unchecked, "path": r.path,
            "last_used": r.lastUsed.map { iso.string(from: $0) as Any } ?? NSNull(), "last_used_source": r.lastUsedSource,
            "in_use": opt(r.inUse), "keep": r.keep, "project_kept": r.projectKept, "projects": r.projects, "note": r.note,
            "snapshots": r.snapshots, "variants": r.variants, "gated": opt(r.gated), "access": opt(r.access),
            "verify": r.verify.map { v -> Any in [
                "status": v.status, "files": v.files, "matched": v.matched, "mismatched": v.mismatched,
                "skipped": v.skipped, "failed": v.failed, "no_reference": v.unreferenced, "hub": opt(v.hub),
            ] } ?? NSNull(),
        ] }
        var out: [String: Any] = [
            "models": models,
            "generated": iso.string(from: Date()),
            "usage_reliable": c.usageReliable,
            "notes": c.notes,
            "roots": ["hf": c.hfRoot, "ollama": c.ollamaRoot, "lmstudio": c.lmstudioRoots],
        ]
        if let l = login { out["hf_login"] = loginText(l) }
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func text(_ rows: [Avail.Row], _ c: Avail.Collection, login: HFAccess.Login?, access: Bool, verify: Bool = false) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }
        var table: [[String]] = [["SOURCE", "MODEL", "REV", "FORMAT", "QUANT", "SIZE", "STATUS", "LAST USED", "KEEP"]
                                 + (access ? ["ACCESS"] : []) + (verify ? ["VERIFY"] : []) + ["NOTE"]]
        for r in rows {
            let used = r.inUse.map { $0.hasPrefix(UsageDetector.unknownPrefix) ? "locked" : "in use" }
                ?? r.lastUsed.map { day.string(from: $0) } ?? "never"
            table.append([r.source, clip(r.name, 60), r.revision.map { String($0.prefix(7)) } ?? "-", r.format,
                          clip(r.quant ?? "-", 28), r.bytes > 0 ? formatBytes(r.bytes) : "-", r.status == "incomplete" ? "INCOMPLETE" : r.status, used,
                          r.keep || r.projectKept ? "keep" : "-"]
                         + (access ? [r.source == "hf" ? (r.access ?? "-") : "-"] : [])
                         + (verify ? [verifyText(r.verify)] : []) + [clip(r.note, 40)])
        }
        let widths = table[0].indices.map { col in table.map { $0[col].count }.max() ?? 0 }
        var lines: [String] = []
        for (n, cells) in table.enumerated() {
            let line = cells.enumerated().map { i, s in i == cells.count - 1 ? s : s.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
            lines.append(printable(line))
            if n > 0 {
                let r = rows[n - 1]
                for p in r.problems.prefix(4) { lines.append(printable("    ! " + p)) }
                if r.problems.count > 4 { lines.append("    ! … and \(r.problems.count - 4) more") }
                for u in r.unchecked.prefix(2) { lines.append(printable("    ? " + u)) }
                if r.unchecked.count > 2 { lines.append("    ? … and \(r.unchecked.count - 2) more not checked") }
            }
        }
        if rows.isEmpty { lines = ["no models match"] }
        let complete = rows.filter(\.complete).count, unverified = rows.filter { $0.status == "unverified" }.count
        lines.append("")
        lines.append("\(rows.count) model\(rows.count == 1 ? "" : "s"): \(complete) complete, \(rows.count - complete - unverified) incomplete, "
                     + (unverified > 0 ? "\(unverified) unverified, " : "")
                     + "\(formatBytes(rows.reduce(0) { $0 + $1.bytes })) (shared files count once per model)")
        if let l = login { lines.append("Hugging Face login: \(loginText(l))") }
        if !c.usageReliable { lines.append("in-use check (ps / lsof) failed: \"in use\" may be missing") }
        for n in c.notes { lines.append(printable(n)) }
        return lines.joined(separator: "\n")
    }
}
