import AppKit
import CrossDiffCore

/// Real native windows with synthetic, path-free examples for the public README.
@MainActor
enum ReadmeRenders {
    typealias D = DeletionPreviewChecks

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-readme/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do {
                try await render()
                print("Rendered bilingual light/dark comparison, deletion-preview and new-comparison windows.")
                exit(0)
            } catch {
                print("README rendering failed: \(error)")
                exit(1)
            }
        }
    }

    static func render() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        try await D.wait("own README window") {
            D.window = NSApp.windows.first { $0.identifier?.rawValue == "crossdiff-main" }
            return D.window != nil
        }
        D.window.setFrame(NSRect(x: -10000, y: -10000, width: 1160, height: 720), display: true)
        D.window.orderFront(nil)
        let left = """
        // A small change. A clearer picture.
        struct CompareOptions {
            var theme = "light"
            var fontSize = 14

            var alignChangedLines = false
            var syncScrolling = true
            var legacyMode = true

            let title = "Make every change visible."
        }

        let formats = ["Text", "Folders"]
        let greeting = "Hello, CrossDiff 👋"

        // Your files stay on your Mac.
        """
        let right = """
        // A small change. A clearer picture.
        struct CompareOptions {
            var theme = "dark"
            var fontSize = 16

            var alignChangedLines = true
            var syncScrolling = true

            let title = "Make every detail visible."
        }

        let formats = ["Text", "Folders", "Images", "Hex", "Archives"]
        let greeting = "你好，CrossDiff 👋"

        // Your files stay on your Mac.
        """
        let session = try await D.mount(left: left, right: right)
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppSettings.shared.language = language
            let locale = language == .english ? "en" : "zh-CN"
            for dark in [false, true] {
                AppAppearance.shared.isDark = dark
                D.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for preview in [false, true] {
                    session.showDeletions = preview
                    if preview { try await D.ready(session) } else { try await D.pause() }
                    D.window.makeFirstResponder(nil)
                    D.window.contentView?.layoutSubtreeIfNeeded()
                    try await D.pause()
                    guard let full = D.window.contentView?.superview else { throw D.CheckError(description: "Missing full native window") }
                    let name = "\(preview ? "deletions" : "text")-\(locale)-\(dark ? "dark" : "light")"
                    _ = try D.capture(full, rect: full.bounds, name: name)
                }
                WorkspaceStore.shared.beginNewComparison()
                try await D.wait("new comparison sheet") { D.window.attachedSheet?.contentView != nil }
                try await D.pause()
                guard let sheet = D.window.attachedSheet, let full = sheet.contentView?.superview else {
                    throw D.CheckError(description: "Missing native type chooser")
                }
                sheet.contentView?.layoutSubtreeIfNeeded()
                _ = try D.capture(full, rect: full.bounds, name: "new-\(locale)-\(dark ? "dark" : "light")")
                WorkspaceStore.shared.newComparison?.cancel()
                try await D.wait("type chooser dismissed") { D.window.attachedSheet == nil }
            }
        }
    }
}
