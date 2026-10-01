import AppKit
import CrossDiffCore

/// Public screenshots use generated HTTP records, never a network request or user data.
@MainActor enum APIReadmeCapture {
    typealias D = DeletionPreviewChecks
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-readme-api/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do {
                try await capture()
                guard D.failures.isEmpty else { throw D.CheckError(description: D.failures.joined(separator: "; ")) }
                print("PASS: four native API README screenshots"); exit(0)
            }
            catch { print("API README capture failed: \(error)"); exit(1) }
        }
    }
    static func capture() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        let before = fixtures.appendingPathComponent("Before.http"), after = fixtures.appendingPathComponent("After.http")
        try """
        HTTP/1.1 200 OK
        Content-Type: application/json
        Cache-Control: max-age=60
        X-Request-ID: demo-before

        {"product":{"name":"Studio headphones","price":129,"stock":12,"available":true},"shipping":{"days":3,"tracking":null},"generatedAt":"2026-10-02T09:00:00Z"}
        """.write(to: before, atomically: true, encoding: .utf8)
        try """
        HTTP/1.1 200 OK
        Content-Type: application/json
        Cache-Control: no-cache
        X-Request-ID: demo-after

        {"product":{"name":"Studio headphones","price":"119.00","stock":0,"available":false},"shipping":{"days":1,"express":true},"generatedAt":"2026-10-02T10:00:00Z"}
        """.write(to: after, atomically: true, encoding: .utf8)
        try await D.wait("own screenshot window") {
            D.window = NSApp.windows.first { $0.identifier?.rawValue == "crossdiff-main" }
            return D.window != nil
        }
        D.window.setFrame(NSRect(x: -10000, y: -10000, width: 1160, height: 760), display: true)
        NSApp.activate(ignoringOtherApps: true); D.window.makeKeyAndOrderFront(nil)
        let session = try await APIWorkflowChecks.create(left: .file(before), right: .file(after))
        WorkspaceStore.shared.sessions = [session]
        let model = session.apiComparisonModel
        try await APIWorkflowChecks.ready(model)
        model.applyRules(headers: ["X-Request-ID"], pointers: ["/generatedAt"])
        try await APIWorkflowChecks.ready(model)
        try await APIWorkflowChecks.press("api.differencesOnly")
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppSettings.shared.language = language
            for dark in [false, true] {
                AppAppearance.shared.isDark = dark
                D.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                D.window.makeFirstResponder(nil)
                try await D.pause()
                D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
                guard let full = D.window.contentView?.superview else { throw D.CheckError(description: "Missing native window") }
                _ = try D.capture(full, rect: full.bounds, name: "api-\(language == .english ? "en" : "zh-CN")-\(dark ? "dark" : "light")")
            }
        }
    }
}
