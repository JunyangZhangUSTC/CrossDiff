import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
extension WorkflowChecks {
    /// Mounts the actual folder/image workspace views with fixtures created only
    /// inside the isolated render directory. Uses neither the system clipboard
    /// nor desktop capture; D.capture renders this process's native view tree.
    static func checkTranslatedSurfaces() async throws {
        D.log("Checking live folder and image translations at the minimum window width")
        let store = WorkspaceStore.shared
        let previousSessions = store.sessions
        let previousSelection = store.selectedID
        let previousLanguage = AppSettings.shared.language
        let previousAppearance = AppAppearance.shared.isDark
        let previousFrame = D.window.frame
        let previousWindowAppearance = D.window.appearance
        defer {
            store.sessions = previousSessions
            store.selectedID = previousSelection
            AppSettings.shared.language = previousLanguage
            AppAppearance.shared.isDark = previousAppearance
            D.window.appearance = previousWindowAppearance
            D.window.setFrame(previousFrame, display: true)
        }

        let fixtures = D.output.appendingPathComponent("surface-fixtures", isDirectory: true)
        let leftFolder = fixtures.appendingPathComponent("left", isDirectory: true)
        let rightFolder = fixtures.appendingPathComponent("right", isDirectory: true)
        for folder in [leftFolder, rightFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "unchanged\n".write(to: folder.appendingPathComponent("identical.txt"), atomically: true, encoding: .utf8)
        }
        try "let fontSize = 14\n".write(to: leftFolder.appendingPathComponent("options.swift"), atomically: true, encoding: .utf8)
        try "let fontSize = 16\n".write(to: rightFolder.appendingPathComponent("options.swift"), atomically: true, encoding: .utf8)
        try "removed file\n".write(to: leftFolder.appendingPathComponent("left-only.txt"), atomically: true, encoding: .utf8)
        try "new file\n".write(to: rightFolder.appendingPathComponent("right-only.txt"), atomically: true, encoding: .utf8)
        let ignored = leftFolder.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try "isolated fixture\n".write(to: ignored.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let scan = try FolderComparison.scan(left: leftFolder, right: rightFolder)
        let status = scan.entries.first { $0.path == "left-only.txt" }!.status
        let error: Error = FolderComparisonError.stale("options.swift")
        let folder = ComparisonSession(kind: .folder, left: .init(path: leftFolder.path), right: .init(path: rightFolder.path))
        store.sessions = [folder]; store.selectedID = folder.id; store.message = nil
        try await prepareSurfaceWindow()
        try await D.wait("folder table loads isolated content") {
            nativeSurfaceViews().compactMap { $0 as? NSTableView }.contains { $0.numberOfRows >= 3 }
        }
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppSettings.shared.language = language
            try await D.pause()
            let english = language == .english
            D.check(status.title == (english ? "Left Only" : "仅左侧"), "existing folder status follows the selected language without rescanning")
            D.check(localizedErrorDescription(error).contains(english ? "Compare again" : "请重新比较"), "existing folder error follows the selected language")
            D.check(scan.ignoredCount == 1 && scan.entries.count == 4, "folder fixture includes changed, one-sided, identical, and ignored items")
            let text = surfaceAccessibilityText()
            let expected = english ? ["Relative Path", "Differences Only", "Compare Again"] : ["相对路径", "仅显示差异", "重新比较"]
            D.check(expected.allSatisfy { text.contains($0) }, "folder view exposes all controls in \(language.rawValue)")
            try captureSurface("folder-" + (english ? "en" : "zh"), accessibilityText: text)
        }

        let leftImage = fixtures.appendingPathComponent("image-before.png")
        let rightImage = fixtures.appendingPathComponent("image-after.png")
        try writeSurfacePNG(to: leftImage, modified: false)
        try writeSurfacePNG(to: rightImage, modified: true)
        let images = ComparisonSession(kind: .image, left: .init(path: leftImage.path), right: .init(path: rightImage.path))
        store.sessions = [images]; store.selectedID = images.id
        try await D.pause()
        try await D.wait("image previews finish loading") {
            let text = surfaceAccessibilityText()
            return text.contains("image-before.png") && text.contains("image-after.png")
        }
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppSettings.shared.language = language
            try await D.pause()
            let english = language == .english
            let text = surfaceAccessibilityText()
            let expected = english ? ["Comparison Mode", "Side by Side", "Pixel Difference", "Zoom"] : ["比较方式", "并排", "像素差异", "缩放"]
            D.check(expected.allSatisfy { text.contains($0) }, "image view exposes all controls in \(language.rawValue)")
            D.check(images.left.path == leftImage.path && images.right.path == rightImage.path, "language switching preserves image file associations")
            try captureSurface("image-" + (english ? "en" : "zh"), accessibilityText: text)
        }
        D.log("Folder and image views rendered in English and Simplified Chinese at 860 pixels")
    }

    private static func prepareSurfaceWindow() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                AppAppearance.shared.isDark = false
                D.window.appearance = NSAppearance(named: .aqua)
                D.window.setFrame(NSRect(x: -10000, y: -10000, width: 860, height: 580), display: true)
                D.window.makeKeyAndOrderFront(nil)
                D.window.contentView?.layoutSubtreeIfNeeded()
                continuation.resume()
            }
        }
        try await D.pause()
    }

    private static func nativeSurfaceViews() -> [NSView] {
        func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
        return D.window.contentView.map(descend) ?? []
    }

    /// Read this process's accessibility objects directly. SwiftUI exposes some
    /// controls as virtual children, so NSView.subviews alone misses their labels.
    /// Check only our expected labels; file names and OS-supplied strings are data.
    private static func surfaceAccessibilityText() -> String {
        var seen = Set<ObjectIdentifier>()
        var strings: [String] = []
        func descend(_ object: NSObject, depth: Int) {
            guard depth < 40, seen.insert(ObjectIdentifier(object)).inserted else { return }
            for name in ["accessibilityLabel", "accessibilityValue", "title", "stringValue"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty {
                    strings.append(value)
                }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for child in values { descend(child, depth: depth + 1) }
            }
            if let view = object as? NSView {
                for child in view.subviews { descend(child, depth: depth + 1) }
            }
        }
        if let view = D.window.contentView { descend(view, depth: 0) }
        return strings.joined(separator: "\n")
    }

    private static func captureSurface(_ name: String, accessibilityText: String) throws {
        D.window.contentView?.layoutSubtreeIfNeeded()
        guard let full = D.window.contentView?.superview else {
            throw D.CheckError(description: "Missing native window content for \(name)")
        }
        _ = try D.capture(full, rect: full.bounds, name: name)
        try accessibilityText.write(to: D.output.appendingPathComponent(name + "-accessibility.txt"), atomically: true, encoding: .utf8)
        D.log("Rendered \(name)")
    }

    private static func writeSurfacePNG(to url: URL, modified: Bool) throws {
        let width = 160, height = 110
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw D.CheckError(description: "Unable to allocate isolated PNG fixture")
        }
        for y in 0..<height {
            for x in 0..<width {
                let blue = (24..<124).contains(x) && (20..<86).contains(y)
                let change = modified && (76..<136).contains(x) && (44..<98).contains(y)
                let color = change ? NSColor(deviceRed: 1, green: 0.55, blue: 0.1, alpha: 1)
                    : blue ? NSColor(deviceRed: 0.15, green: 0.45, blue: 0.85, alpha: 1)
                    : NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
                bitmap.setColor(color, atX: x, y: y)
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw D.CheckError(description: "Unable to encode isolated PNG fixture")
        }
        try data.write(to: url)
    }
}
