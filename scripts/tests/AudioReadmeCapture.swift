import AppKit
import CrossDiffCore

/// Public screenshots of the actual window, with project-local synthetic audio.
/// Uses normal creation, Apple analysis and the real Olaf helper; never auditions.
@MainActor
enum AudioReadmeCapture {
    typealias D = DeletionPreviewChecks
    typealias A = AudioWorkflowChecks
    static var root: URL { D.output.deletingLastPathComponent() }

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-audio-readme/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-audio-readme/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do {
                try await capture()
                guard D.failures.isEmpty else { throw D.CheckError(description: D.failures.joined(separator: "; ")) }
                print("Rendered four actual audio windows; real decode/STFT and matching, no playback.")
                exit(0)
            } catch {
                print("Audio README capture failed: \(error)")
                exit(1)
            }
        }
    }

    static func capture() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        try await D.wait("audio README window") {
            D.window = NSApp.windows.first { $0.identifier?.rawValue == "crossdiff-main" }
            return D.window != nil
        }
        D.window.setFrame(NSRect(x: -10000, y: -10000, width: 1160, height: 930), display: true)
        D.window.orderFront(nil)
        PluginManager.shared.setEnabled(true, id: "org.crossdiff.audio")

        for language in [AppLanguage.simplifiedChinese, .english] {
            let english = language == .english, locale = english ? "en" : "zh-CN"
            AppSettings.shared.language = language
            let left = root.appendingPathComponent("fixtures/" + (english ? "Studio session.wav" : "原始录音.wav"))
            let right = root.appendingPathComponent("fixtures/" + (english ? "Final edit.wav" : "剪辑版本.wav"))
            let leftOriginal = try Data(contentsOf: left), rightOriginal = try Data(contentsOf: right)
            let session = try await A.create(left: left, right: right)
            for other in Array(WorkspaceStore.shared.sessions) where other.id != session.id {
                WorkspaceStore.shared.close(other)
            }
            let model = session.audioComparisonModel
            try await A.ready(model)
            model.runMatching()
            try await A.waitForMatching(model)
            guard model.correspondences.count >= 2 else { throw D.CheckError(description: "Expected real reordered match candidates") }
            guard let match = model.correspondences.first(where: { abs(($0.right.start - $0.left.start) + 12) < 0.2 })
                    ?? model.correspondences.first else { throw D.CheckError(description: "No real match") }
            model.selectCorrespondence(match)
            model.saveRegion(name: english ? "Opening passage" : "开场片段")
            try await A.ready(model)
            print("\(locale): \(model.correspondences.count) real candidates, \(model.leftSource!.duration) s / \(model.rightSource!.duration) s")
            for dark in [false, true] {
                AppAppearance.shared.isDark = dark
                D.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                NSApp.activate(ignoringOtherApps: true)
                D.window.makeKeyAndOrderFront(nil)
                try await D.wait("active screenshot window") { NSApp.isActive && NSApp.keyWindow === D.window }
                D.window.makeFirstResponder(nil)
                try await D.pause()
                D.window.contentView?.layoutSubtreeIfNeeded()
                D.window.displayIfNeeded()
                try await D.pause()
                guard let frame = D.window.contentView?.superview else { throw D.CheckError(description: "Missing full native frame") }
                _ = try D.capture(frame, rect: frame.bounds, name: "audio-\(locale)-\(dark ? "dark" : "light")")
            }
            guard !model.playback.isPlaying, try Data(contentsOf: left) == leftOriginal,
                  try Data(contentsOf: right) == rightOriginal else { throw D.CheckError(description: "Screenshot must preserve original audio without playback") }
        }
    }
}
