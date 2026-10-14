import Foundation
import SwiftUI
import AppKit

// Headless modes (used by the launch agent and for testing); otherwise open the window.
let args = CommandLine.arguments

if args.contains("--agent") {
    Agent.runOnce()
    exit(0)
}

if args.contains("--list") {
    let res = CacheScanner.scan(state: Store.load())
    let sorted = res.models.sorted(by: { $0.exclusiveBytes > $1.exclusiveBytes })
    let hfCount = res.models.filter { $0.store == .hf }.count
    let ollamaCount = res.models.count - hfCount
    if args.contains("--json") {
        // Machine-readable, for scripts and benchmark harnesses. Field names are a stable interface.
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = sorted.map { m in [
            "id": m.id, "store": m.store.rawValue, "name": m.name, "path": m.folder.path,
            "exclusive_bytes": m.exclusiveBytes, "total_bytes": m.totalBytes,
            "last_used": m.lastUsed == .distantPast ? NSNull() : iso.string(from: m.lastUsed),
            "last_used_source": m.lastUsedSource,
            "locked": m.isLocked, "lock_reason": m.inUseReason.map { $0 as Any } ?? NSNull(),
            "keep": m.excluded, "project_kept": m.projectKept, "projects": m.projectNames, "note": m.note,
            "delete_blocked": m.deleteBlocked.map { $0 as Any } ?? NSNull(),
        ] }
        let totals: [String: Any] = [
            "hf": ["models": hfCount, "bytes": res.uniqueBytes, "root": realPath(CacheScanner.cacheRoot.path)],
            "ollama": ["models": ollamaCount, "bytes": res.ollamaBytes, "root": realPath(OllamaStore.root.path),
                       "present": res.ollamaPresent, "complete": res.ollamaIncomplete == nil,
                       "incomplete_reason": res.ollamaIncomplete.map { $0 as Any } ?? NSNull()],
            "usage_reliable": res.usageReliable,
            "leftover_staging": res.leftoverStaging,
        ]
        let out = try! JSONSerialization.data(withJSONObject: ["models": rows, "totals": totals],
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: out, as: UTF8.self))
        exit(0)
    }
    for m in sorted {
        let pad = m.id.padding(toLength: 64, withPad: " ", startingAt: 0)
        print(printable("\(pad) \(formatBytes(m.exclusiveBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) "
              + (m.lastUsed == .distantPast ? "used never" : "used \(m.lastUsed.formatted(date: .abbreviated, time: .omitted)) [\(m.lastUsedSource)]")
              + (m.inUseReason.map { "  LOCKED: \($0)" } ?? "") + (m.excluded ? "  KEEP" : "")
              + (m.projectNames.isEmpty ? "" : "  [\(m.projectNames.joined(separator: ", "))\(m.projectKept ? ", kept" : "")]")))
    }
    if res.ollamaPresent {
        print("\(hfCount) HF repo\(hfCount == 1 ? "" : "s"), \(formatBytes(res.uniqueBytes)); "
              + "\(ollamaCount) Ollama model\(ollamaCount == 1 ? "" : "s"), \(formatBytes(res.ollamaBytes)) on disk")
    } else {
        print("\(res.models.count) repos, \(formatBytes(res.uniqueBytes)) on disk")
    }
    for p in res.leftoverStaging { print(printable("Interrupted delete, files still on disk: \(p)")) }
    if let why = res.ollamaIncomplete { print(printable("Ollama store not fully readable (\(why)); Ollama models can't be deleted until it is")) }
    exit(0)
}

if let i = args.firstIndex(of: "--delete"), i + 1 < args.count {
    let res = CacheScanner.scan(state: Store.load())
    guard let m = res.models.first(where: { $0.id == args[i + 1] }) else { print("no such repo"); exit(1) }
    guard res.usageReliable else { print("Not deleted: the in-use check failed, so it can't be ruled out that the model is in use"); exit(1) }
    do {
        let outcome = try Deleter.delete(m, toTrash: !args.contains("--permanent"))
        print(printable("deleted \(m.id), freed \(formatBytes(outcome.freed))" + (outcome.trashLocation.map { ", in Trash at \($0)" } ?? "")))
    } catch { print(printable(error.localizedDescription)); exit(1) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-about"), i + 1 < args.count {
    // Developer helper: writes the About view to a PNG (used for the README).
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: AboutView().background(Color(nsColor: .windowBackgroundColor)))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        }
    }
    exit(0)
}

if let i = args.firstIndex(of: "--render-window"), i + 1 < args.count {
    // Developer helper: draws the main window off-screen to a PNG (debugging, README screenshots).
    let out = URL(fileURLWithPath: args[i + 1])
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let vm = ViewModel(manageAgent: false)
        let host = NSHostingView(rootView: ContentView().environmentObject(vm).frame(width: 1400, height: 720))
        let win = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1400, height: 720),
                           styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        win.contentView = host
        win.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(6))   // let the scan finish and lay out
        let rect = host.bounds
        if let rep = host.bitmapImageRepForCachingDisplay(in: rect) {
            host.cacheDisplay(in: rect, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
        }
    }
    exit(0)
}

ModelCacheApp.main()
