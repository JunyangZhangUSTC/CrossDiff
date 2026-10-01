import AppKit
import SwiftUI
import CoreText
import PDFKit
import CryptoKit
import CrossDiffCore

@MainActor
enum PluginWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).deletingLastPathComponent() }
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-plugin-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: plugin install/enable/remove/recovery, actual external JSON algorithm, PDF page/text native UI, light/dark/English/narrow windows, immutable sources" : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? verdict.write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        D.window = NativeMenuController.shared.comparisonWindow
        guard D.window != nil else { throw PluginValidationError.invalidField("native window") }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        let manager = PluginManager.shared, store = WorkspaceStore.shared
        // This harness owns an isolated project-local workspace on every run.
        let emptySession = ComparisonSession()
        store.sessions = [emptySession]; store.selectedID = emptySession.id
        D.check(manager.plugin(id: "org.crossdiff.pdf")?.enabled == true, "bundled PDF registered and enabled")
        let packageURL = root.appendingPathComponent("JSON.crossdiffplugin")
        let example = try PluginPackage.load(from: packageURL)
        if manager.plugin(id: example.manifest.id) != nil { manager.uninstall(example.manifest.id) }
        manager.inspect(packageURL)
        D.check(manager.pendingPackage?.manifest.id == example.manifest.id && manager.plugin(id: example.manifest.id) == nil, "opening package previews before installing")
        manager.installPending(trustNative: false)
        D.check(manager.plugin(id: example.manifest.id)?.enabled == true, "restricted third-party package installs without native trust")
        try await D.pause()
        let pluginWindow = NSApp.windows.first { $0.identifier?.rawValue == "crossdiff-plugins" }!
        try await render(pluginWindow, name: "plugins-light", dark: false, width: 690)
        try await render(pluginWindow, name: "plugins-dark", dark: true, width: 650)
        AppSettings.shared.language = .english
        try await render(pluginWindow, name: "plugins-english", dark: false, width: 690)
        pluginWindow.orderOut(nil)
        let a = root.appendingPathComponent("left.cdjson"), b = root.appendingPathComponent("right.cdjson")
        try "{\"name\":\"CrossDiff\",\"version\":1,\"removed\":true}".write(to: a, atomically: true, encoding: .utf8)
        try "{\"name\":\"CrossDiff\",\"version\":2,\"added\":\"本地\"}".write(to: b, atomically: true, encoding: .utf8)
        let originals = [try Data(contentsOf: a), try Data(contentsOf: b)]
        store.accept([a, b])
        try await D.wait("external plugin session") { store.selected?.pluginID == example.manifest.id }
        let session = store.selected!
        try await D.wait("external algorithm completes") { session.pluginTableModel.result != nil || session.pluginTableModel.error != nil }
        D.check(session.pluginTableModel.rows.count == 4 && session.pluginTableModel.rows.filter { $0.state != "same" }.count == 3, "third-party algorithm returns real semantic changes")
        try await render(D.window, name: "json-table-light", dark: false, width: 1100)
        try await render(D.window, name: "json-table-dark-narrow", dark: true, width: 860)
        manager.setEnabled(false, id: example.manifest.id)
        try await D.pause()
        D.check(store.selected?.id == session.id && store.selected?.pluginID == example.manifest.id, "disable retains comparison session")
        try await render(D.window, name: "plugin-missing", dark: false, width: 860)
        manager.setEnabled(true, id: example.manifest.id)
        try await D.wait("re-enabled result") { session.pluginTableModel.result != nil }
        D.check(store.persistNow(), "plugin session persisted")
        let recovered = try SessionFile.load(from: root.appendingPathComponent("data/sessions.json"))
        D.check(recovered.contains { $0.id == session.id && $0.pluginID == example.manifest.id }, "plugin identity survives persistence")
        manager.uninstall(example.manifest.id)
        D.check(store.sessions.contains { $0.id == session.id } && manager.plugin(id: example.manifest.id) == nil, "uninstall retains session but removes capability")
        manager.inspect(packageURL); manager.installPending(trustNative: false)
        let pdfA = root.appendingPathComponent("draft.pdf"), pdfB = root.appendingPathComponent("revision.pdf")
        try writePDF(pdfA, pages: [("CrossDiff Research", "Native comparison, local files."), ("Results", "Version one: 14 samples.")])
        try writePDF(pdfB, pages: [("CrossDiff Research", "Native comparison, local files."), ("New Methods", "An inserted page."), ("Results", "Version two: 28 samples.")])
        let pdfBytes = [try Data(contentsOf: pdfA), try Data(contentsOf: pdfB)]
        store.accept([pdfA, pdfB])
        try await D.wait("PDF session") { store.selected?.pluginID == "org.crossdiff.pdf" }
        let pdf = store.selected!
        try await D.wait("PDF plugin result") { pdf.pdfComparisonModel.result != nil || pdf.pdfComparisonModel.error != nil }
        if let error = pdf.pdfComparisonModel.error { throw error }
        D.check(pdf.pdfComparisonModel.pairs.count == 3 && pdf.pdfComparisonModel.pairs.contains { $0.kind == .added }, "PDF plugin aligns inserted page")
        let externalManager = PluginManager(directory: root.appendingPathComponent("external-pdf-data-" + UUID().uuidString),
                                            bundledDirectory: root.appendingPathComponent("empty-bundled"))
        externalManager.pendingPackage = try PluginPackage.load(from: root.appendingPathComponent("Plugins/PDF.crossdiffplugin"))
        externalManager.installPending(trustNative: false)
        D.check(externalManager.plugin(id: "org.crossdiff.pdf")?.bundled == false && externalManager.plugin(id: "org.crossdiff.pdf")?.enabled == true,
                "Official PDF package installs through the external local-install path in a base edition")
        let externalExecution = try externalManager.execution(for: "org.crossdiff.pdf")
        let externalPDF = PDFComparisonModel()
        await externalPDF.load(left: pdfA, right: pdfB, execute: { try await externalExecution.compare($0) })
        D.check(externalPDF.error == nil && externalPDF.pairs.count == 3 && externalPDF.pairs.contains { $0.kind == .added },
                "Locally installed official PDF runs the same actual external algorithm")
        AppSettings.shared.language = .simplifiedChinese
        try await render(D.window, name: "pdf-pages-light", dark: false, width: 1220)
        try await render(D.window, name: "pdf-pages-dark-narrow", dark: true, width: 860)
        pdf.pdfComparisonModel.selectedIndex = 2; pdf.pdfComparisonModel.mode = .text
        try await D.wait("PDF text difference") { pdf.pdfComparisonModel.textDiff != nil }
        D.check(pdf.pdfComparisonModel.textDiff?.hunks.isEmpty == false, "PDF text difference is visible")
        try await render(D.window, name: "pdf-text-light", dark: false, width: 1220)
        AppSettings.shared.language = .english
        try await render(D.window, name: "pdf-text-english-narrow", dark: true, width: 860)
        D.check(try [Data(contentsOf: a), Data(contentsOf: b)] == originals, "text plugin leaves originals unchanged")
        D.check(try [Data(contentsOf: pdfA), Data(contentsOf: pdfB)] == pdfBytes, "PDF plugin leaves originals unchanged")
        // Extension declarations must not hijack existing native image routing.
        let collisionManifest = PluginManifest(id: "example.crossdiff.image-extension", version: "0.1.0",
            name: example.manifest.name, summary: example.manifest.summary, runtime: .restrictedJavaScript,
            inputKind: .text, fileExtensions: ["png"], resultView: "table")
        let collision = PluginPackage(manifest: collisionManifest, script: example.script, sha256: example.sha256)
        manager.pendingPackage = collision; manager.installPending(trustNative: false)
        let pngA = root.appendingPathComponent("route-left.png"), pngB = root.appendingPathComponent("route-right.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: pngA); try png.write(to: pngB)
        store.accept([pngA, pngB])
        try await D.wait("native image route") { store.selected?.kind == .image }
        D.check(store.selected?.pluginID == nil, "plugin extension does not override native image opening")
        manager.uninstall(collision.manifest.id)
        let folderA = root.appendingPathComponent("directory-left.pdf"), folderB = root.appendingPathComponent("directory-right.pdf")
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        store.accept([folderA, folderB])
        try await D.wait("directory extension route") { store.selected?.kind == .folder }
        D.check(store.selected?.pluginID == nil, "folder ending in pdf remains a folder")
        let legacy = Data("[{\"id\":\"\(UUID())\",\"kind\":\"text\",\"left\":{\"text\":\"old\",\"encoding\":\"utf8\",\"savedText\":\"\"},\"right\":{\"text\":\"\",\"encoding\":\"utf8\",\"savedText\":\"\"}}]".utf8)
        D.check((try JSONDecoder().decode([StoredComparison].self, from: legacy)).first?.pluginID == nil, "old sessions without pluginID still decode")
    }
    static func render(_ window: NSWindow, name: String, dark: Bool, width: Double) async throws {
        AppAppearance.shared.isDark = dark
        window.setContentSize(NSSize(width: width, height: 700)); window.orderFront(nil)
        try await D.pause(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let view = window.contentView!.superview ?? window.contentView!
        let bitmap = try D.capture(view, rect: view.bounds, name: name)
        D.check(bitmap.pixelsWide > 600 && bitmap.pixelsHigh > 400, "\(name) full parent view rendered")
        if name == "pdf-pages-light" || name == "pdf-pages-dark-narrow" {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let pages = descendants(view).filter { $0.identifier?.rawValue == "pdf.page.canvas" }
            D.check(pages.count == 2, "PDF has two native page surfaces")
            for (index, page) in pages.enumerated() {
                let pageRegion = page.convert(page.bounds, to: view).intersection(view.bounds)
                let rendered = try D.capture(view, rect: pageRegion, name: "\(name)-page-\(index)")
                var ink = 0
                for y in stride(from: rendered.pixelsHigh / 10, to: rendered.pixelsHigh * 9 / 10, by: 2) {
                    for x in stride(from: rendered.pixelsWide / 5, to: rendered.pixelsWide * 4 / 5, by: 2) {
                        if let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.redComponent < 0.4, color.greenComponent < 0.4, color.blueComponent < 0.4 { ink += 1 }
                    }
                }
                D.check(ink > 50, "PDF parent rendering includes visible title and body ink (\(name), side \(index))")
            }
        }
    }
    static func writePDF(_ url: URL, pages: [(String, String)]) throws {
        var bounds = CGRect(x: 0, y: 0, width: 480, height: 640)
        guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw PluginValidationError.invalidField("PDF fixture") }
        for (title, body) in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            func line(_ string: String, y: CGFloat, size: CGFloat) {
                let text = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
                context.textPosition = CGPoint(x: 42, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            line(title, y: 550, size: 25); line(body, y: 495, size: 14)
            line("CrossDiff · Local document comparison", y: 60, size: 10)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
