import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CrossDiffCore

@MainActor enum PhotoWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-photo-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: real photography plugin, selection groups, persistence, stale-result protection, XMP, native themes, base installation" : "FAIL: " + D.failures.joined(separator: "; ")
            try? (D.report + [verdict]).joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            print(verdict); exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static func run() async throws {
        let root = D.output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        try await D.wait("own window") {
            D.window = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
            return D.window != nil
        }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        let left = root.appendingPathComponent("Coastal study.png"), right = root.appendingPathComponent("Warm reference.png")
        try writeImage(left, warm: false); try writeImage(right, warm: true)
        let originals = try [Data(contentsOf: left), Data(contentsOf: right)]
        let store = WorkspaceStore.shared
        store.beginNewComparison()
        try await D.wait("native comparison chooser") { store.newComparison != nil && D.window.attachedSheet != nil }
        guard let draft = store.newComparison,
              let photography = draft.types.first(where: { $0.pluginID == "org.crossdiff.photography" }) else {
            throw D.CheckError(description: "Missing installed Photography creation entry")
        }
        draft.select(photography)
        D.check(draft.selectedType?.pluginID == "org.crossdiff.photography", "New comparison includes and selects the installed photography card")
        draft.setInput(.file(left), side: .left); draft.setInput(.file(right), side: .right)
        D.check(draft.canCreate, "photography creation accepts the two photograph inputs")
        draft.create()
        try await D.wait("photography source sheet closes") { store.newComparison == nil && D.window.attachedSheet == nil }
        try await D.wait("photography session") { store.selected?.pluginID == "org.crossdiff.photography" }
        let session = store.selected!, model = session.photoComparisonModel
        try await ready(model)
        D.check(model.findings.count >= 2 && model.leftImage != nil && model.rightImage != nil, "actual restricted plugin produces findings for both decoded images")
        D.check(model.leftStatistics?.analyzedPixels == 1200 * 800, "native ROI statistics are independent of UI preview size")
        AppSettings.shared.language = .simplifiedChinese
        try await render("photo-light", width: 1220, dark: false)
        let sky = PhotoRegion(x: 0.08, y: 0.05, width: 0.7, height: 0.35)
        model.selectRegion(sky, side: .left)
        D.check(model.state.rightRegion == .full, "independent selection leaves other side unchanged")
        try await ready(model)
        let skyPixels = model.leftStatistics!.analyzedPixels
        D.check(skyPixels < 1200 * 800 && model.rightStatistics?.analyzedPixels == 1200 * 800, "selection changes statistics rather than cropping the source")
        model.saveRegion(name: "天空 / Sky")
        let savedID = model.state.regions[0].id
        model.state.linkedRegions = true
        let shore = PhotoRegion(x: 0.15, y: 0.55, width: 0.55, height: 0.3)
        model.selectRegion(shore, side: .right)
        D.check(model.state.leftRegion == shore && model.state.rightRegion == shore, "linked selection maps normalized source positions")
        model.saveRegion(name: "海岸 / Shore")
        // A rapid change followed by restore must never publish the earlier result.
        model.applyRegion(id: savedID)
        try await ready(model)
        D.check(model.leftStatistics?.analyzedPixels == skyPixels && model.state.rightRegion == .full, "saved pairs restore both independent regions and cancel stale work")
        try await render("photo-regions-dark", width: 1220, dark: true)
        let snapshot = session.snapshot
        let encoded = try JSONEncoder().encode([snapshot])
        let decoded = try JSONDecoder().decode([StoredComparison].self, from: encoded)[0]
        D.check(decoded.photoState == model.state && decoded.photoState?.regions.count == 2, "named selection groups persist through the real session snapshot")
        let xmp = root.appendingPathComponent("curves.xmp")
        try """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:ProcessVersion="11.0"><crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 12</rdf:li><rdf:li>128, 150</rdf:li><rdf:li>255, 250</rdf:li></rdf:Seq></crs:ToneCurvePV2012></rdf:Description></rdf:RDF></x:xmpmeta>
        """.write(to: xmp, atomically: true, encoding: .utf8)
        model.state.leftXMPPath = xmp.path
        try await ready(model)
        D.check(model.leftCurves.count == 1 && model.rightCurves.isEmpty, "selected XMP shows recorded curve, absent metadata remains absent")
        AppSettings.shared.language = .english
        try await render("photo-english-narrow", width: 860, dark: false)
        try await render("photo-english-dark-narrow", width: 860, dark: true)
        try await press("photo.professional")
        for (section, name) in [(1, "color"), (2, "curves"), (3, "information")] {
            try selectAnalysis(section)
            for dark in [false, true] {
                AppSettings.shared.language = dark ? .english : .simplifiedChinese
                try await render("photo-professional-\(name)-\(dark ? "dark-en-narrow" : "light-zh-narrow")", width: 860, dark: dark)
            }
        }
        model.resetRegions(); try await ready(model)
        D.check(model.leftStatistics?.analyzedPixels == 1200 * 800, "clearing a selection restores full image analysis")
        model.deleteRegion(id: savedID)
        D.check(model.state.regions.count == 1, "saved selection may be removed without touching photos")
        let external = PluginManager(directory: root.appendingPathComponent("base-plugin-data"), bundledDirectory: root.appendingPathComponent("no-bundled-plugins"))
        let packageURL = root.appendingPathComponent("Plugins/Photography.crossdiffplugin")
        external.pendingPackage = try PluginPackage.load(from: packageURL)
        external.installPending(trustNative: false)
        D.check(external.plugin(id: "org.crossdiff.photography")?.enabled == true, "photography installs through normal base-edition local plugin flow")
        let execution = try external.execution(for: "org.crossdiff.photography")
        let result = try await execution.compare([
            PluginInput(id: "left", role: .left, name: "left", content: model.leftStatistics!.pluginContent),
            PluginInput(id: "right", role: .right, name: "right", content: model.rightStatistics!.pluginContent)])
        D.check(result.schema == "crossdiff.photography/1", "externally installed package runs its actual restricted algorithm")
        try await snapshotAndSchedulingChecks(root: root, right: right, execute: { try await execution.compare($0) })
        let bytesAfter = try [Data(contentsOf: left), Data(contentsOf: right)]
        D.check(bytesAfter == originals, "all comparisons and region operations preserve source bytes")
    }
    static func snapshotAndSchedulingChecks(root: URL, right: URL, execute: @escaping PhotoComparisonModel.Execute) async throws {
        let path = root.appendingPathComponent("snapshot-photo.png")
        try writeImage(path, warm: false, curve: 100)
        let model = PhotoComparisonModel()
        await model.load(left: path, right: right, execute: execute, executionID: "snapshot")
        try await ready(model)
        let oldHistogram = model.leftStatistics!.lightness
        let oldCurve = model.leftCurves
        D.check(oldCurve.first?.points[1].y == 100.0 / 255, "embedded curve loads with the photographic byte snapshot")
        try writeImage(path, warm: true, curve: 180)
        let replacement = try Data(contentsOf: path)
        model.selectRegion(.init(x: 0, y: 0, width: 0.5, height: 0.5), side: .left)
        try await ready(model)
        D.check(model.leftCurves == oldCurve, "changing ROI after external file replacement preserves snapshot curves")
        model.resetRegions(); try await ready(model)
        D.check(model.leftStatistics?.lightness == oldHistogram && model.leftCurves == oldCurve,
                "histograms and embedded curves refer to the same retained photograph")
        model.invalidateSources()
        await model.load(left: path, right: right, execute: execute, executionID: "snapshot")
        try await ready(model)
        D.check(model.leftStatistics?.lightness != oldHistogram && model.leftCurves.first?.points[1].y == 180.0 / 255,
                "explicit reload updates both pixels and embedded curves together")
        D.check(try Data(contentsOf: path) == replacement, "snapshot reload never writes the replaced source")

        let counter = ExecutionCounter()
        let queued = PhotoComparisonModel()
        let observed: PhotoComparisonModel.Execute = { inputs in
            await counter.begin()
            // A deliberately non-cooperative stage verifies that cancellation alone
            // is insufficient: the next job must join this one before execution.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { continuation.resume() }
            }
            do {
                let result = try await execute(inputs)
                await counter.end(); return result
            } catch { await counter.end(); throw error }
        }
        await queued.load(left: path, right: right, execute: observed, executionID: "scheduling")
        try await ready(queued)
        let initialCount = await counter.total
        for index in 1...25 {
            queued.selectRegion(.init(x: Double(index) / 100, y: 0, width: 0.5, height: 0.5), side: .left)
        }
        try await ready(queued)
        let finalCount = await counter.total
        D.check(finalCount == initialCount + 1, "rapid selection changes debounce to one final analysis")
        queued.selectRegion(.init(x: 0.1, y: 0.2, width: 0.4, height: 0.4), side: .left)
        let deadline = Date().addingTimeInterval(10)
        while await counter.active == 0, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let activeCount = await counter.active
        D.check(activeCount == 1, "non-cooperative execution is active before superseding it")
        queued.selectRegion(.init(x: 0.2, y: 0.1, width: 0.3, height: 0.3), side: .left)
        try await ready(queued)
        let maximumActive = await counter.maximumActive
        D.check(maximumActive == 1, "superseded jobs finish before another analysis executes")
        queued.cancel(); model.cancel()
    }
    actor ExecutionCounter {
        var total = 0
        var active = 0
        var maximumActive = 0
        func begin() { total += 1; active += 1; maximumActive = max(maximumActive, active) }
        func end() { active -= 1 }
    }
    static func press(_ identifier: String) async throws {
        let matches = objects().filter { string($0, "accessibilityIdentifier") == identifier }
        guard let object = matches.first(where: { $0 is NSControl }) ?? matches.first else {
            throw D.CheckError(description: "Missing accessible control: \(identifier)")
        }
        if let button = object as? NSButton { button.performClick(nil) }
        else {
            let action = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: action) else { throw D.CheckError(description: "Missing press: \(identifier)") }
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            D.check(unsafeBitCast(object.method(for: action), to: Action.self)(object, action), "professional control dispatches native action")
        }
        try await D.pause()
    }
    static func selectAnalysis(_ index: Int) throws {
        guard let picker = objects().compactMap({ $0 as? NSSegmentedControl }).first(where: {
            $0.segmentCount == 4 && ["影调", "Tone"].contains($0.label(forSegment: 0) ?? "")
        }) else { throw D.CheckError(description: "Missing photographic analysis picker") }
        picker.selectedSegment = index
        D.check(picker.sendAction(picker.action, to: picker.target), "professional analysis section dispatches native action")
    }
    static func objects() -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func descend(_ object: NSObject, depth: Int) {
            guard depth < 45, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                for child in children { descend(child, depth: depth + 1) }
            }
            if let view = object as? NSView { for child in view.subviews { descend(child, depth: depth + 1) } }
        }
        if let view = D.window.contentView { descend(view, depth: 0) }
        return result
    }
    static func string(_ object: NSObject, _ attribute: String) -> String {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    static func ready(_ model: PhotoComparisonModel) async throws {
        let deadline = Date().addingTimeInterval(45)
        while model.isLoading || model.isAnalyzing || model.leftStatistics == nil {
            if let error = model.error { throw error }
            if Date() > deadline { throw D.CheckError(description: "Photo analysis timeout") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if let error = model.error { throw error }
    }
    static func render(_ name: String, width: Double, dark: Bool) async throws {
        AppAppearance.shared.isDark = dark
        D.window.setContentSize(NSSize(width: width, height: 820)); D.window.orderFront(nil)
        try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
        let view = D.window.contentView!.superview ?? D.window.contentView!
        let bitmap = try D.capture(view, rect: view.bounds, name: name)
        D.check(bitmap.pixelsWide >= Int(width), "\(name) renders full parent window")
    }
    static func writeImage(_ url: URL, warm: Bool, curve: Int? = nil) throws {
        let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 1200 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let sky: [CGFloat] = warm ? [0.97, 0.69, 0.43, 1.0] : [0.3, 0.6, 0.81, 1.0]
        let sea: [CGFloat] = warm ? [0.22, 0.49, 0.53, 1.0] : [0.09, 0.39, 0.57, 1.0]
        let gradient = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colorComponents: sea + sky, locations: [0, 1], count: 2)!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 800), options: [])
        context.setFillColor(CGColor(red: 1, green: warm ? 0.87 : 0.98, blue: warm ? 0.64 : 1, alpha: 0.95))
        context.fillEllipse(in: CGRect(x: 830, y: 550, width: 90, height: 90))
        context.setFillColor(CGColor(red: 0.13, green: 0.25, blue: 0.28, alpha: 1))
        context.move(to: .zero); context.addLine(to: CGPoint(x: 0, y: 340))
        context.addCurve(to: CGPoint(x: 1200, y: 70), control1: CGPoint(x: 400, y: 100), control2: CGPoint(x: 850, y: 430))
        context.addLine(to: CGPoint(x: 1200, y: 0)); context.closePath(); context.fillPath()
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        if let curve {
            let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"><crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>128, \(curve)</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012></rdf:Description></rdf:RDF></x:xmpmeta>
            """.utf8)
            let metadata = CGImageMetadataCreateFromXMPData(packet as CFData)!
            CGImageDestinationAddImageAndMetadata(destination, context.makeImage()!, metadata, nil)
        } else { CGImageDestinationAddImage(destination, context.makeImage()!, nil) }
        if !CGImageDestinationFinalize(destination) { throw D.CheckError(description: "Cannot write image fixture") }
    }
}
