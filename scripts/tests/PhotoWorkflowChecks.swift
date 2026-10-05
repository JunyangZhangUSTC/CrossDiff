import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import CrossDiffCore

/// Only the disposable workflow build substitutes this window class. Allowing
/// offscreen title bars lets a real chart sit beneath a stationary system pointer.
@MainActor final class PhotoWorkflowCheckWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor enum PhotoWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-photo-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: real photography plugin, native channels/layouts, Lab histograms, chart interaction, preview cancellation, selection groups, persistence, stale-result protection, XMP, native themes, base installation" : "FAIL: " + D.failures.joined(separator: "; ")
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
        let left = root.appendingPathComponent("Coastal study.tiff"), right = root.appendingPathComponent("Warm reference.tiff")
        try writeImage(left, warm: false, captureMetadata: true)
        try writeImage(right, warm: true, captureMetadata: true)
        let originals = try sourceHashes([left, right])
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
        D.check(model.leftImage?.metadata.first(where: { $0.id == "shutter" })?.value == "1/125 s"
                && model.rightImage?.metadata.first(where: { $0.id == "shutter" })?.value == "1/250 s",
                "ImageIO retains the differing fixture exposure times")
        D.check(model.leftImage?.metadata.contains(where: { $0.id == "exposureBias" }) == true
                && model.rightImage?.metadata.contains(where: { $0.id == "exposureBias" }) == false,
                "missing exposure compensation remains absent in decoded source metadata")
        AppSettings.shared.language = .simplifiedChinese
        try await render("photo-light", width: 1220, dark: false)
        D.check(analysisPicker() != nil, "new photography comparison opens with professional analysis sections visible")
        try await render("photo-default-professional-light-narrow", width: 860, dark: false)
        try await render("photo-default-professional-dark-narrow", width: 860, dark: true)
        try await press("photo.professional")
        D.check(analysisPicker() == nil, "professional analysis can still be collapsed after opening by default")
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
        try await displayAndChartChecks(model)
        let snapshot = session.snapshot
        let encoded = try JSONEncoder().encode([snapshot])
        let decoded = try JSONDecoder().decode([StoredComparison].self, from: encoded)[0]
        D.check(decoded.photoState == model.state && decoded.photoState?.regions.count == 2,
                "named selection groups and all display choices persist through the real session snapshot")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.state)) as! [String: Any]
        for key in ["previewChannel", "histogramChannel", "histogramLayout"] { legacy.removeValue(forKey: key) }
        let legacyState = try JSONDecoder().decode(PhotoWorkspaceState.self, from: JSONSerialization.data(withJSONObject: legacy))
        D.check(legacyState.previewChannel == .original && legacyState.histogramChannel == .perceptualLightness
                && legacyState.histogramLayout == .separated && legacyState.regions == model.state.regions,
                "old saved photo state restores default display choices without losing named regions")
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
        D.check(analysisPicker() == nil, "analysis refresh, region changes, appearance and language keep the user's collapsed choice")
        try await press("photo.professional")
        D.check(analysisPicker() != nil, "professional analysis expands again through its native control")
        for (section, name) in [(1, "color"), (2, "curves"), (3, "information")] {
            try selectAnalysis(section)
            for dark in [false, true] {
                AppSettings.shared.language = dark ? .english : .simplifiedChinese
                try await render("photo-professional-\(name)-\(dark ? "dark-en-narrow" : "light-zh-narrow")", width: 860, dark: dark)
                if section == 3 { try metadataRowChecks() }
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
        try await saturationBoundaryChecks(root: root, right: right, execute: { try await execution.compare($0) })
        try await snapshotAndSchedulingChecks(root: root, right: right, execute: { try await execution.compare($0) })
        let hashesAfter = try sourceHashes([left, right])
        D.check(hashesAfter == originals, "all comparisons, previews, chart highlights and region operations preserve source SHA-256 hashes")
    }
    static func displayAndChartChecks(_ model: PhotoComparisonModel) async throws {
        try await previewReady(model)
        D.check(model.state.previewChannel == .original && model.state.histogramChannel == .perceptualLightness
                && model.state.histogramLayout == .separated, "new photo comparison defaults to original image and separate Lab histograms")
        let statistics = [model.leftStatistics!, model.rightStatistics!]
        let regions = [model.state.leftRegion, model.state.rightRegion]
        let originalLeft = imageBytes(model.leftImage!.preview)
        let originalRight = imageBytes(model.rightImage!.preview)
        D.check(imageBytes(model.leftDisplayImage!) == originalLeft, "default displayed photograph retains the decoded original colors")
        for (index, channel) in PhotoPreviewChannel.allCases.enumerated() {
            try await choose("photo.preview-channel", index: index)
            try await previewReady(model)
            D.check(model.state.previewChannel == channel, "native photo display menu selects \(channel.rawValue)")
            D.check(model.state.histogramChannel == .perceptualLightness, "photo display menu leaves histogram channel independent")
            if channel != .original {
                let pixels = imageBytes(model.leftDisplayImage!)
                D.check(isGrayscale(pixels) && pixels != originalLeft, "\(channel.rawValue) preview renders grayscale channel intensities")
            }
        }
        for (index, channel) in PhotoHistogramChannel.allCases.enumerated() {
            try await choose("photo.histogram-channel", index: index)
            D.check(model.state.histogramChannel == channel && model.state.previewChannel == .blue,
                    "native histogram control selects \(channel.rawValue) independently of preview")
        }
        try await choose("photo.preview-channel", index: 0)
        try await previewReady(model)
        try await choose("photo.histogram-channel", index: 1)
        for (index, layout) in PhotoHistogramLayout.allCases.enumerated() {
            try await choose("photo.histogram-layout", index: index)
            D.check(model.state.histogramLayout == layout, "native histogram layout control selects \(layout.rawValue)")
            AppSettings.shared.language = .simplifiedChinese
            try await render("photo-rgb-\(layout.rawValue)-light-zh-narrow", width: 860, dark: false)
            AppSettings.shared.language = .english
            try await render("photo-rgb-\(layout.rawValue)-dark-en-narrow", width: 860, dark: true)
            let plot = layout == .separated ? "left" : layout.rawValue
            for channel in ["red", "green", "blue"] {
                _ = try control("photo.histogram.\(channel).\(plot)")
            }
        }
        D.check([model.leftStatistics!, model.rightStatistics!] == statistics && !model.isAnalyzing,
                "preview channels and chart display modes retain original ROI statistics")
        try await choose("photo.histogram-channel", index: 0)
        try await choose("photo.histogram-layout", index: 1)
        AppSettings.shared.language = .english
        try await render("photo-lab-overlay-light-en-narrow", width: 860, dark: false)
        AppSettings.shared.language = .simplifiedChinese
        try await render("photo-lab-overlay-dark-zh-narrow", width: 860, dark: true)
        let chartID = "photo.histogram.perceptualLightness.overlay"
        let description = try await hoverChart(chartID,
            readoutIdentifier: "photo.histogram.perceptualLightness.readout", fraction: 0.55)
        D.log("Histogram hover readout: \(description)")
        D.check(description.contains("A") && description.contains("B"), "native histogram hover exposes both sides at the same bin")
        // Give native accessibility geometry time to settle after moving the
        // temporary hover window back offscreen before locating the drag target.
        try await D.pause()
        try await dragChart(chartID, from: 0.2, to: 0.7)
        try await D.wait("chart drag updates highlight range") { model.highlightedRange != nil }
        try await previewReady(model)
        D.check(model.highlightedRange?.channel == .perceptualLightness,
                "native histogram drag selects perceptual-lightness bins")
        let highlightedLeft = imageBytes(model.leftDisplayImage!)
        D.check(highlightedLeft != originalLeft || imageBytes(model.rightDisplayImage!) != originalRight,
                "histogram selection changes visible photo pixels")
        D.check(rightEdgeBytes(highlightedLeft, width: model.leftDisplayImage!.width)
                == rightEdgeBytes(originalLeft, width: model.leftImage!.preview.width),
                "histogram highlight leaves the strip outside the left ROI untouched")
        D.check([model.state.leftRegion, model.state.rightRegion] == regions
                && [model.leftStatistics!, model.rightStatistics!] == statistics && !model.isAnalyzing,
                "chart highlight preserves both source-coordinate regions and their statistics")
        try await render("photo-lab-highlight-dark-zh-narrow", width: 860, dark: true)
        try await press("photo.clear-highlight")
        try await previewReady(model)
        D.check(model.highlightedRange == nil && imageBytes(model.leftDisplayImage!) == originalLeft
                && imageBytes(model.rightDisplayImage!) == originalRight, "native clear-highlight restores both original photo previews")

        // Superseded display work must not publish after a newer original request.
        for channel in [PhotoPreviewChannel.red, .green, .blue, .red, .original] {
            model.state.previewChannel = channel
            model.highlightedRange = channel == .original ? nil : .init(channel: .red, lowerBin: 20, upperBin: 220)
        }
        try await previewReady(model)
        try await D.pause()
        D.check(model.state.previewChannel == .original && imageBytes(model.leftDisplayImage!) == originalLeft,
                "rapid preview and highlight changes cannot publish a stale transformed image")
        // Persist a non-default combination so the session round trip exercises all new fields.
        try await choose("photo.preview-channel", index: 2)
        try await choose("photo.histogram-channel", index: 3)
        try await choose("photo.histogram-layout", index: 2)
        try await previewReady(model)
        D.check([model.leftStatistics!, model.rightStatistics!] == statistics,
                "all display interactions leave the analyzed photograph unchanged")
    }

    static func metadataRowChecks() throws {
        func displayed(_ id: String) throws -> String {
            let value = try accessibleText(id)
            D.log("\(id): \(value)")
            return value
        }
        let leftShutter = try displayed("photo.metadata.shutter.left")
        let rightShutter = try displayed("photo.metadata.shutter.right")
        D.check(leftShutter.contains("1/125 s") && rightShutter.contains("1/250 s"),
                "native metadata rows display differing recorded shutter values side by side")
        let leftISO = try displayed("photo.metadata.iso.left")
        let rightISO = try displayed("photo.metadata.iso.right")
        D.check(leftISO.contains("200") && rightISO.contains("800"),
                "native capture comparison preserves left and right ISO values")
        let recordedBias = try displayed("photo.metadata.exposureBias.left")
        let missingBias = try displayed("photo.metadata.exposureBias.right")
        let missing = AppSettings.shared.language == .english ? "Not recorded" : "未记录"
        D.check(recordedBias.contains("EV") && missingBias.contains(missing),
                "native exposure compensation row distinguishes a record from an explicit missing value")
        let missingLens = try displayed("photo.metadata.lens.left")
        D.check(missingLens.contains(missing), "capture metadata with no record is not inferred from the photograph")
    }

    static func sourceHashes(_ urls: [URL]) throws -> [Data] {
        try urls.map { Data(SHA256.hash(data: try Data(contentsOf: $0))) }
    }
    static func imageBytes(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }
    static func rightEdgeBytes(_ data: Data, width: Int) -> Data {
        // The selected sky ends at x=0.78; this strip is unambiguously outside it.
        let start = Int(Double(width) * 0.9) * 4, stride = width * 4
        var result = Data()
        for row in 0..<(data.count / stride) { result.append(data[(row * stride + start)..<((row + 1) * stride)]) }
        return result
    }
    static func isGrayscale(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                if abs(red - green) > 1 { return false }
                if abs(green - blue) > 1 { return false }
            }
            return true
        }
    }

    static func saturationBoundaryChecks(root: URL, right: URL, execute: @escaping PhotoComparisonModel.Execute) async throws {
        let path = root.appendingPathComponent("saturation-boundary.png")
        // Eight RGBA pixels enter OpenCV's vectorized conversion path. This color
        // can round just above HLS saturation 1 and must retain all histogram mass.
        let pixels = Data((0..<8).flatMap { _ in [UInt8(255), 1, 1, 255] })
        let image = CGImage(width: 8, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw D.CheckError(description: "Unable to create saturation boundary fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw D.CheckError(description: "Unable to write saturation boundary fixture")
        }
        let original = try sourceHashes([path])
        let model = PhotoComparisonModel()
        defer { model.cancel() }
        await model.load(left: path, right: right, execute: execute, executionID: "saturation-boundary")
        try await ready(model)
        D.check(model.error == nil && model.leftStatistics != nil && !model.findings.isEmpty,
                "saturated PNG completes native decoding and restricted plugin analysis without a histogram normalization error")
        let statistics = model.leftStatistics!
        D.check(statistics.analyzedPixels == 8 && abs(statistics.saturation.reduce(0, +) - 1) < 0.000001,
                "saturated PNG preserves every pixel in the normalized saturation histogram")
        D.check(statistics.neutralFraction == 0 && abs(statistics.hue.reduce(0, +) - 1) < 0.000001,
                "saturated PNG remains chromatic with a normalized hue distribution")
        D.check(try sourceHashes([path]) == original, "boundary-color photo analysis preserves the original PNG bytes")
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
        queued.state.previewChannel = .red
        queued.highlightedRange = .init(channel: .green, lowerBin: 64, upperBin: 192)
        queued.cancel()
        queued.state.previewChannel = .blue
        queued.clearHighlight()
        await queued.load(left: path, right: right, execute: observed, executionID: "scheduling")
        try await previewReady(queued)
        let expectedBlue = try PhotoAnalysisEngine.preview(queued.leftImage!, channel: .blue, highlight: nil, region: queued.state.leftRegion)
        D.check(imageBytes(queued.leftDisplayImage!) == imageBytes(expectedBlue),
                "cancelled display work and cached reload publish only the current preview request")
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
    static func control(_ identifier: String) throws -> NSObject {
        let matches = objects().filter { string($0, "accessibilityIdentifier") == identifier }
        if let native = matches.first(where: { $0 is NSControl }) { return native }
        if let cell = matches.first as? NSCell, let view = cell.controlView { return view }
        guard let object = matches.first else { throw D.CheckError(description: "Missing accessible control: \(identifier)") }
        return object
    }
    static func choose(_ identifier: String, index: Int) async throws {
        let object = try control(identifier)
        if let picker = object as? NSSegmentedControl {
            D.check(index < picker.segmentCount, "\(identifier) includes the requested segment")
            picker.selectedSegment = index
            D.check(picker.sendAction(picker.action, to: picker.target), "\(identifier) dispatches a native selection")
        } else if let picker = object as? NSPopUpButton {
            guard let menu = picker.menu, let item = picker.item(at: index) else {
                throw D.CheckError(description: "\(identifier) is missing menu item \(index)")
            }
            D.check(item.action != nil && item.isEnabled, "\(identifier) exposes an enabled native menu action")
            picker.selectItem(at: index)
            // SwiftUI menu Pickers attach their binding action to each item,
            // whereas the popup button itself may intentionally have no action.
            menu.performActionForItem(at: index)
            menu.cancelTrackingWithoutAnimation()
        } else { throw D.CheckError(description: "\(identifier) is not a native selection control") }
        try await D.pause()
    }
    static func accessibilityFrame(_ object: NSObject) throws -> NSRect {
        if let element = object as? NSAccessibilityElement { return element.accessibilityFrame() }
        if let view = object as? NSView { return view.accessibilityFrame() }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { throw D.CheckError(description: "Missing accessible frame") }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
    }
    static func activateWindow() async throws {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if NSApp.keyWindow !== D.window { D.window.makeKeyAndOrderFront(nil) }
        D.window.acceptsMouseMovedEvents = true
        try await D.wait("native photo interaction window active") { NSApp.isActive && NSApp.keyWindow === D.window }
    }
    static func hoverChart(_ identifier: String, readoutIdentifier: String, fraction: Double) async throws -> String {
        try await activateWindow()
        let oldOrigin = D.window.frame.origin
        defer {
            D.window.setFrameOrigin(oldOrigin)
            D.window.contentView?.layoutSubtreeIfNeeded()
            D.window.displayIfNeeded()
        }
        let frame = try accessibilityFrame(control(identifier))
        let target = NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
        let pointer = NSEvent.mouseLocation
        // SwiftUI continuous hover consults the pointer's actual window position.
        // Put the real chart beneath the stationary pointer just for this check;
        // never warp the user's pointer or call the chart's internal callbacks.
        let visibleOrigin = NSPoint(x: oldOrigin.x + pointer.x - target.x,
                                    y: oldOrigin.y + pointer.y - target.y)
        D.window.setFrameOrigin(visibleOrigin)
        D.window.contentView?.layoutSubtreeIfNeeded()
        D.window.displayIfNeeded()
        let placedFrame = try accessibilityFrame(control(identifier))
        let placedTarget = NSPoint(x: placedFrame.minX + placedFrame.width * fraction, y: placedFrame.midY)
        D.log("Hover placement: requested=\(visibleOrigin), actual=\(D.window.frame.origin), chart=\(placedFrame), target=\(placedTarget), sampledPointer=\(pointer)")
        D.check(abs(placedTarget.x - pointer.x) <= 3 && abs(placedTarget.y - pointer.y) <= 3,
                "native chart target aligns with the sampled pointer after window placement")
        let location = D.window.convertPoint(fromScreen: placedTarget)
        let moved = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: D.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        NSApp.postEvent(moved, atStart: true)
        D.log("Hover native window: origin=\(D.window.frame.origin), pointer=\(NSEvent.mouseLocation), point=\(location)")
        let deadline = Date().addingTimeInterval(3)
        var readout = try accessibleText(readoutIdentifier)
        while !(readout.contains("A") && readout.contains("B")) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            readout = try accessibleText(readoutIdentifier)
        }
        // Read before restoring the offscreen window, which legitimately ends hover.
        return readout
    }
    static func dragChart(_ identifier: String, from start: Double, to end: Double) async throws {
        try await activateWindow()
        let frame = try accessibilityFrame(control(identifier))
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp].enumerated() {
            let progress = Double(min(index, 2)) / 2
            let fraction = start + (end - start) * progress
            let point = NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
            let event = NSEvent.mouseEvent(with: type, location: D.window.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: D.window.windowNumber,
                context: nil, eventNumber: index, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.postEvent(event, atStart: false)
        }
        try await D.pause()
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
    static func analysisPicker() -> NSSegmentedControl? {
        objects().compactMap({ $0 as? NSSegmentedControl }).first(where: {
            $0.segmentCount == 4 && ["影调", "Tone"].contains($0.label(forSegment: 0) ?? "")
        })
    }
    static func selectAnalysis(_ index: Int) throws {
        guard let picker = analysisPicker() else { throw D.CheckError(description: "Missing photographic analysis picker") }
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
        guard object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() else { return "" }
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        return ""
    }
    static func accessibleText(_ identifier: String) throws -> String {
        let matches = objects().filter { string($0, "accessibilityIdentifier") == identifier }
        guard !matches.isEmpty else { throw D.CheckError(description: "Missing accessible text: \(identifier)") }
        var seen = Set<ObjectIdentifier>(), values: [String] = []
        func collect(_ object: NSObject, depth: Int) {
            guard depth < 8, seen.insert(ObjectIdentifier(object)).inserted else { return }
            for attribute in ["accessibilityValue", "accessibilityLabel", "accessibilityAttributedValue"] {
                let value = string(object, attribute)
                if !value.isEmpty { values.append(value) }
            }
            if let field = object as? NSTextField { values.append(field.stringValue) }
            if let text = object as? NSTextView { values.append(text.string) }
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                for child in children { collect(child, depth: depth + 1) }
            }
            if let view = object as? NSView {
                for child in view.subviews { collect(child, depth: depth + 1) }
            }
        }
        for match in matches { collect(match, depth: 0) }
        return values.joined(separator: " ")
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
    static func previewReady(_ model: PhotoComparisonModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.isPreviewing || model.leftDisplayImage == nil || model.rightDisplayImage == nil {
            if let error = model.previewError { throw error }
            if Date() > deadline { throw D.CheckError(description: "Photo preview timeout") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if let error = model.previewError { throw error }
    }
    static func render(_ name: String, width: Double, dark: Bool) async throws {
        AppAppearance.shared.isDark = dark
        D.window.setContentSize(NSSize(width: width, height: 820)); D.window.orderFront(nil)
        try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
        let view = D.window.contentView!.superview ?? D.window.contentView!
        let bitmap = try D.capture(view, rect: view.bounds, name: name)
        D.check(bitmap.pixelsWide >= Int(width), "\(name) renders full parent window")
    }
    static func writeImage(_ url: URL, warm: Bool, curve: Int? = nil, captureMetadata: Bool = false) throws {
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
        let type = url.pathExtension == "tiff" ? UTType.tiff : UTType.png
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [String: Any] = [:]
        if captureMetadata {
            var exif: [String: Any] = [
                kCGImagePropertyExifExposureTime as String: warm ? 1.0 / 250 : 1.0 / 125,
                kCGImagePropertyExifFNumber as String: warm ? 5.6 : 2.8,
                kCGImagePropertyExifISOSpeedRatings as String: [warm ? 800 : 200],
                kCGImagePropertyExifFocalLength as String: warm ? 50 : 35
            ]
            if !warm { exif[kCGImagePropertyExifExposureBiasValue as String] = -1.0 / 3 }
            properties[kCGImagePropertyExifDictionary as String] = exif
            properties[kCGImagePropertyTIFFDictionary as String] = [
                kCGImagePropertyTIFFMake as String: "CrossDiff Fixture",
                kCGImagePropertyTIFFModel as String: "Deterministic Camera"
            ]
        }
        if let curve {
            let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"><crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>128, \(curve)</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012></rdf:Description></rdf:RDF></x:xmpmeta>
            """.utf8)
            let metadata = CGImageMetadataCreateFromXMPData(packet as CFData)!
            CGImageDestinationAddImageAndMetadata(destination, context.makeImage()!, metadata, properties as CFDictionary)
        } else { CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary) }
        if !CGImageDestinationFinalize(destination) { throw D.CheckError(description: "Cannot write image fixture") }
    }
}
