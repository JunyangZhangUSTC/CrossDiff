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
            let verdict = D.failures.isEmpty ? "PASS: native installed/discover tabs, uninstall/remove confirmation and cancellation, offline restore, Chinese/English, light/dark and 650-point minimum width" : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? (D.report + [verdict]).joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        let manager = PluginManager(directory: root.appendingPathComponent("catalog-data-" + UUID().uuidString),
            bundledDirectory: root.appendingPathComponent("Plugins"), catalogURL: root.appendingPathComponent("OfficialPlugins.json"))
        D.check(manager.officialPlugins.count == 4 && manager.officialCatalogError == nil, "four official catalog cards load offline")
        D.check(manager.plugin(id: "org.crossdiff.archive")?.bundled == true && manager.plugin(id: "org.crossdiff.pdf") == nil && manager.plugin(id: "org.crossdiff.photography") == nil && manager.plugin(id: "org.crossdiff.api") == nil, "Base shows bundled Archive and downloadable PDF, Photography and API")
        let archiveURL = root.appendingPathComponent("Plugins/Archive.crossdiffplugin")
        let archiveBytes = try Data(contentsOf: archiveURL)
        manager.pendingPackage = try PluginPackage.load(from: root.appendingPathComponent("PDF.crossdiffplugin"))
        manager.installPending(trustNative: false)
        D.check(manager.plugin(id: "org.crossdiff.pdf")?.bundled == false, "PDF fixture is an external installation")
        D.window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 720, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        D.window.title = "CrossDiff"
        D.window.contentView = NSHostingView(rootView: PluginManagerView(manager: manager))
        D.window.orderFront(nil)
        AppSettings.shared.language = .simplifiedChinese
        try await D.pause()
        D.check(has("plugins.remove.org.crossdiff.archive") && has("plugins.uninstall.org.crossdiff.pdf"), "default Installed page exposes removal and uninstall directly on cards")
        for english in [false, true] {
            AppSettings.shared.language = english ? .english : .simplifiedChinese
            for dark in [false, true] {
                for width in [720.0, 650.0] {
                    try await render("plugins-installed-\(english ? "en" : "zh")-\(dark ? "dark" : "light")-\(Int(width))", dark: dark, width: width)
                    D.check(has("plugins.remove.org.crossdiff.archive") && has("plugins.uninstall.org.crossdiff.pdf"), "installed controls remain accessible across language, appearance and width changes")
                    D.check(manager.plugins.count == 2 && manager.pendingPackage == nil, "browsing Installed leaves installations unchanged")
                }
            }
        }
        // Use real card controls and the actual confirmation UI, never call the
        // manager's removal methods to satisfy these interaction checks.
        AppSettings.shared.language = .simplifiedChinese
        AppAppearance.shared.isDark = false
        try await D.pause()
        try await press("plugins.uninstall.org.crossdiff.pdf")
        try await renderConfirmation("plugins-uninstall-confirm-zh", dark: false)
        D.check(manager.plugin(id: "org.crossdiff.pdf") != nil, "opening uninstall confirmation does not uninstall")
        try await press("plugins.removal.cancel", fallback: "取消")
        D.check(manager.plugin(id: "org.crossdiff.pdf") != nil, "canceling uninstall retains the external plugin")
        try await press("plugins.uninstall.org.crossdiff.pdf")
        try await press("plugins.removal.confirm", fallback: "卸载")
        try await D.wait("external plugin uninstalled") { manager.plugin(id: "org.crossdiff.pdf") == nil }
        D.check(!has("plugins.uninstall.org.crossdiff.pdf"), "confirmed uninstall removes external card from Installed")
        D.check(manager.plugin(id: "org.crossdiff.archive")?.enabled == true, "external uninstall preserves bundled plugins")
        AppSettings.shared.language = .english
        AppAppearance.shared.isDark = true
        try await D.pause()
        try await press("plugins.remove.org.crossdiff.archive")
        try await renderConfirmation("plugins-remove-confirm-en-dark", dark: true)
        try await press("plugins.removal.cancel", fallback: "Cancel")
        D.check(manager.plugin(id: "org.crossdiff.archive")?.enabled == true, "canceling bundled removal retains capability")
        try await press("plugins.remove.org.crossdiff.archive")
        try await press("plugins.removal.confirm", fallback: "Remove")
        try await D.wait("bundled plugin removed") { manager.plugin(id: "org.crossdiff.archive") == nil }
        D.check(manager.removedBundledPlugins.contains { $0.id == "org.crossdiff.archive" }, "removed bundled plugin is available for local recovery")
        D.check(try Data(contentsOf: archiveURL) == archiveBytes, "bundled removal never mutates app resource bytes")
        try await render("plugins-installed-removed-en-dark-650", dark: true, width: 650)
        try await selectPage("Discover")
        D.check(has("plugins.restore.org.crossdiff.archive") || titledAction("Restore") != nil, "Discover offers offline restoration of removed bundled Archive")
        D.check(!has("plugins.official.install.org.crossdiff.archive"), "bundled restoration is offered instead of a download")
        try await render("plugins-discover-restore-en-dark-650", dark: true, width: 650)
        try await press("plugins.restore.org.crossdiff.archive", fallback: "Restore")
        try await D.wait("bundled plugin restored") { manager.plugin(id: "org.crossdiff.archive")?.enabled == true }
        D.check(!manager.downloading && manager.removedBundledPlugins.isEmpty, "restore completes offline with no installation review")
        for english in [false, true] {
            AppSettings.shared.language = english ? .english : .simplifiedChinese
            for dark in [false, true] {
                for width in [720.0, 650.0] {
                    try await render("plugins-official-\(english ? "en" : "zh")-\(dark ? "dark" : "light")-\(Int(width))", dark: dark, width: width)
                    D.check(!manager.downloading && manager.pendingPackage == nil && manager.plugins.count == 1, "viewing Discover changes no installation")
                }
            }
        }
        try await selectPage("Installed")
        D.check(has("plugins.remove.org.crossdiff.archive"), "restored plugin returns to Installed with removal control")
        D.check(try Data(contentsOf: archiveURL) == archiveBytes, "full removal/restore workflow preserves bundled resources")
        D.window.orderOut(nil)
    }
    static func render(_ name: String, dark: Bool, width: Double) async throws {
        AppAppearance.shared.isDark = dark
        D.window.setContentSize(NSSize(width: width, height: 660))
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
        let view = D.window.contentView!.superview ?? D.window.contentView!
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
    }
    static func renderConfirmation(_ name: String, dark: Bool) async throws {
        D.check(AppAppearance.shared.isDark == dark, "confirmation uses the appearance selected before opening")
        try await D.pause()
        guard let window = D.window.attachedSheet else { throw D.CheckError(description: "Missing actual native confirmation sheet") }
        guard let content = window.contentView else { throw D.CheckError(description: "Missing confirmation window") }
        content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let parent = content.superview ?? content
        let bitmap = try D.capture(parent, rect: parent.bounds, name: name)
        let canvas = ComparisonTheme(isDark: dark).canvas.usingColorSpace(.deviceRGB)!
        var background = 0, sampled = 0
        for y in stride(from: 12, to: bitmap.pixelsHigh - 12, by: 3) {
            for x in stride(from: 12, to: bitmap.pixelsWide - 12, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                sampled += 1
                if max(abs(color.redComponent - canvas.redComponent), abs(color.greenComponent - canvas.greenComponent), abs(color.blueComponent - canvas.blueComponent)) < 0.08 { background += 1 }
            }
        }
        D.check(sampled > 0 && background > sampled / 2, name + " confirmation background matches the selected theme")
        // Crop the composed sheet at the actual accessibility frames so a red
        // confirmation button cannot disguise invisible title/body text.
        for part in ["title", "message"] {
            let identifier = "plugins.removal." + part
            guard let object = objects().first(where: { string($0, "accessibilityIdentifier") == identifier }) else {
                throw D.CheckError(description: "Missing confirmation text: \(identifier)")
            }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector) else { throw D.CheckError(description: "Missing confirmation text frame") }
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            let screen = unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
            let frame = parent.convert(window.convertFromScreen(screen), from: nil).intersection(parent.bounds)
            guard frame.width > 20 && frame.height > 8 else { throw D.CheckError(description: "Confirmation text is outside the visible sheet") }
            let region = try D.capture(parent, rect: frame, name: name + "-" + part)
            var textPixels = 0
            for y in stride(from: 0, to: region.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: region.pixelsWide, by: 2) {
                    guard let color = region.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if dark ? min(color.redComponent, color.greenComponent, color.blueComponent) > 0.55 : max(color.redComponent, color.greenComponent, color.blueComponent) < 0.55 { textPixels += 1 }
                }
            }
            D.check(textPixels > 30, name + " " + part + " contains readable contrasting text in the composed sheet")
        }
    }
    static func has(_ identifier: String) -> Bool { objects().contains { string($0, "accessibilityIdentifier") == identifier } }
    static func press(_ identifier: String, fallback: String? = nil) async throws {
        let matches = objects().filter { string($0, "accessibilityIdentifier") == identifier }
        if let object = matches.first(where: { $0 is NSControl }) ?? matches.first {
            try perform(object)
        } else if let fallback, let object = titledAction(fallback) {
            try perform(object)
        } else { throw D.CheckError(description: "Missing native control: \(identifier)") }
        try await D.pause()
    }
    static func titledAction(_ title: String) -> NSObject? {
        let action = NSSelectorFromString("accessibilityPerformPress")
        let matches = objects().filter {
            (string($0, "accessibilityLabel") == title || ($0 as? NSButton)?.title == title) &&
                ($0 is NSButton || string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue) && $0.responds(to: action)
        }
        return matches.first(where: { $0 is NSButton }) ?? matches.first
    }
    static func selectPage(_ title: String) async throws {
        let elements = objects()
        if let control = elements.compactMap({ $0 as? NSSegmentedControl }).first(where: { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == title }
        }), let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == title }) {
            control.selectedSegment = index
            _ = control.sendAction(control.action, to: control.target)
        } else {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard let object = elements.first(where: { string($0, "accessibilityLabel") == title && $0.responds(to: selector) }) else {
                throw D.CheckError(description: "Missing native plugin page: \(title)")
            }
            try perform(object)
        }
        try await D.pause()
    }
    static func perform(_ object: NSObject) throws {
        if let button = object as? NSButton { button.performClick(nil); return }
        let action = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: action) else { throw D.CheckError(description: "Control cannot press") }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        // SwiftUI's AX bridge can return false after dispatching successfully.
        // Callers verify the actual sheet, installation and capability changes.
        _ = unsafeBitCast(object.method(for: action), to: Action.self)(object, action)
    }
    static func objects() -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func descend(_ object: NSObject, depth: Int) {
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
            guard depth < 45, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { for child in children { descend(child, depth: depth + 1) } }
            if let view = object as? NSView { for child in view.subviews { descend(child, depth: depth + 1) } }
        }
        if let view = D.window.contentView { descend(view, depth: 0) }
        if let view = D.window.attachedSheet?.contentView { descend(view, depth: 0) }
        return result
    }
    static func string(_ object: NSObject, _ attribute: String) -> String {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
}
