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
        let folderModel = folder.folderComparisonModel
        store.sessions = [folder]; store.selectedID = folder.id; store.message = nil
        try await prepareSurfaceWindow()
        try await D.wait("folder table loads isolated content") {
            folderModel.result?.isComplete == true && !folderModel.scanning && !folderModel.filtering &&
                nativeSurfaceViews().compactMap { $0 as? NSTableView }.contains { $0.numberOfRows == 3 }
        }
        let scanCount = folderModel.scanCount, completedAt = folderModel.completedAt
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppSettings.shared.language = language
            try await D.pause()
            let english = language == .english
            D.check(status.title == (english ? "Left Only" : "仅左侧"), "existing folder status follows the selected language without rescanning")
            D.check(localizedErrorDescription(error).contains(english ? "Compare again" : "请重新比较"), "existing folder error follows the selected language")
            D.check(scan.ignoredCount == 1 && scan.entries.count == 4, "folder fixture includes changed, one-sided, identical, and ignored items")
            let text = surfaceAccessibilityText()
            // Tree mode now has paired Name columns and a richer To Review
            // filter. Relative Path belongs to List mode, not this default view.
            let expected = english
                ? ["Left · left", "Right · right", "Change Left Folder", "Change Right Folder", "Folder View", "Tree", "List", "To Review", "Compare Again"]
                : ["左侧 · left", "右侧 · right", "更换左侧文件夹", "更换右侧文件夹", "目录展示", "目录", "列表", "需关注", "重新比较"]
            let labels = Set(text.components(separatedBy: "\n"))
            D.check(expected.allSatisfy(labels.contains), "paired folder controls and source titles are fully localized in \(language.rawValue)")
            let identifiers = Set(surfaceAccessibilityText(attributes: ["accessibilityIdentifier"]).components(separatedBy: "\n"))
            let controls = ["folders.replace-left", "folders.replace-right", "folders.mode", "folders.filter", "folders.status-filter", "folders.reload", "folders.paired-table"]
            D.check(controls.allSatisfy(identifiers.contains), "localized folder labels belong to the actual input, mode, filter and reload controls")
            let tables = nativeSurfaceViews().compactMap { $0 as? NSTableView }
            D.check(tables.count == 1 && tables.first?.numberOfRows == 3, "both folder sides share one visible paired table in \(language.rawValue)")
            if let table = tables.first {
                let columns = table.tableColumns.filter { !$0.isHidden }
                D.check(columns.map { $0.identifier.rawValue } == ["leftName", "leftSize", "status", "rightName", "rightSize"],
                        "default folder columns retain both names and sizes around the shared status")
                let expectedHeaders = english ? ["Name", "Size", "Status", "Name", "Size"] : ["名称", "大小", "状态", "名称", "大小"]
                D.check(columns.map { $0.headerCell.stringValue } == expectedHeaders,
                        "actual AppKit folder headers refresh in \(language.rawValue)")
            }
            D.check(nativeSurfaceViews().compactMap { $0 as? NSTextField }.contains {
                $0.isEditable && $0.placeholderString == (english ? "Search relative paths" : "搜索相对路径")
            }, "folder path search placeholder is localized in \(language.rawValue)")
            D.check(folderModel.browserMode == .tree && folderModel.statusFilter == .differences &&
                    folderModel.scanCount == scanCount && folderModel.completedAt == completedAt,
                    "language switching keeps the current tree/filter and completed comparison without rescanning")
            D.check(folder.left.path == leftFolder.path && folder.right.path == rightFolder.path &&
                    folderModel.result?.leftRoot.path == leftFolder.path && folderModel.result?.rightRoot.path == rightFolder.path,
                    "language switching preserves both folder input associations and result roots")
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
    private static func surfaceAccessibilityText(attributes: [String] = ["accessibilityLabel", "accessibilityValue", "title", "stringValue"]) -> String {
        var seen = Set<ObjectIdentifier>()
        var strings: [String] = []
        func descend(_ object: NSObject, depth: Int) {
            guard depth < 40, seen.insert(ObjectIdentifier(object)).inserted else { return }
            for name in attributes {
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
