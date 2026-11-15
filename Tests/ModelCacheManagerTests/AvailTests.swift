import XCTest
import Foundation
import CryptoKit
@testable import ModelCacheManager

/// llmavail against fixture trees built in a temp folder: the Hugging Face shared-blob layout (model folders hold
/// only links into one `hub/blobs/` store), missing and truncated shards, Ollama manifests and manifest lists,
/// LM Studio, and the read-only promise.
final class AvailTests: XCTestCase {
    static let stateDir = NSTemporaryDirectory() + "llmavail-state-\(UUID().uuidString)"
    var tmp = ""
    var hub: String { tmp + "/hub" }
    var ollama: String { tmp + "/ollama" }
    let fm = FileManager.default

    override class func setUp() {
        super.setUp()
        setenv("MCC_STATE_DIR", stateDir, 1)   // before anything touches Store
    }

    override func setUpWithError() throws {
        tmp = realPath(NSTemporaryDirectory()) + "/llmavail-\(UUID().uuidString)"
        try fm.createDirectory(atPath: hub + "/blobs", withIntermediateDirectories: true)
        setenv("HF_HUB_CACHE", hub, 1)
        setenv("OLLAMA_MODELS", ollama, 1)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: tmp)
    }

    // MARK: Fixture helpers

    /// A valid safetensors file: one U8 tensor of `n` bytes.
    func safetensors(_ n: Int, truncateBy cut: Int = 0) -> Data {
        var header = Data(#"{"t":{"dtype":"U8","shape":[\#(n)],"data_offsets":[0,\#(n)]}}"#.utf8)
        while header.count % 8 != 0 { header.append(0x20) }
        var d = Data()
        var len = UInt64(header.count).littleEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(header)
        d.append(Data(repeating: 7, count: n))
        return d.prefix(d.count - cut)
    }

    /// Writes a file the way a finished download looks: access time equal to modification time. (A freshly written
    /// file's atime is a few µs older than its mtime, and llmavail won't read such a file: see testReadsNeverTouchAccessTimes.)
    func write(_ path: String, _ data: Data) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        setAtime(path, daysBeforeMtime: 0)
    }

    func setAtime(_ path: String, daysBeforeMtime days: Int) {
        var st = stat()
        stat(path, &st)
        let m = timespec(tv_sec: st.st_mtimespec.tv_sec, tv_nsec: st.st_mtimespec.tv_nsec)
        var times = [days == 0 ? m : timespec(tv_sec: m.tv_sec - days * 86_400, tv_nsec: 0), m]
        XCTAssertEqual(utimensat(AT_FDCWD, path, &times, 0), 0)
    }

    /// Makes files look like they were modified after they were last read. Waits first: a malware scanner or
    /// Spotlight reads new files within a second or so, and that read would set the access time to now.
    func makeStale(_ paths: [String]) {
        Thread.sleep(forTimeInterval: 2)
        for p in paths { setAtime(p, daysBeforeMtime: 1) }
    }

    func atimeNs(_ path: String) -> Int {
        var st = stat()
        stat(path, &st)
        return st.st_atimespec.tv_sec * 1_000_000_000 + st.st_atimespec.tv_nsec
    }

    func link(_ path: String, to dest: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: path, withDestinationPath: dest)
    }

    /// A repo in the shared-blob layout: the data sits in `hub/blobs/<xx>/<hash>`; the repo's own `blobs/<hash>`
    /// links there, and `snapshots/<rev>/<file>` links to the repo blob. Returns the shared blob paths.
    @discardableResult
    func hfRepo(_ repo: String, rev: String = String(repeating: "a", count: 40), files: [String: Data],
                refs: Bool = true) throws -> [String: String] {
        let folder = hub + "/models--" + repo.replacingOccurrences(of: "/", with: "--")
        var shared: [String: String] = [:]
        for (name, data) in files {
            let hash = sha256Hex(Data(name.utf8) + data)   // unique per file, even for equal content
            let real = hub + "/blobs/\(hash.prefix(2))/\(hash)"
            try write(real, data)
            try link(folder + "/blobs/" + hash, to: "../../blobs/\(hash.prefix(2))/\(hash)")
            let depth = name.split(separator: "/").count - 1
            try link(folder + "/snapshots/\(rev)/\(name)", to: String(repeating: "../", count: 2 + depth) + "blobs/" + hash)
            shared[name] = real
        }
        if refs { try write(folder + "/refs/main", Data(rev.utf8)) }
        return shared
    }

    func sha256Hex(_ d: Data) -> String { Avail.sha256Hex(d) }

    /// A valid GGUF v3 file: metadata (alignment, a string, a string array) and one tensor per `(ggml type, shape)`,
    /// laid out the way llama.cpp writes them. Default: an F32 [8] and a Q4_0 [64] tensor.
    func ggufFile(tensors: [(UInt32, [UInt64])] = [(0, [8]), (2, [64])], cut: Int = 0) -> Data {
        var d = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func str(_ s: String) { u64(UInt64(s.utf8.count)); d.append(Data(s.utf8)) }
        u32(3); u64(UInt64(tensors.count)); u64(3)
        str("general.alignment"); u32(4); u32(32)
        str("general.name"); u32(8); str("fixture")
        str("tokenizer.ggml.tokens"); u32(9); u32(8); u64(3); str("a"); str("bb"); str("ccc")
        func size(_ type: UInt32, _ dims: [UInt64]) -> Int {
            let n = Int(dims.reduce(1, *))
            switch type { case 0: return n * 4; case 2: return n / 32 * 18; default: return n }
        }
        var offset = 0
        for (i, t) in tensors.enumerated() {
            str("t\(i)"); u32(UInt32(t.1.count)); for x in t.1 { u64(x) }; u32(t.0); u64(UInt64(offset))
            offset += (size(t.0, t.1) + 31) / 32 * 32
        }
        while d.count % 32 != 0 { d.append(0) }
        for (i, t) in tensors.enumerated() {
            d.append(Data(repeating: UInt8(i + 1), count: size(t.0, t.1)))
            if i < tensors.count - 1 { while d.count % 32 != 0 { d.append(0) } }
        }
        return d.prefix(d.count - cut)
    }

    /// An HF repo whose blobs are named by their real hashes, the way a download leaves them: large files in the
    /// shared store under their SHA-256, small ones as plain files in the repo's blobs/ under their git blob SHA-1.
    @discardableResult
    func hfRepoHashed(_ repo: String, rev: String = String(repeating: "b", count: 40), lfs: [String: Data],
                      small: [String: Data] = [:]) throws -> [String: String] {
        let folder = hub + "/models--" + repo.replacingOccurrences(of: "/", with: "--")
        var real: [String: String] = [:]
        for (name, data) in lfs {
            let hash = sha256Hex(data)
            let p = hub + "/blobs/\(hash.prefix(2))/\(hash)"
            try write(p, data)
            try link(folder + "/blobs/" + hash, to: "../../blobs/\(hash.prefix(2))/\(hash)")
            try link(folder + "/snapshots/\(rev)/\(name)", to: "../../blobs/" + hash)
            real[name] = p
        }
        for (name, data) in small {
            var h = Insecure.SHA1()
            h.update(data: Data("blob \(data.count)\0".utf8)); h.update(data: data)
            let hash = h.finalize().map { String(format: "%02x", $0) }.joined()
            try write(folder + "/blobs/" + hash, data)
            try link(folder + "/snapshots/\(rev)/\(name)", to: "../../blobs/" + hash)
            real[name] = folder + "/blobs/" + hash
        }
        try write(folder + "/refs/main", Data(rev.utf8))
        return real
    }

    /// Overwrites a file with different bytes of the same length, keeping its dates (atime = mtime).
    func tamper(_ path: String) throws {
        var d = try Data(contentsOf: URL(fileURLWithPath: path))
        d[d.count - 1] ^= 0xff
        try write(path, d)
    }

    func index(_ shards: [String]) -> Data {
        let map = Dictionary(uniqueKeysWithValues: shards.enumerated().map { ("w\($0.offset)", $0.element) })
        return try! JSONSerialization.data(withJSONObject: ["metadata": ["total_size": 1], "weight_map": map])
    }

    func rows(lmstudio: [String] = [], extra: [String] = []) -> [Avail.Row] {
        var o = Avail.Options()
        o.ollamaRoot = ollama
        o.lmstudioRoots = lmstudio
        o.extraFolders = extra
        o.usage = false
        return Avail.collect(o, state: AppState()).rows
    }

    func row(_ name: String, _ rs: [Avail.Row]) -> Avail.Row? { rs.first { $0.name == name } }

    // MARK: Hugging Face cache

    func testSharedBlobLayoutIsSizedThroughLinks() throws {
        let config = Data(#"{"quantization":{"bits":8,"group_size":64,"mode":"affine"}}"#.utf8)
        let s1 = safetensors(3000), s2 = safetensors(5000)
        try hfRepo("org/Model-MLX-8bit", files: [
            "config.json": config,
            "model-00001-of-00002.safetensors": s1,
            "model-00002-of-00002.safetensors": s2,
            "model.safetensors.index.json": index(["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]),
        ])
        let r = try XCTUnwrap(row("org/Model-MLX-8bit", rows()))
        XCTAssertTrue(r.complete, "\(r.problems)")
        XCTAssertEqual(r.format, "mlx")
        XCTAssertEqual(r.quant, "8bit")
        XCTAssertEqual(r.revision, String(repeating: "a", count: 40))
        // The repo folder itself holds only links (a few bytes each); the size is the real data behind them.
        XCTAssertGreaterThanOrEqual(r.bytes, Int64(s1.count + s2.count))
        let idx = index(["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])
        // Every file once, plus the 40-byte refs/main (the app counts the whole repo folder).
        XCTAssertEqual(r.bytes, Int64(s1.count + s2.count + config.count + idx.count + 40))
    }

    func testMissingSharedBlobMakesRepoIncomplete() throws {
        let shared = try hfRepo("org/broken", files: [
            "model-00001-of-00002.safetensors": safetensors(100),
            "model-00002-of-00002.safetensors": safetensors(200),
            "model.safetensors.index.json": index(["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]),
        ])
        try fm.removeItem(atPath: try XCTUnwrap(shared["model-00002-of-00002.safetensors"]))   // the shared store lost it
        let r = try XCTUnwrap(row("org/broken", rows()))
        XCTAssertFalse(r.complete)
        XCTAssertTrue(r.problems.contains { $0.contains("missing: model-00002-of-00002.safetensors") }, "\(r.problems)")
    }

    func testShardNamedByIndexButAbsent() throws {
        try hfRepo("org/partial", files: [
            "model-00001-of-00003.safetensors": safetensors(100),
            "model.safetensors.index.json": index(["model-00001-of-00003.safetensors", "model-00002-of-00003.safetensors",
                                                   "model-00003-of-00003.safetensors"]),
        ])
        let r = try XCTUnwrap(row("org/partial", rows()))
        XCTAssertFalse(r.complete)
        XCTAssertEqual(r.problems.filter { $0.hasPrefix("missing shard") }.count, 2, "\(r.problems)")
    }

    func testZeroBasedShardNumbersAreFine() throws {
        // gpt-oss counts its shards from 00000 and has an index; the index is what counts.
        try hfRepo("org/zero", files: [
            "model-00000-of-00001.safetensors": safetensors(10),
            "model-00001-of-00001.safetensors": safetensors(10),
            "model.safetensors.index.json": index(["model-00000-of-00001.safetensors", "model-00001-of-00001.safetensors"]),
            "config.json": Data(#"{"quantization_config":{"quant_method":"mxfp4"}}"#.utf8),
        ])
        let r = try XCTUnwrap(row("org/zero", rows()))
        XCTAssertTrue(r.complete, "\(r.problems)")
        XCTAssertEqual(r.quant, "mxfp4")
        XCTAssertEqual(r.format, "safetensors")
    }

    func testTruncatedSafetensorsIsIncomplete() throws {
        try hfRepo("org/short", files: ["model.safetensors": safetensors(1000, truncateBy: 400)])
        let r = try XCTUnwrap(row("org/short", rows()))
        XCTAssertFalse(r.complete)
        XCTAssertTrue(r.problems.contains { $0.contains("truncated") }, "\(r.problems)")
    }

    func testRefsOnlyRepo() throws {
        try write(hub + "/models--org--gone/refs/main", Data(String(repeating: "b", count: 40).utf8))
        let r = try XCTUnwrap(row("org/gone", rows()))
        XCTAssertFalse(r.complete)
        XCTAssertEqual(r.format, "none")
        XCTAssertTrue(r.problems[0].contains("no snapshot"))
    }

    func testUnfinishedDownload() throws {
        try hfRepo("org/downloading", files: ["model.safetensors": safetensors(10)])
        try write(hub + "/models--org--downloading/blobs/deadbeef.incomplete", Data(count: 5))
        let r = try XCTUnwrap(row("org/downloading", rows()))
        XCTAssertFalse(r.complete)
        XCTAssertEqual(r.status, "unverified")   // may belong to another revision (review L4)
        XCTAssertTrue(r.unchecked.contains { $0.contains(".incomplete") })
    }

    func testSplitGGUFMissingPart() throws {
        let gguf = ggufFile()
        try hfRepo("org/Big-GGUF", files: [
            "Big-Q4_K_M-00001-of-00003.gguf": gguf,
            "Big-Q4_K_M-00003-of-00003.gguf": gguf,
        ])
        let r = try XCTUnwrap(row("org/Big-GGUF", rows()))
        XCTAssertEqual(r.format, "gguf")
        XCTAssertEqual(r.quant, "Q4_K_M")
        XCTAssertFalse(r.complete)
        XCTAssertTrue(r.problems.contains { $0.contains("missing 1 of 3 parts") }, "\(r.problems)")
    }

    func testBadGGUFHeader() throws {
        try hfRepo("org/fake-gguf", files: ["x-Q8_0.gguf": Data("NOPE....".utf8)])
        let r = try XCTUnwrap(row("org/fake-gguf", rows()))
        XCTAssertFalse(r.complete)
    }

    func testIndexCannotPointOutsideTheSnapshot() throws {
        try write(tmp + "/outside.safetensors", safetensors(10))
        try hfRepo("org/escape", files: [
            "model.safetensors.index.json": index(["../../../../outside.safetensors"]),
            "model.safetensors": safetensors(10),
        ])
        let r = try XCTUnwrap(row("org/escape", rows()))
        XCTAssertFalse(r.complete)
        XCTAssertTrue(r.problems.contains { $0.contains("unsafe path") }, "\(r.problems)")
    }

    func testRefsMainPointsAtMissingSnapshot() throws {
        try hfRepo("org/moved", rev: String(repeating: "c", count: 40), files: ["model.safetensors": safetensors(10)], refs: false)
        try write(hub + "/models--org--moved/refs/main", Data(String(repeating: "d", count: 40).utf8))
        let r = try XCTUnwrap(row("org/moved", rows()))
        XCTAssertEqual(r.revision, String(repeating: "c", count: 40))   // falls back to the snapshot that's there
        XCTAssertFalse(r.complete)
    }

    func testNoWeights() throws {
        try hfRepo("org/tokenizer-only", files: ["tokenizer.json": Data("{}".utf8)])
        let r = try XCTUnwrap(row("org/tokenizer-only", rows()))
        XCTAssertFalse(r.complete)
        XCTAssertEqual(r.problems.first, "no weights files")
    }

    // MARK: Ollama

    func blob(_ data: Data) throws -> String {
        let hex = sha256Hex(data)
        try write(ollama + "/blobs/sha256-" + hex, data)
        return hex
    }

    func manifest(config: String, layers: [(String, Int)]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "config": ["digest": "sha256:" + config, "size": 10],
            "layers": layers.map { ["digest": "sha256:" + $0.0, "size": $0.1] },
        ])
    }

    func testOllamaManifestListAndLegacyLayout() throws {
        try fm.createDirectory(atPath: ollama + "/manifests", withIntermediateDirectories: true)
        let cfg = try blob(Data(#"{"file_type":"Q4_K_M"}"#.utf8))
        let weights = Data(repeating: 1, count: 4096)
        let w = try blob(weights)
        let good = try blob(manifest(config: cfg, layers: [(w, weights.count)]))
        let missing = String(repeating: "e", count: 64)
        let half = try blob(manifest(config: cfg, layers: [(missing, 99)]))
        let list = try blob(try JSONSerialization.data(withJSONObject: ["manifests": [
            ["digest": "sha256:" + good, "runner": "llamacpp", "format": "gguf"],
            ["digest": "sha256:" + half, "runner": "mlx", "format": "safetensors"],
        ]]))
        let v2 = ollama + "/manifests-v2/ollama.com/library"
        try link(v2 + "/m/7b", to: "../../../../blobs/sha256-" + list)
        // Deleted model: the link is still there, the manifest blob isn't.
        try link(v2 + "/gone/1b", to: "../../../../blobs/sha256-" + String(repeating: "f", count: 64))
        // A link that leads out of the store is never read.
        try write(tmp + "/evil.json", manifest(config: cfg, layers: [(w, weights.count)]))
        try link(v2 + "/evil/latest", to: tmp + "/evil.json")
        // Legacy layout, same model as manifests-v2's m:7b: listed once.
        try write(ollama + "/manifests/registry.ollama.ai/library/m/7b", manifest(config: cfg, layers: [(w, weights.count)]))
        // Legacy layout, a layer shorter than the manifest says.
        try write(ollama + "/manifests/registry.ollama.ai/library/short/1b", manifest(config: cfg, layers: [(w, weights.count + 1)]))

        let rs = rows().filter { $0.source == "ollama" }
        XCTAssertEqual(rs.filter { $0.name == "m:7b" }.count, 1)
        let m = try XCTUnwrap(row("m:7b", rs))
        XCTAssertEqual(m.id, "ollama/library/m:7b")   // the app's id, so Keep and notes match
        XCTAssertTrue(m.complete, "\(m.problems)")
        XCTAssertEqual(m.quant, "Q4_K_M")
        XCTAssertEqual(m.bytes, Int64(weights.count + #"{"file_type":"Q4_K_M"}"#.utf8.count))
        XCTAssertEqual(m.variants, ["llamacpp/gguf: complete", "mlx/safetensors: incomplete"])

        let gone = try XCTUnwrap(row("gone:1b", rs))
        XCTAssertFalse(gone.complete)
        XCTAssertEqual(gone.revision, String(repeating: "f", count: 64))

        let evil = try XCTUnwrap(row("evil:latest", rs))
        XCTAssertFalse(evil.complete)
        XCTAssertTrue(evil.problems[0].contains("outside"))

        let short = try XCTUnwrap(row("short:1b", rs))
        XCTAssertFalse(short.complete)
        XCTAssertTrue(short.problems.contains { $0.contains("is short") })
    }

    // MARK: LM Studio and loose folders

    func testLMStudio() throws {
        let root = tmp + "/lmstudio"
        let gguf = ggufFile()
        try write(root + "/lmstudio-community/Qwen-7B-GGUF/Qwen-7B-Q8_0.gguf", gguf)
        try write(root + "/mlx-community/Tiny-4bit/model.safetensors", safetensors(50))
        try write(root + "/mlx-community/Tiny-4bit/config.json", Data(#"{"quantization":{"bits":4}}"#.utf8))
        let rs = rows(lmstudio: [root]).filter { $0.source == "lmstudio" }
        let g = try XCTUnwrap(row("lmstudio-community/Qwen-7B-GGUF", rs))
        XCTAssertEqual(g.format, "gguf"); XCTAssertEqual(g.quant, "Q8_0"); XCTAssertTrue(g.complete)
        XCTAssertEqual(g.bytes, Int64(gguf.count))
        let t = try XCTUnwrap(row("mlx-community/Tiny-4bit", rs))
        XCTAssertEqual(t.format, "mlx"); XCTAssertEqual(t.quant, "4bit"); XCTAssertTrue(t.complete)
    }

    func testExtraFolderPath() throws {
        let root = tmp + "/models"
        let gguf = ggufFile(tensors: [(0, [UInt64(FolderStore.minWeightBytes / 4)])])   // F32, big enough to count as a model
        try write(root + "/loose-Q5_K_M.gguf", gguf)
        let rs = rows(extra: [root]).filter { $0.source == "folder" }
        let r = try XCTUnwrap(rs.first)
        XCTAssertEqual(r.format, "gguf"); XCTAssertEqual(r.quant, "Q5_K_M"); XCTAssertTrue(r.complete, "\(r.problems)")
    }

    // MARK: Read-only

    func testCollectChangesNothing() throws {
        try hfRepo("org/a", files: ["model.safetensors": safetensors(10)])
        try write(ollama + "/manifests/registry.ollama.ai/library/x/1", Data("{}".utf8))
        func snapshot() -> [String] {
            var out: [String] = []
            let en = fm.enumerator(atPath: tmp)
            while let rel = en?.nextObject() as? String {
                var st = stat()
                lstat(tmp + "/" + rel, &st)
                out.append("\(rel) \(st.st_size) \(st.st_mode) m=\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec) "
                           + "a=\(st.st_atimespec.tv_sec).\(st.st_atimespec.tv_nsec)")
            }
            return out.sorted()
        }
        let before = snapshot()
        _ = rows()
        _ = Store.load()
        XCTAssertEqual(before, snapshot())
        XCTAssertFalse(fm.fileExists(atPath: Self.stateDir), "reading the state must not create its folder")
    }

    /// In-process check of the reporting (unchecked / unverified). It does NOT prove the guard: under XCTest an
    /// open-then-check guard also passed (review 2026-11-14). testBuiltBinaryLeavesAccessTimesAlone covers that.
    /// On APFS a read sets the access time to now when it is older than the modification time, and the app counts
    /// access times as use. llmavail must leave such files unread: a skipped header check is reported, a skipped
    /// index makes the model "unverified", and no access time changes.
    func testReadsNeverTouchAccessTimes() throws {
        let shared = try hfRepo("org/stale-header", files: ["model.safetensors": safetensors(100),
                                                            "config.json": Data(#"{"torch_dtype":"bfloat16"}"#.utf8)])
        let shared2 = try hfRepo("org/stale-index", files: [
            "model-00001-of-00002.safetensors": safetensors(10),
            "model-00002-of-00002.safetensors": safetensors(10),
            "model.safetensors.index.json": index(["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]),
        ])
        let watched = [shared["model.safetensors"]!, shared["config.json"]!, shared2["model.safetensors.index.json"]!]
        makeStale(watched)
        let before = watched.map(atimeNs)
        let rs = rows()
        XCTAssertEqual(watched.map(atimeNs), before, "an access time changed")

        let h = try XCTUnwrap(row("org/stale-header", rs))
        XCTAssertEqual(h.status, "unverified")       // the header check was skipped, so it can't say complete (review M2)
        XCTAssertEqual(h.unchecked.count, 2, "\(h.unchecked)")
        XCTAssertNil(h.quant)                        // config.json wasn't read

        let i = try XCTUnwrap(row("org/stale-index", rs))
        XCTAssertEqual(i.status, "unverified")
        XCTAssertFalse(i.complete)
        XCTAssertTrue(i.problems.isEmpty)
    }

    /// The same check through the built binary, the way agents run it (review H1: a guard that only ran after
    /// opening the file passed under XCTest but not in the real command).
    func testBuiltBinaryLeavesAccessTimesAlone() throws {
        let bin = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ModelCacheManager")
        // Fail, don't skip: this is the only test that covers the access-time guard as agents run it.
        guard fm.isExecutableFile(atPath: bin.path) else { return XCTFail("built binary not found at \(bin.path)") }
        let shared = try hfRepo("org/old", files: ["model.safetensors": safetensors(100),
                                                   "config.json": Data(#"{"torch_dtype":"bfloat16"}"#.utf8)])
        let files = Array(shared.values)
        makeStale(files)
        let before = files.map(atimeNs)
        let p = Process()
        p.executableURL = bin
        p.arguments = ["llmavail", "--json", "--no-usage"]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_CACHE"] = hub; env["OLLAMA_MODELS"] = ollama; env["LMSTUDIO_MODELS"] = tmp + "/none"
        env["MCC_STATE_DIR"] = tmp + "/state"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(files.map(atimeNs), before, "the built binary changed an access time")
        XCTAssertFalse(fm.fileExists(atPath: tmp + "/state"))
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let m = try XCTUnwrap((j["models"] as? [[String: Any]])?.first { $0["name"] as? String == "org/old" })
        XCTAssertEqual(m["status"] as? String, "unverified")
        XCTAssertTrue(m["complete"] is NSNull)
    }

    func testCraftedOffsetsDontCrash() throws {
        // A header whose offsets would overflow 8 + n + end (review M1).
        var header = Data(#"{"t":{"dtype":"U8","shape":[1],"data_offsets":[0,9223372036854775807]}}"#.utf8)
        while header.count % 8 != 0 { header.append(0x20) }
        var d = Data(); var len = UInt64(header.count).littleEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(header); d.append(Data(count: 16))
        try hfRepo("org/crafted", files: ["model.safetensors": d])
        try hfRepo("org/negative", files: ["model.safetensors": {
            var h = Data(#"{"t":{"dtype":"U8","shape":[1],"data_offsets":[-5,3]}}"#.utf8)
            while h.count % 8 != 0 { h.append(0x20) }
            var x = Data(); var l = UInt64(h.count).littleEndian
            withUnsafeBytes(of: &l) { x.append(contentsOf: $0) }
            x.append(h); x.append(Data(count: 8)); return x
        }()])
        let rs = rows()
        XCTAssertEqual(row("org/crafted", rs)?.status, "incomplete")
        XCTAssertEqual(row("org/negative", rs)?.status, "incomplete")
    }

    func testDiffusersMissingComponent() throws {
        try hfRepo("org/pipe", files: [
            "model_index.json": Data(#"{"_class_name":"P","unet":["diffusers","UNet"],"vae":["diffusers","AutoencoderKL"],"safety_checker":[null,null]}"#.utf8),
            "unet/diffusion_pytorch_model.safetensors": safetensors(10),
            "unet/config.json": Data("{}".utf8),
            "text_encoder/config.json": Data("{}".utf8),
            "tokenizer/vocab.json": Data("{}".utf8),
        ])
        let r = try XCTUnwrap(row("org/pipe", rows()))
        XCTAssertEqual(r.status, "incomplete")
        XCTAssertEqual(r.problems, ["missing component: vae/ (named in model_index.json)"])
        // text_encoder/ isn't in model_index.json here, so it isn't required; one that is, with only a config, is:
        try hfRepo("org/pipe2", files: [
            "model_index.json": Data(#"{"unet":["diffusers","UNet"],"tokenizer":["transformers","T"]}"#.utf8),
            "unet/config.json": Data("{}".utf8),
            "tokenizer/vocab.json": Data("{}".utf8),
        ])
        XCTAssertEqual(row("org/pipe2", rows())?.problems.contains("missing weights in component unet/"), true)
    }

    func testStaleIndexStillCatchesMissingNumberedShards() throws {
        let shared = try hfRepo("org/stale-missing", files: [
            "model-00001-of-00002.safetensors": safetensors(10),
            "model.safetensors.index.json": index(["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]),
        ])
        makeStale([shared["model.safetensors.index.json"]!])
        let r = try XCTUnwrap(row("org/stale-missing", rows()))
        XCTAssertEqual(r.status, "incomplete", "\(r.problems)")
    }

    func testStaleOllamaManifestIsReadButLayersAreNot() throws {
        let cfg = try blob(Data(#"{"file_type":"Q4_0"}"#.utf8))
        let w = try blob(Data(repeating: 2, count: 3000))
        let path = ollama + "/manifests/registry.ollama.ai/library/old/1b"
        try write(path, manifest(config: cfg, layers: [(w, 3000)]))
        makeStale([path, ollama + "/blobs/sha256-" + w])
        let before = atimeNs(ollama + "/blobs/sha256-" + w)
        let r = try XCTUnwrap(row("old:1b", rows()))
        XCTAssertEqual(r.status, "complete", "\(r.problems)")   // a manifest is bookkeeping; its date isn't use
        XCTAssertEqual(atimeNs(ollama + "/blobs/sha256-" + w), before)
    }

    // MARK: Names

    func testQuantFromNames() {
        XCTAssertEqual(Avail.quantFromName("Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-3.3bpw"), "3.3bpw")
        XCTAssertEqual(Avail.quantFromName("Qwen3.8-27B-MLX-8bit"), "8bit")
        XCTAssertEqual(Avail.quantFromName("Z-Image-Turbo-6B-MLX-Q8"), "Q8")
        XCTAssertEqual(Avail.quantFromName("MiniMax-H3-MLX-bf16"), "bf16")
        XCTAssertNil(Avail.quantFromName("Qwen3.8-27B"))
        XCTAssertEqual(Avail.ggufQuant("Qwen3.8-27B-Q4_K_M.gguf"), "Q4_K_M")
        XCTAssertEqual(Avail.ggufQuant("m-UD-IQ2_XXS-00001-of-00003.gguf"), "UD-IQ2_XXS")
        XCTAssertEqual(Avail.ggufQuant("Qwen3.8-Flash-Next-Q4.gguf"), "Q4")
        XCTAssertEqual(Avail.quantFrom(name: "x", config: ["torch_dtype": "bfloat16"]), "bf16")
        XCTAssertEqual(Avail.quantFrom(name: "x-3.3bpw", config: ["quantization": ["bits": 4]]), "3.3bpw")
    }

    // MARK: Hugging Face access (no network: the parts that decide)

    func testTokenValidation() throws {
        XCTAssertEqual(HFAccess.validToken("hf_abcDEF123456\n"), "hf_abcDEF123456")
        XCTAssertEqual(HFAccess.validToken("hf_oauth_aaa.bbb.ccc"), "hf_oauth_aaa.bbb.ccc")
        XCTAssertNil(HFAccess.validToken("hf_abc123456\r\nX-Evil: 1"))
        XCTAssertNil(HFAccess.validToken("hf abc 123456"))
        XCTAssertNil(HFAccess.validToken("short"))
        let f = tmp + "/token"
        try write(f, Data("hf_fromfile12345\n".utf8))
        XCTAssertEqual(HFAccess.readToken(env: [:], path: f), "hf_fromfile12345")
        XCTAssertEqual(HFAccess.readToken(env: ["HF_TOKEN": "hf_fromenv123456"], path: f), "hf_fromenv123456")
        XCTAssertNil(HFAccess.readToken(env: [:], path: tmp + "/nope"))
    }

    func testRepoAndFileNamesForURLs() {
        XCTAssertTrue(HFAccess.isValidRepo("meta-llama/Llama-Prompt-Guard-2-86M"))
        XCTAssertFalse(HFAccess.isValidRepo("../etc"))
        XCTAssertFalse(HFAccess.isValidRepo("a/b/c"))
        XCTAssertFalse(HFAccess.isValidRepo("a/.."))
        XCTAssertFalse(HFAccess.isValidRepo("a/b?x=1"))
        XCTAssertTrue(HFAccess.isValidFile("config.json"))
        XCTAssertFalse(HFAccess.isValidFile("../config.json"))
    }

    func testAccessClassification() {
        XCTAssertEqual(HFAccess.classify(status: 200, errorCode: nil, errorMessage: nil), "granted")
        XCTAssertEqual(HFAccess.classify(status: 302, errorCode: nil, errorMessage: nil), "granted")
        XCTAssertEqual(HFAccess.classify(status: 403, errorCode: "GatedRepo",
                                         errorMessage: "Your request to access model x/y is awaiting a review from the repo authors."), "pending")
        XCTAssertEqual(HFAccess.classify(status: 403, errorCode: "GatedRepo",
                                         errorMessage: "Access to model x/y is restricted and you are not in the authorized list."), "not requested")
        XCTAssertEqual(HFAccess.classify(status: 401, errorCode: "GatedRepo", errorMessage: nil), "not requested")
        XCTAssertTrue(HFAccess.classify(status: 404, errorCode: nil, errorMessage: nil).hasPrefix("unknown"))   // review L3
    }

    // MARK: GGUF length

    func testWholeGGUFIsComplete() throws {
        try hfRepo("org/tiny-GGUF", files: ["tiny-Q4_0.gguf": ggufFile()])
        let r = try XCTUnwrap(row("org/tiny-GGUF", rows()))
        XCTAssertEqual(r.status, "complete", "\(r.problems) \(r.unchecked)")
    }

    func testTruncatedSingleGGUFIsIncomplete() throws {
        try hfRepo("org/cut-GGUF", files: ["cut-Q4_0.gguf": ggufFile(cut: 1)])
        let r = try XCTUnwrap(row("org/cut-GGUF", rows()))
        XCTAssertEqual(r.status, "incomplete")
        XCTAssertTrue(r.problems.contains { $0.contains("truncated") }, "\(r.problems)")
        // Cut inside the header too.
        try hfRepo("org/stub-GGUF", files: ["stub-Q4_0.gguf": ggufFile().prefix(40)])
        let s = try XCTUnwrap(row("org/stub-GGUF", rows()))
        XCTAssertTrue(s.problems.contains { $0.contains("ends inside its header") }, "\(s.problems)")
    }

    func testGGUFWithUnknownLastTensorTypeIsUnverified() throws {
        try hfRepo("org/new-GGUF", files: ["new-Q4_0.gguf": ggufFile(tensors: [(0, [8]), (99, [64])])])
        let r = try XCTUnwrap(row("org/new-GGUF", rows()))
        XCTAssertEqual(r.status, "unverified", "\(r.problems)")
        XCTAssertTrue(r.unchecked.contains { $0.contains("ggml type 99") })
    }

    func testCraftedGGUFHeadersDontCrash() throws {
        var d = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        // One tensor whose shape overflows, one whose offset is huge, a string length past the end.
        u32(3); u64(2); u64(0)
        u64(1); d.append(Data("a".utf8)); u32(2); u64(UInt64.max); u64(UInt64.max); u32(0); u64(0)
        try write(tmp + "/x1.gguf", d)
        d = Data("GGUF".utf8); u32(3); u64(1); u64(0); u64(1); d.append(Data("a".utf8)); u32(1); u64(32); u32(0); u64(UInt64(Int64.max))
        try write(tmp + "/x2.gguf", d)
        d = Data("GGUF".utf8); u32(3); u64(0); u64(1); u64(UInt64.max - 3)
        try write(tmp + "/x3.gguf", d)
        d = Data("GGUF".utf8); u32(3); u64(0); u64(1); u64(1); d.append(Data("k".utf8)); u32(9); u32(9); u64(UInt64.max)   // nested array bomb
        try write(tmp + "/x4.gguf", d)
        for f in ["x1", "x2", "x3", "x4"] {
            guard case .ok(let c) = Avail.ggufCheck(tmp + "/\(f).gguf") else { return XCTFail("\(f) not read") }
            XCTAssertNotEqual(c, .whole, f)
        }
    }

    // MARK: --verify

    func testVerifyHashesAgainstBlobNames() throws {
        let weights = safetensors(4000)
        try hfRepoHashed("org/hashed", lfs: ["model.safetensors": weights], small: ["config.json": Data("{}".utf8)])
        var rs = rows().filter { $0.name == "org/hashed" }
        XCTAssertEqual(rs.first?.hashRefs.count, 2)
        AvailVerify.run(&rs, hub: false, token: nil, login: nil)
        XCTAssertEqual(rs[0].verify?.status, "verified")
        XCTAssertEqual(rs[0].verify?.matched, 2)
        XCTAssertTrue(rs[0].complete)
    }

    func testVerifyCatchesAlteredContent() throws {
        let real = try hfRepoHashed("org/altered", lfs: ["model.safetensors": safetensors(4000)],
                                    small: ["config.json": Data(#"{"a":1}"#.utf8)])
        try tamper(real["model.safetensors"]!)   // same length: the structural checks can't see it
        try tamper(real["config.json"]!)
        var rs = rows().filter { $0.name == "org/altered" }
        XCTAssertTrue(rs[0].complete, "same length, so complete before hashing")
        AvailVerify.run(&rs, hub: false, token: nil, login: nil)
        XCTAssertEqual(rs[0].verify?.status, "mismatch")
        XCTAssertEqual(rs[0].verify?.mismatched, 2)
        XCTAssertEqual(rs[0].status, "incomplete")
        XCTAssertTrue(rs[0].problems.contains { $0.hasPrefix("model.safetensors: content doesn't match") })
    }

    func testVerifySkipsFilesItWouldTouch() throws {
        let real = try hfRepoHashed("org/stale", lfs: ["model.safetensors": safetensors(4000)])
        let p = real["model.safetensors"]!
        makeStale([p])
        let before = atimeNs(p)
        var rs = rows().filter { $0.name == "org/stale" }
        AvailVerify.run(&rs, hub: false, token: nil, login: nil)
        XCTAssertEqual(rs[0].verify?.status, "partly verified")
        XCTAssertEqual(rs[0].verify?.skipped, 1)
        XCTAssertEqual(atimeNs(p), before)
    }

    func testVerifyOllamaBlobsAndLMStudio() throws {
        try fm.createDirectory(atPath: ollama + "/manifests", withIntermediateDirectories: true)
        let cfg = try blob(Data(#"{"file_type":"Q4_0"}"#.utf8))
        let w = try blob(Data(repeating: 3, count: 5000))
        try write(ollama + "/manifests/registry.ollama.ai/library/ok/1b", manifest(config: cfg, layers: [(w, 5000)]))
        let w2 = try blob(Data(repeating: 4, count: 6000))
        try write(ollama + "/manifests/registry.ollama.ai/library/bad/1b", manifest(config: cfg, layers: [(w2, 6000)]))
        try tamper(ollama + "/blobs/sha256-" + w2)
        let lm = tmp + "/lmstudio"
        try write(lm + "/pub/m-GGUF/m-Q4_0.gguf", ggufFile())
        var rs = rows(lmstudio: [lm])
        AvailVerify.run(&rs, hub: false, token: nil, login: nil)
        XCTAssertEqual(row("ok:1b", rs)?.verify?.status, "verified")
        XCTAssertEqual(row("bad:1b", rs)?.verify?.status, "mismatch")
        XCTAssertEqual(row("pub/m-GGUF", rs)?.verify?.status, "no reference hash")
    }

    func testHubFileListComparison() throws {
        let body = Data(#"""
        {"siblings":[
          {"rfilename":"model.safetensors","size":4096,"blobId":"1111111111111111111111111111111111111111",
           "lfs":{"sha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","size":4096,"pointerSize":134}},
          {"rfilename":"config.json","size":2,"blobId":"9e26dfeeb6e641a33dae4961196235bdb965b21b"}
        ]}
        """#.utf8)
        let hub = try XCTUnwrap(HFAccess.parseFileList(body).files)
        XCTAssertEqual(hub["model.safetensors"], HFAccess.HubFile(size: 4096, sha256: String(repeating: "a", count: 64),
                                                                 blobId: String(repeating: "1", count: 40)))
        let ok = [AvailVerify.Ref(rel: "model.safetensors", real: "/x", size: 4096, algo: .sha256, hex: String(repeating: "a", count: 64)),
                  AvailVerify.Ref(rel: "config.json", real: "/y", size: 2, algo: .gitSHA1, hex: "9e26dfeeb6e641a33dae4961196235bdb965b21b")]
        let good = AvailVerify.compareHub(ok, hub)
        XCTAssertEqual(good.problems, []); XCTAssertEqual(good.compared, 2)
        let bad = [AvailVerify.Ref(rel: "model.safetensors", real: "/x", size: 4000, algo: .sha256, hex: String(repeating: "b", count: 64)),
                   AvailVerify.Ref(rel: "extra.bin", real: "/z", size: 1, algo: .sha256, hex: String(repeating: "c", count: 64))]
        let c = AvailVerify.compareHub(bad, hub)
        XCTAssertEqual(c.problems.count, 2)   // size and hash
        XCTAssertEqual(c.notListed, ["extra.bin"])
        XCTAssertNil(HFAccess.parseFileList(Data("[]".utf8)).files)
    }

    // MARK: The app and Ollama 0.40's manifests-v2

    /// v1 `a:1` and v2 `a:1` (Ollama 0.40 writes both), a v1-only `b:1` sharing a layer with the v2 list,
    /// and a v2-only `c:1`. Returns the digests.
    func ollamaBothLayouts() throws -> (shared: String, onlyB: String, onlyC: String, aList: String) {
        let cfg = try blob(Data(#"{"file_type":"Q4_0"}"#.utf8))
        let shared = try blob(Data(repeating: 5, count: 7000))
        let onlyB = try blob(Data(repeating: 6, count: 3000))
        let onlyC = try blob(Data(repeating: 7, count: 2000))
        let v1 = ollama + "/manifests/registry.ollama.ai/library"
        try write(v1 + "/a/1", manifest(config: cfg, layers: [(shared, 7000)]))
        try write(v1 + "/b/1", manifest(config: cfg, layers: [(shared, 7000), (onlyB, 3000)]))
        let aSub = try blob(manifest(config: cfg, layers: [(shared, 7000)]))
        let aList = try blob(try JSONSerialization.data(withJSONObject: ["mediaType": "application/vnd.ollama.manifest.list.v2+json",
            "manifests": [["digest": "sha256:" + aSub, "runner": "mlx", "format": "safetensors"],
                          ["digest": "sha256:" + String(repeating: "d", count: 64), "runner": "llamacpp", "format": "gguf"]]]))
        let v2 = ollama + "/manifests-v2/ollama.com/library"
        try link(v2 + "/a/1", to: "../../../../blobs/sha256-" + aList)
        // Its gguf variant is gone, like a leftover on a real store: an hour old, so not a pull in progress.
        var t = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(Date().timeIntervalSince1970) - 3600, tv_nsec: 0)]
        XCTAssertEqual(utimensat(AT_FDCWD, v2 + "/a/1", &t, AT_SYMLINK_NOFOLLOW), 0)
        let cMan = try blob(manifest(config: cfg, layers: [(onlyC, 2000)]))
        try link(v2 + "/c/1", to: "../../../../blobs/sha256-" + cMan)
        return (shared, onlyB, onlyC, aList)
    }

    func scanModels() -> [CachedModel] {
        CacheScanner.scan(state: AppState(), checkUsage: false).models.filter { $0.store == .ollama }
    }

    func testAppListsManifestsV2() throws {
        let d = try ollamaBothLayouts()
        let refs = OllamaStore.references(root: realPath(ollama))
        XCTAssertTrue(refs.isComplete, "\(refs.incomplete)")
        XCTAssertEqual(Set(refs.v2.map(\.id)), ["ollama/library/a:1", "ollama/library/c:1"])
        let ms = scanModels()
        XCTAssertEqual(ms.map(\.id).sorted(), ["ollama/library/a:1", "ollama/library/b:1", "ollama/library/c:1"])   // a:1 once
        let a = try XCTUnwrap(ms.first { $0.id == "ollama/library/a:1" })
        XCTAssertNotNil(a.deleteBlocked)                       // has a v2 tag: not deleted by the app
        XCTAssertTrue(a.ollamaBlobs.contains(d.aList))
        let c = try XCTUnwrap(ms.first { $0.id == "ollama/library/c:1" })
        XCTAssertEqual(c.name, "c:1")
        XCTAssertNotNil(c.deleteBlocked)
        XCTAssertEqual(c.exclusiveBytes, c.totalBytes - Int64(#"{"file_type":"Q4_0"}"#.utf8.count))   // all but the shared config
        XCTAssertGreaterThanOrEqual(c.totalBytes, 2000)
        let b = try XCTUnwrap(ms.first { $0.id == "ollama/library/b:1" })
        XCTAssertNil(b.deleteBlocked)
        XCTAssertFalse(b.externalExclusiveFiles.contains { $0.path.hasSuffix(d.shared) })   // a's v2 list uses it too
    }

    func testDeletingV1ModelKeepsLayersAV2ManifestUses() throws {
        let d = try ollamaBothLayouts()
        let b = try XCTUnwrap(scanModels().first { $0.id == "ollama/library/b:1" })
        try Deleter.delete(b, toTrash: false)
        XCTAssertFalse(fm.fileExists(atPath: ollama + "/manifests/registry.ollama.ai/library/b/1"))
        XCTAssertFalse(fm.fileExists(atPath: ollama + "/blobs/sha256-" + d.onlyB))
        XCTAssertTrue(fm.fileExists(atPath: ollama + "/blobs/sha256-" + d.shared))   // a:1 (both layouts) still needs it
        let a = try XCTUnwrap(scanModels().first { $0.id == "ollama/library/a:1" })
        XCTAssertThrowsError(try Deleter.delete(a, toTrash: false))
        var unblocked = a; unblocked.deleteBlocked = nil   // the delete re-checks the store itself
        XCTAssertThrowsError(try Deleter.delete(unblocked, toTrash: false))
        XCTAssertTrue(fm.fileExists(atPath: ollama + "/manifests/registry.ollama.ai/library/a/1"))
    }

    func testManifestDatesAreNotEvidenceOfUse() throws {
        let cfg = try blob(Data(#"{"file_type":"Q4_0"}"#.utf8))
        let w = try blob(Data(repeating: 8, count: 4000))
        let path = ollama + "/manifests/registry.ollama.ai/library/m/1"
        try write(path, manifest(config: cfg, layers: [(w, 4000)]))
        // Layers last read 30 days ago; the manifest read just now (as the app's own scan does).
        let old = Int(Date().timeIntervalSince1970) - 30 * 86_400
        for p in [ollama + "/blobs/sha256-" + w, ollama + "/blobs/sha256-" + cfg] {
            var t = [timespec(tv_sec: old, tv_nsec: 0), timespec(tv_sec: old, tv_nsec: 0)]
            XCTAssertEqual(utimensat(AT_FDCWD, p, &t, 0), 0)
        }
        var t = [timespec(tv_sec: Int(Date().timeIntervalSince1970), tv_nsec: 0), timespec(tv_sec: old, tv_nsec: 0)]
        XCTAssertEqual(utimensat(AT_FDCWD, path, &t, 0), 0)
        let m = try XCTUnwrap(scanModels().first { $0.id == "ollama/library/m:1" })
        XCTAssertEqual(m.lastAccess.map { Int($0.timeIntervalSince1970) }, old)
        // And llmavail reads manifests freely now, layers stay untouched.
        let before = atimeNs(ollama + "/blobs/sha256-" + w)
        XCTAssertEqual(row("m:1", rows())?.status, "complete")
        XCTAssertEqual(atimeNs(ollama + "/blobs/sha256-" + w), before)
    }

    // MARK: Regressions from the 2026-11-15 security review

    /// v1-only b:1 shares a layer with a v2 manifest-list variant of a:1; `badVariant` adds a list entry whose
    /// digest isn't sha256-shaped (a future format), so the list can't be read in full.
    func listFixture(badVariant: Bool, v1a: Bool) throws -> (shared: String, onlyB: String) {
        let cfg = try blob(Data(#"{"file_type":"Q4_0"}"#.utf8))
        let shared = try blob(Data(repeating: 5, count: 7000))
        let onlyB = try blob(Data(repeating: 6, count: 3000))
        let v1 = ollama + "/manifests/registry.ollama.ai/library"
        try write(v1 + "/b/1", manifest(config: cfg, layers: [(shared, 7000), (onlyB, 3000)]))
        if v1a { try write(v1 + "/a/1", manifest(config: cfg, layers: [(shared, 7000)])) }
        let aSub = try blob(manifest(config: cfg, layers: [(shared, 7000)]))
        var entries: [[String: Any]] = [["digest": "sha256:" + aSub, "runner": "mlx", "format": "safetensors"]]
        if badVariant { entries.append(["digest": "sha512:" + String(repeating: "e", count: 128), "runner": "future"]) }
        let aList = try blob(try JSONSerialization.data(withJSONObject: ["manifests": entries]))
        try link(ollama + "/manifests-v2/ollama.com/library/a/1", to: "../../../../blobs/sha256-" + aList)
        return (shared, onlyB)
    }

    func testUnreadableV2ListBlocksOllamaDeletes() throws {   // review H1
        let d = try listFixture(badVariant: true, v1a: false)
        XCTAssertFalse(OllamaStore.references(root: realPath(ollama)).isComplete)
        let b = try XCTUnwrap(scanModels().first { $0.id == "ollama/library/b:1" })
        XCTAssertThrowsError(try Deleter.delete(b, toTrash: false))
        XCTAssertTrue(fm.fileExists(atPath: ollama + "/blobs/sha256-" + d.shared))
        XCTAssertTrue(fm.fileExists(atPath: ollama + "/blobs/sha256-" + d.onlyB))
    }

    func testUnreadableV2ListStillBlocksItsV1Copy() throws {   // review H2
        _ = try listFixture(badVariant: true, v1a: true)
        let a = try XCTUnwrap(scanModels().first { $0.id == "ollama/library/a:1" })
        XCTAssertThrowsError(try Deleter.delete(a, toTrash: false))
        XCTAssertTrue(fm.fileExists(atPath: ollama + "/manifests/registry.ollama.ai/library/a/1"))
    }

    func testDuplicateV2TagsStillBlockTheV1Copy() throws {   // review M1
        let cfg = try blob(Data(#"{"file_type":"Q4_0"}"#.utf8))
        let w = try blob(Data(repeating: 9, count: 5000))
        let man = manifest(config: cfg, layers: [(w, 5000)])
        try write(ollama + "/manifests/registry.ollama.ai/library/a/1", man)
        let mb = try blob(man)
        try link(ollama + "/manifests-v2/ollama.com/library/a/1", to: "../../../../blobs/sha256-" + mb)
        try link(ollama + "/manifests-v2/registry.ollama.ai/library/a/1", to: "../../../../blobs/sha256-" + mb)
        let a = try XCTUnwrap(scanModels().first { $0.id == "ollama/library/a:1" })
        XCTAssertNotNil(a.deleteBlocked)
        var unblocked = a; unblocked.deleteBlocked = nil
        XCTAssertThrowsError(try Deleter.delete(unblocked, toTrash: false))
        XCTAssertTrue(fm.fileExists(atPath: ollama + "/manifests/registry.ollama.ai/library/a/1"))
    }

    func testV2LinkOutOfTheStoreIsNotFollowed() throws {   // review L1
        try fm.createDirectory(atPath: ollama + "/manifests", withIntermediateDirectories: true)
        try link(ollama + "/manifests-v2/ollama.com/library/g/1", to: "/")
        let t0 = Date()
        let refs = OllamaStore.references(root: realPath(ollama))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        XCTAssertFalse(refs.isComplete)   // fails safe: no Ollama deletes
    }

    func testVocabOnlyGGUFIsWhole() throws {   // review L2
        var d = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(3); u64(0); u64(1); u64(4); d.append(Data("abcd".utf8)); u32(8); u64(1); d.append(Data("x".utf8))
        try write(tmp + "/vocab.gguf", d)
        guard case .ok(let c) = Avail.ggufCheck(tmp + "/vocab.gguf") else { return XCTFail("not read") }
        XCTAssertEqual(c, .whole)
    }

    func testManyStringsParseQuickly() throws {   // review L3
        let n = 5_000_000
        var d = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(3); u64(0); u64(1); u64(1); d.append(Data("k".utf8)); u32(9); u32(8); u64(UInt64(n))
        d.append(Data(count: n * 8))
        try write(tmp + "/many.gguf", d)
        let t0 = Date()
        _ = Avail.ggufCheck(tmp + "/many.gguf")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
    }

    func testUnknownTensorTypeAnywhereIsUnverified() throws {   // review L4
        var d = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func str(_ s: String) { u64(UInt64(s.utf8.count)); d.append(Data(s.utf8)) }
        u32(3); u64(2); u64(0)
        str("a"); u32(1); u64(1 << 20); u32(40); u64(0)
        str("b"); u32(1); u64(0); u32(0); u64(0)
        while d.count % 32 != 0 { d.append(0) }
        d.append(Data(count: 64))
        try write(tmp + "/hidden.gguf", d)
        guard case .ok(let c) = Avail.ggufCheck(tmp + "/hidden.gguf") else { return XCTFail("not read") }
        guard case .unknown = c else { return XCTFail("\(c)") }
    }

    func testDisagreeingOllamaCopiesAreUnverified() throws {   // review L5
        let cfg = try blob(Data(#"{"file_type":"Q4_0"}"#.utf8))
        let w = try blob(Data(repeating: 1, count: 4000))
        try write(ollama + "/manifests/registry.ollama.ai/library/m/1", manifest(config: cfg, layers: [(w, 4000)]))
        let broken = try blob(manifest(config: cfg, layers: [(String(repeating: "e", count: 64), 10)]))
        try link(ollama + "/manifests-v2/ollama.com/library/m/1", to: "../../../../blobs/sha256-" + broken)
        let r = try XCTUnwrap(row("m:1", rows()))
        XCTAssertEqual(r.status, "unverified")
        XCTAssertTrue(r.unchecked.contains { $0.contains("manifests-v2 copy is incomplete") }, "\(r.unchecked)")
    }

    func testDSStoreInManifestsV2DoesNotBlockDeletes() throws {   // review 2, N1
        let cfg = try blob(Data(#"{"file_type":"Q4_0"}"#.utf8))
        let w = try blob(Data(repeating: 4, count: 3000))
        try write(ollama + "/manifests/registry.ollama.ai/library/z/1", manifest(config: cfg, layers: [(w, 3000)]))
        try write(ollama + "/manifests-v2/.DS_Store", Data(repeating: 0, count: 64))
        try write(ollama + "/manifests-v2/ollama.com/library/.DS_Store", Data(repeating: 0, count: 64))
        XCTAssertTrue(OllamaStore.references(root: realPath(ollama)).isComplete)
        let z = try XCTUnwrap(scanModels().first { $0.id == "ollama/library/z:1" })
        XCTAssertNoThrow(try Deleter.delete(z, toTrash: false))
    }

    func testFreshListWithMissingVariantBlocksDeletes() throws {   // review 2: a pull racing a delete
        _ = try listFixture(badVariant: false, v1a: false)
        let cfg = try blob(Data(#"{"file_type":"Q4_0"}"#.utf8))
        let list = try blob(try JSONSerialization.data(withJSONObject: ["manifests": [
            ["digest": "sha256:" + String(repeating: "d", count: 64), "runner": "llamacpp", "format": "gguf"]]]))
        _ = cfg
        let tag = ollama + "/manifests-v2/ollama.com/library/new/1"
        try link(tag, to: "../../../../blobs/sha256-" + list)
        XCTAssertFalse(OllamaStore.references(root: realPath(ollama)).isComplete)   // just written: may be mid-pull
        var t = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(Date().timeIntervalSince1970) - 3600, tv_nsec: 0)]
        XCTAssertEqual(utimensat(AT_FDCWD, tag, &t, AT_SYMLINK_NOFOLLOW), 0)
        XCTAssertTrue(OllamaStore.references(root: realPath(ollama)).isComplete)    // an hour old: a leftover
    }

    // MARK: Command line

    func testParseAndFilter() throws {
        let p = try LLMAvailCLI.parse(["qwen", "--format", "gguf", "--incomplete"]).get()
        XCTAssertEqual(p.terms, ["qwen"]); XCTAssertEqual(p.format, "gguf"); XCTAssertTrue(p.incomplete)
        XCTAssertThrowsError(try LLMAvailCLI.parse(["--format", "zip"]).get())
        XCTAssertThrowsError(try LLMAvailCLI.parse(["--delete"]).get())
        XCTAssertThrowsError(try LLMAvailCLI.parse(["--complete", "--incomplete"]).get())
        let a = Avail.Row(source: "hf", id: "model/org/Qwen-GGUF", name: "org/Qwen-GGUF", revision: nil, format: "gguf",
                          quant: nil, bytes: 1, problems: ["x"], path: "/")
        var b = a; b.name = "org/Llama"; b.id = "model/org/Llama"; b.problems = []
        XCTAssertEqual(LLMAvailCLI.filter([a, b], p).map(\.name), ["org/Qwen-GGUF"])
        XCTAssertEqual(LLMAvailCLI.filter([a, b], try LLMAvailCLI.parse(["--complete"]).get()).map(\.name), ["org/Llama"])
    }

    func testTextOutputStripsControlCharacters() {
        var r = Avail.Row(source: "folder", id: "x", name: "evil\u{1b}[2Jname", revision: nil, format: "gguf",
                          quant: nil, bytes: 1, path: "/")
        r.note = "note\u{7}"
        let t = LLMAvailCLI.text([r], Avail.Collection(), login: nil, access: false)
        XCTAssertFalse(t.contains("\u{1b}")); XCTAssertFalse(t.contains("\u{7}"))
    }
}
