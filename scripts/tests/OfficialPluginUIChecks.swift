import AppKit
import SwiftUI
import CrossDiffCore

@MainActor enum OfficialPluginUIChecks {
    typealias D = DeletionPreviewChecks
    static var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).deletingLastPathComponent() }
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-official-plugin-ui/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: official catalog native UI in Chinese/English, light/dark and 650-point minimum width" : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? verdict.write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        let manager = PluginManager(directory: root.appendingPathComponent("catalog-data-" + UUID().uuidString),
            bundledDirectory: root.appendingPathComponent("Plugins"), catalogURL: root.appendingPathComponent("OfficialPlugins.json"))
        D.check(manager.officialPlugins.count == 2 && manager.officialCatalogError == nil, "two official catalog cards load offline")
        D.check(manager.plugin(id: "org.crossdiff.archive")?.bundled == true && manager.plugin(id: "org.crossdiff.pdf") == nil, "Base shows bundled Archive and downloadable PDF")
        D.window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 720, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        D.window.title = "CrossDiff"
        D.window.contentView = NSHostingView(rootView: PluginManagerView(manager: manager))
        D.window.orderFront(nil)
        for english in [false, true] {
            AppSettings.shared.language = english ? .english : .simplifiedChinese
            for dark in [false, true] {
                for width in [720.0, 650.0] {
                    AppAppearance.shared.isDark = dark
                    D.window.setContentSize(NSSize(width: width, height: 660))
                    D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                    try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
                    let view = D.window.contentView!.superview ?? D.window.contentView!
                    let name = "plugins-official-\(english ? "en" : "zh")-\(dark ? "dark" : "light")-\(Int(width))"
                    let bitmap = try D.capture(view, rect: view.bounds, name: name)
                    D.check(bitmap.pixelsWide >= Int(width) && bitmap.pixelsHigh >= 660, name + " full native window captured")
                    var contrast = 0
                    for y in stride(from: 80, to: bitmap.pixelsHigh - 60, by: 3) {
                        for x in stride(from: 30, to: bitmap.pixelsWide - 30, by: 3) {
                            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                                if dark ? min(color.redComponent, color.greenComponent, color.blueComponent) > 0.7 : max(color.redComponent, color.greenComponent, color.blueComponent) < 0.45 { contrast += 1 }
                            }
                        }
                    }
                    D.check(contrast > 180, name + " readable contrasting text rendered")
                    D.check(!manager.downloading && manager.pendingPackage == nil && manager.plugins.count == 1, name + " viewing catalog changes no installation")
                }
            }
        }
        D.window.orderOut(nil)
    }
}
