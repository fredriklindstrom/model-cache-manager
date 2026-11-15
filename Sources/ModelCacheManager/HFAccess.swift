import Foundation

/// `llmavail --access`: for each Hugging Face repo, whether it is gated and whether your login has access.
///
/// Uses the token the `hf` CLI saved (`hf auth login`). The token:
/// - is read from `$HF_TOKEN`, else the file `$HF_TOKEN_PATH`, else `$HF_HOME/token`, else `~/.cache/huggingface/token`;
/// - is only ever sent to https://huggingface.co, as an `Authorization` header (`HF_ENDPOINT` is ignored on purpose,
///   so a changed environment can't send it elsewhere), with redirects refused so it can't follow one either;
/// - is never printed, logged, stored, or put in a URL.
/// Requests are read-only: model info (GET), a HEAD on one small file of the cached revision, and (with
/// `--verify`) the revision's file list (GET).
enum HFAccess {
    static let host = "huggingface.co"

    enum Login: Equatable { case none, ok, rejected, unknown(String) }

    struct Result { var gated: String?; var access: String }

    // MARK: Token

    static var tokenPath: String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["HF_TOKEN_PATH"], !p.isEmpty { return (p as NSString).expandingTildeInPath }
        if let h = env["HF_HOME"], !h.isEmpty { return (h as NSString).expandingTildeInPath + "/token" }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.cache/huggingface/token"
    }

    /// The saved token, or nil. Only a plain token is accepted (ASCII letters, digits, `_`, `-`, `.`), so nothing read
    /// from the file can add a header line or anything else to a request.
    static func readToken(env: [String: String] = ProcessInfo.processInfo.environment, path: String? = nil) -> String? {
        if let t = env["HF_TOKEN"], let v = validToken(t) { return v }
        guard let d = Avail.readRegular(path ?? tokenPath, max: 4096, guardAtime: false) else { return nil }   // not a model file
        return validToken(String(decoding: d, as: UTF8.self))
    }

    static func validToken(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...4096).contains(t.count),
              t.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "_-.".unicodeScalars.contains($0) })
        else { return nil }
        return t
    }

    // MARK: Requests

    /// `org/name`, each part a Hub name (letters, digits, `.`, `_`, `-`; not `.` or `..`).
    static func isValidRepo(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 96
                && $0.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0) }
        }
    }

    static func isValidFile(_ s: String) -> Bool { HFAccess.isValidRepo("x/" + s) }

    struct Reply { var status: Int; var headers: [String: String]; var body: Data; var error: String? }

    private final class Fetch: NSObject, URLSessionDataDelegate {
        var reply = Reply(status: 0, headers: [:], body: Data())
        let done = DispatchSemaphore(value: 0)
        let cap: Int
        init(cap: Int) { self.cap = cap }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let h = response as? HTTPURLResponse {
                reply.status = h.statusCode
                for (k, v) in h.allHeaderFields { if let k = k as? String, let v = v as? String { reply.headers[k.lowercased()] = v } }
            }
            completionHandler(.allow)
        }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            reply.body.append(chunk)
            if reply.body.count > cap { reply.error = "reply too large"; dataTask.cancel() }
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // never follow: the 3xx itself is the answer, and the token stays on huggingface.co
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let e = error, reply.error == nil { reply.error = (e as? URLError).map { "network error \($0.code.rawValue)" } ?? "network error" }
            done.signal()
        }
    }

    /// One request to https://huggingface.co. `path` is built only from validated parts.
    static func request(_ method: String, _ path: String, token: String?, cap: Int = 1 << 20) -> Reply {
        var c = URLComponents()
        let pieces = path.split(separator: "?", maxSplits: 1).map(String.init)
        c.scheme = "https"; c.host = host; c.percentEncodedPath = pieces[0]
        if pieces.count == 2 { c.percentEncodedQuery = pieces[1] }
        guard let url = c.url, url.host == host, url.scheme == "https" else { return Reply(status: 0, headers: [:], body: Data(), error: "bad request") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        let f = Fetch(cap: cap)
        let session = URLSession(configuration: cfg, delegate: f, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("llmavail (Model Cache Manager)", forHTTPHeaderField: "User-Agent")
        if let t = token { r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        session.dataTask(with: r).resume()
        f.done.wait()
        return f.reply
    }

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "._-"))) ?? ""
    }

    static func checkLogin(token: String?) -> Login {
        guard let t = token else { return .none }
        let r = request("GET", "/api/whoami-v2", token: t)
        if r.status == 200 { return .ok }
        if r.status == 401 { return .rejected }
        return .unknown(r.error ?? "HTTP \(r.status)")
    }

    /// Gated or not, and what this login may do. `probe` is a file of the cached revision `revision`.
    static func check(repo: String, revision: String?, probe: String?, token: String?, login: Login) -> Result {
        guard isValidRepo(repo) else { return Result(gated: nil, access: "unknown (unusual repo name, not checked)") }
        let parts = repo.split(separator: "/").map { encode(String($0)) }
        // Without the token first (gated status is public), so the Hub only learns which repos you have cached
        // under your account when it has to: a private repo, or the access check below.
        var info = request("GET", "/api/models/\(parts[0])/\(parts[1])?expand%5B%5D=gated", token: nil)
        if (info.status == 401 || info.status == 404) && login == .ok {
            info = request("GET", "/api/models/\(parts[0])/\(parts[1])?expand%5B%5D=gated", token: token)
        }
        let gated: String?
        switch info.status {
        case 200:
            let j = (try? JSONSerialization.jsonObject(with: info.body)) as? [String: Any]
            if let g = j?["gated"] as? String { gated = g } else if j?["gated"] as? Bool == false { gated = "no" } else { gated = nil }
        case 401, 404:
            return Result(gated: nil, access: login == .ok ? "not found (private or removed)" : "not found (or private: needs a login)")
        default:
            return Result(gated: nil, access: "unknown (\(info.error ?? "HTTP \(info.status)"))")
        }
        guard let g = gated else { return Result(gated: nil, access: "unknown (no gated field)") }
        if g == "no" { return Result(gated: "no", access: "open") }
        switch login {
        case .none: return Result(gated: g, access: "no login")
        case .rejected: return Result(gated: g, access: "token rejected")
        case .unknown(let why): return Result(gated: g, access: "unknown (login check failed: \(why))")
        case .ok: break
        }
        let rev = revision.flatMap { $0.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil ? $0 : nil } ?? "main"
        let file = probe.flatMap { isValidFile($0) ? $0 : nil } ?? "config.json"
        let r = request("HEAD", "/\(parts[0])/\(parts[1])/resolve/\(rev)/\(encode(file))", token: token)
        return Result(gated: g, access: classify(status: r.status, errorCode: r.headers["x-error-code"],
                                                 errorMessage: r.headers["x-error-message"], networkError: r.error))
    }

    /// A HEAD on a file of a gated repo: 2xx/3xx = you have access; 401/403 = you don't, and the Hub's
    /// message says whether a request is waiting for review.
    static func classify(status: Int, errorCode: String?, errorMessage: String?, networkError: String? = nil) -> String {
        switch status {
        case 200..<400: return "granted"
        case 401, 403:
            let m = (errorMessage ?? "").lowercased()
            if m.contains("awaiting") || m.contains("pending") { return "pending" }
            if m.contains("rejected") { return "rejected" }
            return "not requested"
        case 404: return "unknown (the file checked isn't in that revision)"
        default: return "unknown (\(networkError ?? "HTTP \(status)"))"
        }
    }

    /// Fills `gated` and `access` on every Hugging Face row, a few repos at a time.
    static func annotate(_ rows: inout [Avail.Row], token: String?) -> Login {
        let login = checkLogin(token: token)
        let idx = rows.indices.filter { rows[$0].source == "hf" }
        var results = [Int: Result]()
        let lock = NSLock()
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 6
        for i in idx {
            let row = rows[i]
            q.addOperation {
                let res = check(repo: row.name, revision: row.revision, probe: probeFile(row), token: token, login: login)
                lock.lock(); results[i] = res; lock.unlock()
            }
        }
        q.waitUntilAllOperationsAreFinished()
        for (i, r) in results { rows[i].gated = r.gated; rows[i].access = r.access }
        return login
    }

    // MARK: File list (--verify)

    struct HubFile: Equatable { var size: Int64?; var sha256: String?; var blobId: String? }

    /// Every file of a revision with its size and hashes (`/api/models/<repo>/revision/<rev>?blobs=true`): the
    /// SHA-256 for LFS files, the git blob id for the rest. Without the token first, like the model info.
    static func revisionFiles(repo: String, revision: String?, token: String?, login: Login) -> (files: [String: HubFile]?, error: String?) {
        guard isValidRepo(repo) else { return (nil, "unusual repo name") }
        guard let rev = revision, rev.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            return (nil, "no cached commit to compare")
        }
        let parts = repo.split(separator: "/").map { encode(String($0)) }
        let path = "/api/models/\(parts[0])/\(parts[1])/revision/\(rev)?blobs=true"
        var r = request("GET", path, token: nil, cap: 64 << 20)
        if (r.status == 401 || r.status == 403 || r.status == 404) && login == .ok {
            r = request("GET", path, token: token, cap: 64 << 20)
        }
        guard r.status == 200 else { return (nil, r.error ?? "HTTP \(r.status)") }
        return parseFileList(r.body)
    }

    static func parseFileList(_ body: Data) -> (files: [String: HubFile]?, error: String?) {
        guard let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let siblings = j["siblings"] as? [[String: Any]] else { return (nil, "unexpected reply") }
        func hex(_ v: Any?, _ n: Int) -> String? {
            guard let s = (v as? String)?.lowercased(), s.count == n, s.allSatisfy(\.isHexDigit) else { return nil }
            return s
        }
        var out: [String: HubFile] = [:]
        for f in siblings {
            guard let name = f["rfilename"] as? String else { continue }
            let lfs = f["lfs"] as? [String: Any]
            out[name] = HubFile(size: ((lfs?["size"] ?? f["size"]) as? NSNumber)?.int64Value,
                                sha256: hex(lfs?["sha256"], 64), blobId: hex(f["blobId"], 40))
        }
        return (out, nil)
    }

    /// A small top-level file of the cached snapshot to HEAD: config.json if it's there.
    static func probeFile(_ row: Avail.Row) -> String? {
        let names = Avail.sortedNames(row.path).filter { !$0.hasPrefix(".") && isValidFile($0) }
        if names.contains("config.json") { return "config.json" }
        return names.first { $0.hasSuffix(".json") || $0.hasSuffix(".md") } ?? names.first
    }
}
