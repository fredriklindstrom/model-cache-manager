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
    for m in res.models.sorted(by: { $0.exclusiveBytes > $1.exclusiveBytes }) {
        let pad = m.id.padding(toLength: 64, withPad: " ", startingAt: 0)
        print("\(pad) \(formatBytes(m.exclusiveBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) "
              + (m.lastUsed == .distantPast ? "used never" : "used \(m.lastUsed.formatted(date: .abbreviated, time: .omitted)) [\(m.lastUsedSource)]")
              + (m.inUseReason.map { "  LOCKED: \($0)" } ?? "") + (m.excluded ? "  KEEP" : "")
              + (m.projectNames.isEmpty ? "" : "  [\(m.projectNames.joined(separator: ", "))\(m.projectKept ? ", kept" : "")]"))
    }
    print("\(res.models.count) repos, \(formatBytes(res.uniqueBytes)) on disk")
    exit(0)
}

if let i = args.firstIndex(of: "--delete"), i + 1 < args.count {
    let res = CacheScanner.scan(state: Store.load())
    guard let m = res.models.first(where: { $0.id == args[i + 1] }) else { print("no such repo"); exit(1) }
    do {
        let outcome = try Deleter.delete(m, toTrash: !args.contains("--permanent"))
        print("deleted \(m.id), freed \(formatBytes(outcome.freed))" + (outcome.trashLocation.map { ", in Trash at \($0)" } ?? ""))
    } catch { print(error.localizedDescription); exit(1) }
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
