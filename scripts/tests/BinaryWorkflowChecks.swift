import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
enum BinaryWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).deletingLastPathComponent() }
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-binary-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: binary routing, aligned hex/ASCII, 64-bit row mapping, bounded paging, navigation, read-only menus, sessions, mutation recovery and actual bilingual light/dark/narrow native windows" : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? verdict.write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        D.window = NativeMenuController.shared.comparisonWindow
        guard D.window != nil else { throw D.CheckError(description: "No native window") }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.makeKeyAndOrderFront(nil)
        AppSettings.shared.language = .simplifiedChinese
        let store = WorkspaceStore.shared, menu = NativeMenuController.shared
        let empty = ComparisonSession(); store.sessions = [empty]; store.selectedID = empty.id
        let a = root.appendingPathComponent("firmware-original.bin"), b = root.appendingPathComponent("firmware-revised.bin")
        var left = Data((0..<2048).map { UInt8(($0 * 37 + 11) % 256) })
        left.replaceSubrange(0..<16, with: Array("CrossDiff BIN 1.0".utf8))
        var right = left
        right.replaceSubrange(12..<16, with: Array(" 2.0".utf8))
        right.removeSubrange(48..<56)
        right.insert(contentsOf: [0x43, 0x72, 0x6f, 0x73, 0x73, 0x44, 0x69, 0x66, 0x66], at: 112)
        try left.write(to: a); try right.write(to: b)
        store.accept([a, b])
        try await D.wait("binary auto-routing") { store.selected?.kind == .binary }
        let session = store.selected!, model = session.binaryComparisonModel
        try await D.wait("binary comparison") { model.result != nil || model.error != nil }
        if let error = model.error { throw error }
        try await D.wait("first byte page") { model.page != nil }
        D.check(model.changeIndices.count >= 3, "byte modifications, additions and removals stay separate")
        D.check(model.result?.spans.contains { $0.kind == .added } == true, "insertions aligned")
        D.check(model.result?.spans.contains { $0.kind == .removed } == true, "deletions aligned")
        D.check(model.result?.alignmentIsApproximate == false, "small edits exact")
        try checkRows(model, left: left, right: right)
        let saveItem = NSMenuItem(title: "", action: #selector(NativeMenuController.save(_:)), keyEquivalent: "s")
        let findItem = NSMenuItem(title: "", action: #selector(NativeMenuController.find(_:)), keyEquivalent: "f")
        D.check(!menu.validateMenuItem(saveItem) && !menu.validateMenuItem(findItem), "hex does not expose text save/search commands")
        store.save(session, side: .left)
        D.check(try Data(contentsOf: a) == left, "direct save entry cannot overwrite binary source")
        let prior = model.selectedChange
        model.navigate(1)
        D.check(model.selectedChange == (prior + 1) % model.changeIndices.count, "next change updates selection")
        D.check(model.requestedRow == model.layout?.row(forSpanIndex: model.changeIndices[model.selectedChange]), "difference navigation uses aligned row mapping")
        model.navigate(-1)
        model.jump(to: 180, side: .right)
        D.check(model.requestedRow == model.layout?.row(containingOffset: 180, side: .right), "jump uses right source address after insertion")
        model.jump(to: 0, side: .left)
        try await render(name: "binary-light", dark: false, width: 1220)
        try await render(name: "binary-dark", dark: true, width: 1220)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        if let canvas = descendants(D.window.contentView!).compactMap({ $0 as? BinaryHexCanvas }).first,
           let first = canvas.cellRect(side: .left, row: 0, column: 0),
           let last = canvas.cellRect(side: .left, row: 0, column: 7) {
            func event(_ type: NSEvent.EventType, _ rect: NSRect) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: canvas.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: D.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: event(.leftMouseDown, first))
            canvas.mouseDragged(with: event(.leftMouseDragged, last))
            canvas.mouseUp(with: event(.leftMouseUp, last))
            D.check(canvas.selectedHex == left.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "),
                    "actual pointer selection returns only real hexadecimal bytes without using clipboard")
            let undo = NSMenuItem(title: "", action: #selector(NativeMenuController.undo(_:)), keyEquivalent: "z")
            D.check(!menu.validateMenuItem(undo), "read-only hex canvas cannot undo text behind it")
            canvas.clearSelection()
        } else { D.check(false, "native byte cells available for selection") }

        AppSettings.shared.language = .english
        try await render(name: "binary-english-narrow", dark: false, width: 860)
        AppSettings.shared.language = .simplifiedChinese
        try await render(name: "binary-chinese-dark-narrow", dark: true, width: 860)

        if let viewport = descendants(D.window.contentView!).compactMap({ $0 as? BinaryHexViewport }).first {
            viewport.scroll(toRow: 25)
            try await D.wait("scroll row retained by model") { model.requestedRow == 25 }
            store.selectedID = empty.id
            try await D.pause()
            store.selectedID = session.id
            try await D.pause()
            let restored = descendants(D.window.contentView!).compactMap { $0 as? BinaryHexViewport }.first
            D.check(restored?.firstVisibleRow == 25, "tab recreation retains the actual scrolled position")
            model.jump(to: 512, side: .left)
            try await D.pause()
            let before = model.requestedRow * Int64(model.bytesPerRow)
            model.bytesPerRow = model.bytesPerRow == 8 ? 16 : 8
            let rowStart = model.requestedRow * Int64(model.bytesPerRow)
            D.check(rowStart <= before && before < rowStart + Int64(model.bytesPerRow),
                    "column change keeps the previous first byte in the first row")
            model.jump(to: 0, side: .left)
        } else { D.check(false, "native viewport exists for scroll restoration") }
        D.check(store.persistNow(), "binary session persisted")
        let recovered = try SessionFile.load(from: root.appendingPathComponent("data/sessions.json"))
        let saved = recovered.first { $0.id == session.id }
        D.check(saved?.kind == "binary" && saved?.left.text == "" && saved?.right.text == "" && saved?.left.path == a.path,
                "binary persistence stores paths and type without bytes or formatted hex")

        // Explicit byte mode wins over image/PDF/text and package classification.
        let forcedA = root.appendingPathComponent("source.pdf"), forcedB = root.appendingPathComponent("source.txt")
        try Data("%PDF-read-as-bytes".utf8).write(to: forcedA)
        try Data("a plain text file".utf8).write(to: forcedB)
        store.accept([forcedA, forcedB], kind: .binary)
        try await D.wait("explicit binary mixed pair") { store.selected?.left.path == forcedA.path }
        D.check(store.selected?.kind == .binary && store.selected?.pluginID == nil, "explicit binary mode accepts mixed regular files")
        store.accept([a, forcedB])
        try await D.wait("binary and text automatic pair") { store.selected?.left.path == a.path && store.selected?.right.path == forcedB.path }
        D.check(store.selected?.kind == .binary, "binary and text sources compare as bytes")
        store.accept([forcedA], kind: .binary)
        D.check(store.pairing && store.candidates.first?.kind == .binary, "single explicit binary input preserves pairing type")
        store.pairing = false
        store.selectedID = session.id
        try await D.pause()
        D.check(model.result != nil && model.error == nil, "tab switch retains comparison model")

        // Sparse sources exercise the viewport path beyond the text size ceiling.
        let largeA = root.appendingPathComponent("large-left.bin"), largeB = root.appendingPathComponent("large-right.bin")
        let size = 24 * 1024 * 1024
        try sparse(largeA, size: size, final: 0x41); try sparse(largeB, size: size, final: 0x42)
        let large = BinaryComparisonModel()
        await large.load(left: largeA, right: largeB)
        if let error = large.error { throw error }
        D.check(large.result?.leftSize == Int64(size), "binary source bypasses 20 MB text limit")
        large.jump(to: Int64(size - 1), side: .right)
        try await D.wait("large tail page") { large.page?.byte(at: Int64(size - 1), side: .right) == 0x42 }
        D.check((large.page?.leftBytes.count ?? Int.max) <= 8192 && (large.page?.rows.count ?? Int.max) <= 512,
                "large view page remains bounded")
        // Move away and immediately return to an already cached page. The old
        // asynchronous request must not displace the current viewport later.
        large.requestRows(start: 0, count: 512)
        large.requestRows(start: large.page!.startRow, count: large.page!.rows.count)
        try await D.pause()
        D.check(large.page?.byte(at: Int64(size - 1), side: .right) == 0x42, "cached return supersedes an in-flight distant read")

        large.requestRows(start: large.layout!.totalRows - 2, count: 2)
        try await D.wait("rapid page requests") { large.page?.byte(at: Int64(size - 1), side: .right) == 0x42 }
        // A changed file invalidates the snapshot before publishing more bytes.
        try right.appendingByte(0xff).write(to: b)
        await model.load(left: a, right: b)
        D.check(model.error != nil && model.result == nil && model.page == nil, "source modification clears stale bytes and alignment")
        try right.write(to: b)
        await model.load(left: a, right: b, force: true)
        D.check(model.error == nil && model.result != nil, "explicit refresh recovers after source mutation")
        let canceled = BinaryComparisonModel()
        let operation = Task { await canceled.load(left: largeA, right: largeB) }
        await Task.yield(); canceled.cancel(); await operation.value
        D.check(!canceled.isLoading && canceled.result == nil, "cancellation never publishes an obsolete result")
        D.check(try Data(contentsOf: a) == left && Data(contentsOf: b) == right, "all viewing operations leave both originals unchanged")
        D.log("Completed native and integration checks")
    }

    static func checkRows(_ model: BinaryComparisonModel, left: Data, right: Data) throws {
        guard let result = model.result else { return }
        for width in [8, 16] {
            let layout = BinaryRowLayout(result: result, bytesPerRow: width)
            let cells = layout.rows(start: 0, count: 512).flatMap(\.cells)
            D.check(cells.compactMap(\.leftOffset) == Array(0..<Int64(left.count)), "left row mapping covers each source byte once at \(width) columns")
            D.check(cells.compactMap(\.rightOffset) == Array(0..<Int64(right.count)), "right row mapping covers each source byte once at \(width) columns")
            D.check(cells.contains { $0.leftOffset == nil } && cells.contains { $0.rightOffset == nil }, "aligned gaps remain gaps at \(width) columns")
        }
        let size: Int64 = 8 * 1024 * 1024 * 1024
        let huge = BinaryRowLayout(result: .init(spans: [.init(kind: .equal, leftOffset: 0, rightOffset: 0, leftCount: size, rightCount: size)], leftSize: size, rightSize: size, alignmentIsApproximate: false), bytesPerRow: 16)
        let tail = huge.rows(start: huge.totalRows - 1, count: 1)
        D.check(tail.first?.cells.last?.leftOffset == size - 1, "virtual row address remains 64-bit near 8 GiB")
        D.check(huge.rows(start: 0, count: Int.max).count == 512, "row construction bounded independent of file size")
    }

    static func sparse(_ url: URL, size: Int, final: UInt8) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size)); try handle.seek(toOffset: UInt64(size - 1)); try handle.write(contentsOf: Data([final]))
    }

    static func render(name: String, dark: Bool, width: Double) async throws {
        AppAppearance.shared.isDark = dark
        D.window.setContentSize(NSSize(width: width, height: 700)); D.window.makeKeyAndOrderFront(nil)
        try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
        let view = D.window.contentView!.superview ?? D.window.contentView!
        _ = try D.capture(view, rect: view.bounds, name: name)
        func descendants(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(descendants) }
        guard let canvas = descendants(view).first(where: { $0.identifier?.rawValue == "binary.hex.canvas" }) else {
            D.check(false, "native byte canvas exists: \(name)"); return
        }
        let region = canvas.convert(canvas.bounds, to: view).intersection(view.bounds)
        let bitmap = try D.capture(view, rect: region, name: name + "-bytes")
        let counts = D.countPixels(bitmap, background: AppAppearance.shared.colors.canvas)
        D.check(counts.readable > 200 && counts.red > 12, "actual parent rendering contains readable bytes and removal highlights: \(name)")
        D.check(region.width > 760 && region.height > 300, "byte viewport remains usable: \(name)")
    }
}

private extension Data {
    func appendingByte(_ byte: UInt8) -> Data { var copy = self; copy.append(byte); return copy }
}
