import AppKit
import SwiftUI
import CrossDiffCore

/// Exercises the real native image workspace, with fixtures and settings isolated
/// to this check's project directory. No system clipboard or desktop capture.
@MainActor
enum ImageTransformChecks {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    static var window: NSWindow!
    static var report: [String] = []
    static var failures: [String] = []
    static var output: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]!) }

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-image-workflow-checks/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-image-workflow-checks/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() }
            catch {
                failures.append("Interrupted: \(error)")
                if window != nil {
                    try? await stage("image-failure", width: 1220, height: 790, dark: false, language: .simplifiedChinese)
                }
            }
            let success = ProcessInfo.processInfo.environment["CROSSDIFF_CORNER_CHECK_ONLY"] == "1"
                    ? "PASS: targeted native corner transitions and mouse-up completion"
                    : "PASS: native image scale/rotation, four-corner resize, aspect locking, horizontal/vertical flip, independent edits, alignment, mode/tab retention, reset, newest render, immutable files, Chinese/English and light/dark/wide/860px full-window renders"
            let verdict = failures.isEmpty
                ? success
                : "FAIL: " + failures.joined(separator: "; ")
            log(verdict)
            try? report.joined(separator: "\n").write(to: output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(failures.isEmpty ? 0 : 8)
        }
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await wait("main app window") {
            window = NSApp.windows.first { $0.identifier?.rawValue == "crossdiff-main" }
            return window != nil
        }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("test app and window active") { NSApp.isActive && NSApp.keyWindow === window }
        let fixtures = output.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let left = fixtures.appendingPathComponent("original.png"), right = fixtures.appendingPathComponent("cropped.png")
        try writeFixture(left, crop: false)
        try writeFixture(right, crop: true)
        let originalBytes = [try Data(contentsOf: left), try Data(contentsOf: right)]
        let session = ComparisonSession(kind: .image, left: .init(path: left.path), right: .init(path: right.path))
        let store = WorkspaceStore.shared
        store.sessions = [session]; store.selectedID = session.id; store.message = nil
        AppSettings.shared.language = .simplifiedChinese
        let model = session.imageComparisonModel
        try await settled(model)
        try await pause()
        try await assertControls(model)
        log("Loaded immutable image pair in actual native workspace")
        if ProcessInfo.processInfo.environment["CROSSDIFF_CORNER_CHECK_ONLY"] == "1" {
            try await checkCornerTransitions(model)
            return
        }

        _ = try focusField("image.left.scale.field")
        try await changeSlider("image.left.scale.slider", value: 135)
        _ = try focusField("image.right.scale.field")
        window.makeFirstResponder(nil)
        try await pause()
        check(near(model.leftTransform.scale, 1.35), "leaving a focused numeric field does not restore its pre-slider draft")
        _ = try focusField("image.left.scale.field")
        try await press("image.left.reset")
        _ = try focusField("image.right.scale.field")
        window.makeFirstResponder(nil)
        try await pause()
        check(model.leftTransform.isIdentity, "reset while a number field is focused is not overwritten on blur")
        try await changeSlider("image.left.scale.slider", value: 135)
        check(near(model.leftTransform.scale, 1.35) && model.rightTransform.isIdentity,
              "left scale slider changes the left image only")
        try await changeSlider("image.right.rotation.slider", value: 30)
        check(near(model.rightTransform.rotationDegrees, 30) && near(model.leftTransform.rotationDegrees, 0),
              "right rotation slider changes the right image only")
        try await editField("image.left.rotation.field", value: "-12.5")
        check(near(model.leftTransform.rotationDegrees, -12.5) && near(model.rightTransform.rotationDegrees, 30),
              "left editable degree value applies independently")
        try await editField("image.right.scale.field", value: "80")
        check(near(model.rightTransform.scale, 0.8) && near(model.leftTransform.scale, 1.35),
              "right editable percentage applies independently")
        try await settled(model)

        let leftTransform = model.leftTransform, rightTransform = model.rightTransform
        for (index, mode) in ImageComparisonMode.allCases.enumerated() {
            try await chooseMode(index)
            check(model.mode == mode, "native mode segment selects \(mode)")
            check(model.leftTransform == leftTransform && model.rightTransform == rightTransform,
                  "switching \(mode) preserves both transforms")
        }
        let other = ComparisonSession(left: .init(text: "isolated"), right: .init(text: "fixture"))
        store.sessions.append(other); store.selectedID = other.id
        try await pause()
        store.selectedID = session.id
        try await pause()
        check(session.imageComparisonModel === model && model.leftTransform == leftTransform && model.rightTransform == rightTransform,
              "switching tabs preserves the image model and both transforms")
        store.sessions = [session]

        try await press("image.left.reset")
        check(model.leftTransform.isIdentity && model.rightTransform == rightTransform,
              "left reset restores only left scale, rotation, and position")
        try await press("image.right.reset")
        check(model.rightTransform.isIdentity, "right reset restores its transform")
        try await settled(model)
        model.mode = .overlay; model.alignmentSide = .right
        try await pause()
        try await dragCanvas("image.canvas.combined", delta: NSPoint(x: 36, y: -24))
        check(near(model.rightTransform.offsetX, 36) && near(model.rightTransform.offsetY, 24),
              "native canvas drag follows its pointer translation without a layout jump")
        check(model.leftTransform.isIdentity, "native alignment drag leaves the other image unchanged")
        try await settled(model)
        try await press("image.right.reset")
        try await settled(model)
        model.mode = .wipe
        try await pause()
        guard let handle = objects().first(where: { string($0, "accessibilityLabel") == "图片分界手柄" }) else {
            throw CheckError(description: "No accessible wipe handle")
        }
        let originalWipe = model.wipePosition
        try await dragElement(handle, description: "wipe handle", delta: NSPoint(x: 48, y: 0))
        check(near(model.wipePosition, originalWipe + 0.1), "native wipe handle drag follows the pointer on the 480-pixel canvas")
        check(model.leftTransform.isIdentity && model.rightTransform.isIdentity,
              "dragging the wipe handle never moves either image")

        // Rapid updates deliberately overlap the background worker. Only the final
        // identity comparison should survive, and both source files remain intact.
        model.mode = .difference
        let baseline = model.preview!.differentPixels
        for index in 0..<18 {
            model.leftTransform = ImageComparisonTransform(scale: 1 + Double(index) / 25,
                                                          rotationDegrees: Double(index * 5),
                                                          offsetX: Double(index * 3), offsetY: Double(-index))
        }
        model.leftTransform = .identity
        try await settled(model)
        try await Task.sleep(nanoseconds: 350_000_000)
        check(model.leftTransform.isIdentity && model.preview?.leftTransform.isIdentity == true &&
              model.renderedLeftTransform.isIdentity && model.preview?.differentPixels == baseline && !model.isRendering,
              "obsolete transform jobs cannot replace the latest render")

        // Model-driven interaction simulation, kept distinct from the native
        // slider and mouse events above. A held gesture must publish intermediate
        // previews rather than wait indefinitely for input to stop.
        var sawIntermediatePreview = false
        model.setInteracting(true)
        for index in 1...12 {
            model.setTransform(ImageComparisonTransform(scale: 1 + Double(index) / 20), for: .left)
            try await Task.sleep(nanoseconds: 50_000_000)
            sawIntermediatePreview = sawIntermediatePreview || model.preview?.leftTransform.isIdentity == false
        }
        model.setInteracting(false)
        try await settled(model)
        check(sawIntermediatePreview && near(model.preview!.leftTransform.scale, 1.6),
              "model-simulated continuous input publishes intermediate previews and ends at the latest value")
        model.reset(side: .left)
        try await settled(model)

        model.rightTransform = ImageComparisonTransform(offsetX: 80, offsetY: 50)
        model.overlapOnly = true
        try await settled(model)
        check(model.preview!.differentPixels == 0, "manually aligned crop matches in overlap-only comparison")
        model.overlapOnly = false
        try await settled(model)
        check(model.preview!.differentPixels > 0, "whole-canvas comparison includes pixels outside the crop")

        try await checkResizeAndFlip(session)

        model.mode = .overlay
        model.leftTransform = ImageComparisonTransform(scale: 1.08, rotationDegrees: -8)
        model.rightTransform = ImageComparisonTransform(scale: 1.15, rotationDegrees: 12, offsetX: 80, offsetY: 50)
        try await settled(model)
        for (name, width, height, dark, language) in [
            ("image-transforms-zh-light", 1220.0, 790.0, false, AppLanguage.simplifiedChinese),
            ("image-transforms-zh-dark", 1220.0, 790.0, true, AppLanguage.simplifiedChinese),
            ("image-transforms-zh-light-860", 860.0, 580.0, false, AppLanguage.simplifiedChinese),
            ("image-transforms-en-dark-860", 860.0, 580.0, true, AppLanguage.english)
        ] {
            try await stage(name, width: width, height: height, dark: dark, language: language)
            try await assertControls(model)
        }
        model.mode = .sideBySide
        try await stage("image-side-by-side-en-light-860", width: 860, height: 580, dark: false, language: .english)
        model.mode = .wipe
        try await stage("image-wipe-zh-dark-860", width: 860, height: 580, dark: true, language: .simplifiedChinese)
        model.mode = .difference; model.overlapOnly = true
        try await settled(model)
        try await stage("image-difference-zh-light-860", width: 860, height: 580, dark: false, language: .simplifiedChinese)
        check(try Data(contentsOf: left) == originalBytes[0] && Data(contentsOf: right) == originalBytes[1],
              "every transform, preview, reset, and tab switch leaves both original files byte-for-byte intact")
        check(!session.dirty && session.left.path == left.path && session.right.path == right.path,
              "preview transforms never mark source files edited or change file associations")
    }

    private static func inspectImageColors(_ name: String, model: ImageComparisonModel) throws {
        guard let full = window.contentView?.superview,
              let composed = NSBitmapImageRep(data: try Data(contentsOf: output.appendingPathComponent(name + ".png"))) else {
            throw CheckError(description: "No composed parent bitmap for \(name)")
        }
        for side in ImageComparisonSide.allCases {
            let image = side == .left ? model.preview!.left.image : model.preview!.right.image
            let raw = NSBitmapImageRep(cgImage: image)
            if let data = raw.representation(using: .png, properties: [:]) {
                try data.write(to: output.appendingPathComponent(name + "-raw-" + side.rawValue + ".png"))
            }
            let rawColors = colorfulPixels(raw, rect: NSRect(x: 0, y: 0, width: raw.pixelsWide, height: raw.pixelsHigh))
            let screen = try accessibilityFrame(try control("image.canvas.\(side.rawValue)"))
            let rect = full.convert(window.convertFromScreen(screen), from: nil)
            let sx = CGFloat(composed.pixelsWide) / full.bounds.width
            let sy = CGFloat(composed.pixelsHigh) / full.bounds.height
            let pixels = NSRect(x: (rect.minX - full.bounds.minX) * sx,
                                y: (full.bounds.maxY - rect.maxY) * sy,
                                width: rect.width * sx, height: rect.height * sy)
            let actual = colorfulPixels(composed, rect: pixels)
            log("Image colors \(name) \(side): raw=\(rawColors), composed=\(actual), canvasPixels=\(pixels)")
            check(rawColors.blue > 30 && rawColors.green > 30 && rawColors.orange > 30,
                  "\(name) \(side): original preview retains blue, green, and orange fixture content")
            check(actual.blue > 30 && actual.green > 30 && actual.orange > 30,
                  "\(name) \(side): complete parent window visibly preserves blue, green, and orange image content")
        }
    }

    private static func colorfulPixels(_ bitmap: NSBitmapImageRep, rect: NSRect) -> (blue: Int, green: Int, orange: Int) {
        var blue = 0, green = 0, orange = 0
        let x0 = max(0, Int(floor(rect.minX))), x1 = min(bitmap.pixelsWide, Int(ceil(rect.maxX)))
        let y0 = max(0, Int(floor(rect.minY))), y1 = min(bitmap.pixelsHigh, Int(ceil(rect.maxY)))
        guard x1 > x0, y1 > y0 else { return (0, 0, 0) }
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                if b > 0.45 && b > r + 0.15 && b > g + 0.1 { blue += 1 }
                if g > 0.4 && g > r + 0.15 && b > 0.3 && b < g + 0.15 { green += 1 }
                // Compare channel separation instead of exact RGB: the full
                // AppKit window and source image can use different color profiles.
                if r > 0.7 && r > g + 0.15 && g > b + 0.15 && b < 0.55 { orange += 1 }
            }
        }
        return (blue, green, orange)
    }

    private static func checkCornerTransitions(_ model: ImageComparisonModel) async throws {
        model.mode = .sideBySide
        for (side, corner) in [(ImageComparisonSide.left, ImageTransformCorner.topLeft), (.left, .topRight), (.right, .topLeft)] {
            model.reset(side: .left); model.reset(side: .right)
            try await settled(model)
            let size = sourceSize(model, side: side)
            let anchor = ImageTransformGeometry.corners(sourceSize: size, transform: model.transform(for: side))[corner.opposite.rawValue]
            let delta = outwardDelta(corner)
            let outside = NSPoint(x: delta.x < 0 ? -8 : 8, y: delta.y < 0 ? -8 : 8)
            try await dragCorner(model, side: side, corner: corner, delta: delta, hitOffset: outside)
            let after = model.transform(for: side)
            check(after.scaleX > 1 && near(after.scaleX, after.scaleY), "targeted \(side).\(corner) performs its proportional resize")
            check(close(anchor, ImageTransformGeometry.corners(sourceSize: size, transform: after)[corner.opposite.rawValue]),
                  "targeted \(side).\(corner) fixes its opposite corner")
            let other: ImageComparisonSide = side == .left ? .right : .left
            check(model.transform(for: other).isIdentity, "targeted \(side).\(corner) leaves the other image unchanged")
            log("Targeted state: left=\(model.leftTransform), right=\(model.rightTransform), interacting=\(model.isInteracting)")
        }
    }

    private static func checkResizeAndFlip(_ session: ComparisonSession) async throws {
        let model = session.imageComparisonModel
        model.reset(side: .left); model.reset(side: .right)
        model.mode = .sideBySide
        try await settled(model)
        check(model.leftAspectLocked && model.rightAspectLocked, "both images initially lock their aspect ratio")
        for symbol in ["arrow.left.and.right.righttriangle.left.righttriangle.right", "arrow.up.and.down.righttriangle.up.righttriangle.down"] {
            check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "the native flip symbol \(symbol) is available")
        }
        for side in ImageComparisonSide.allCases {
            let other: ImageComparisonSide = side == .left ? .right : .left
            for corner in ImageTransformCorner.allCases {
                model.reset(side: .left); model.reset(side: .right)
                try await settled(model)
                let before = model.transform(for: side)
                let otherBefore = model.transform(for: other)
                let size = sourceSize(model, side: side)
                let anchor = ImageTransformGeometry.corners(sourceSize: size, transform: before)[corner.opposite.rawValue]
                let delta = outwardDelta(corner)
                let outside = NSPoint(x: delta.x < 0 ? -8 : 8, y: delta.y < 0 ? -8 : 8)
                try await dragCorner(model, side: side, corner: corner, delta: delta, hitOffset: outside)
                let after = model.transform(for: side)
                let fixed = ImageTransformGeometry.corners(sourceSize: size, transform: after)[corner.opposite.rawValue]
                check(after.scaleX > before.scaleX && near(after.scaleX, after.scaleY),
                      "\(side).\(corner) native drag grows both axes with the default aspect lock")
                check(close(anchor, fixed), "\(side).\(corner) native resize fixes the opposite world-space corner")
                check(model.transform(for: other) == otherBefore, "\(side).\(corner) resize leaves the other image unchanged")
            }
            model.reset(side: .left); model.reset(side: .right)
            try await settled(model)
            try await press("image.\(side.rawValue).flipHorizontal")
            check(model.transform(for: side).flipHorizontal && !model.transform(for: side).flipVertical,
                  "\(side) horizontal flip button toggles only the horizontal axis")
            try await press("image.\(side.rawValue).flipVertical")
            check(model.transform(for: side).flipHorizontal && model.transform(for: side).flipVertical,
                  "\(side) vertical flip button can combine with horizontal flip")
            try await press("image.\(side.rawValue).flipHorizontal")
            try await press("image.\(side.rawValue).flipVertical")
            check(model.transform(for: side).isIdentity, "\(side) both flip buttons are reversible")

            try await press("image.\(side.rawValue).aspectLock")
            check(!model.aspectLocked(for: side) && model.aspectLocked(for: other),
                  "\(side) aspect unlock remains independent from the other image")
            try await assertControls(model)
            let unlockedSize = sourceSize(model, side: side)
            let originalAnchor = ImageTransformGeometry.corners(sourceSize: unlockedSize, transform: model.transform(for: side))[0]
            try await dragCorner(model, side: side, corner: .bottomRight, delta: NSPoint(x: 28, y: 0))
            let horizontal = model.transform(for: side)
            check(horizontal.scaleX > 1 && near(horizontal.scaleY, 1), "\(side) unlocked horizontal corner drag changes width only")
            check(close(originalAnchor, ImageTransformGeometry.corners(sourceSize: unlockedSize, transform: horizontal)[0]),
                  "\(side) unlocked resize retains the opposite corner")
            _ = try focusField("image.\(side.rawValue).width.field")
            window.makeFirstResponder(nil)
            try await pause()
            check(model.transform(for: side) == horizontal,
                  "\(side) focusing then leaving an untouched number field preserves precise corner alignment")
            try await editField("image.\(side.rawValue).width.field", value: "140.05")
            check(abs(model.transform(for: side).scaleX - 1.4005) < 0.0000001,
                  "\(side) Return preserves entered sub-tenth-percent precision")
            try await changeSlider("image.\(side.rawValue).height.slider", value: 70)
            check(near(model.transform(for: side).scaleX, 1.4005) && near(model.transform(for: side).scaleY, 0.7),
                  "\(side) unlocked width and height accept independent numeric and slider edits")
            try await press("image.\(side.rawValue).aspectLock")
            let ratio = model.transform(for: side).scaleX / model.transform(for: side).scaleY
            try await dragCorner(model, side: side, corner: .bottomRight, delta: NSPoint(x: 18, y: -12))
            check(near(model.transform(for: side).scaleX / model.transform(for: side).scaleY, ratio),
                  "\(side) re-lock preserves the current stretched aspect ratio while resizing")
            try await press("image.\(side.rawValue).reset")
            check(model.transform(for: side).isIdentity && model.aspectLocked(for: side),
                  "\(side) reset restores both axes, flips, position, rotation, and the aspect lock")
        }

        // Rotate and reflect the image before corner dragging. The screen corner
        // no longer corresponds to the unrotated rectangle's intuitive corner.
        for mode in [ImageComparisonMode.overlay, .wipe, .difference] {
            model.mode = mode
            model.alignmentSide = .right
            let corners = mode == .overlay ? ImageTransformCorner.allCases : [.topRight]
            for corner in corners {
                model.leftTransform = .identity
                model.rightTransform = ImageComparisonTransform(rotationDegrees: 27, offsetX: 55, offsetY: 40,
                                                                scaleX: 1.15, scaleY: 0.85,
                                                                flipHorizontal: true, flipVertical: true)
                if model.rightAspectLocked { try await press("image.right.aspectLock") }
                try await settled(model)
                let before = model.rightTransform
                let size = sourceSize(model, side: .right)
                let anchor = ImageTransformGeometry.corners(sourceSize: size, transform: before)[corner.opposite.rawValue]
                let originalWipe = model.wipePosition
                try await dragCorner(model, side: .right, corner: corner, delta: NSPoint(x: -18, y: 12))
                let after = model.rightTransform
                check(after != before && (after.scaleX != before.scaleX || after.scaleY != before.scaleY),
                      "\(mode).\(corner) rotated and flipped corner remains draggable")
                check(after.flipHorizontal && after.flipVertical && near(after.rotationDegrees, before.rotationDegrees),
                      "\(mode).\(corner) resize retains rotation and both flip flags")
                check(close(anchor, ImageTransformGeometry.corners(sourceSize: size, transform: after)[corner.opposite.rawValue]),
                      "\(mode).\(corner) resize fixes its opposite corner rather than panning")
                check(near(model.wipePosition, originalWipe) && model.leftTransform.isIdentity,
                      "\(mode).\(corner) handle does not move the wipe divider or the other image")
            }
        }

        let store = WorkspaceStore.shared
        let before = model.rightTransform
        let other = ComparisonSession(left: .init(text: "resize fixture"), right: .init(text: "tab state"))
        store.sessions.append(other); store.selectedID = other.id
        try await pause()
        store.selectedID = session.id
        try await pause()
        check(session.imageComparisonModel === model && model.rightTransform == before && !model.rightAspectLocked,
              "tab switching retains flips, unequal axes, rotation, and the per-side aspect-lock choice")
        store.sessions = [session]

        model.mode = .sideBySide
        for (name, dark, language) in [
            ("image-corner-resize-zh-light-860", false, AppLanguage.simplifiedChinese),
            ("image-corner-resize-en-dark-860", true, AppLanguage.english)
        ] {
            try await stage(name, width: 860, height: 580, dark: dark, language: language)
            try inspectImageColors(name, model: model)
            try await assertControls(model)
            for side in ImageComparisonSide.allCases {
                for corner in ImageTransformCorner.allCases { _ = try control(cornerID(side, corner)) }
                for feature in ["aspectLock", "flipHorizontal", "flipVertical"] {
                    let button = try control("image.\(side.rawValue).\(feature)")
                    let frame = try accessibilityFrame(button)
                    check(frame.width > 8 && frame.height > 8, "\(side) \(feature) remains accessible at 860 pixels")
                }
            }
        }
        model.mode = .overlay
        try await stage("image-corner-overlay-zh-dark", width: 1220, height: 790, dark: true, language: .simplifiedChinese)
        try await press("image.right.reset")
        check(model.rightTransform.isIdentity && model.rightAspectLocked,
              "reset after rotated, flipped, stretched corner dragging restores the original image")
        try await settled(model)
    }

    private static func cornerID(_ side: ImageComparisonSide, _ corner: ImageTransformCorner) -> String {
        let names = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
        return "image.\(side.rawValue).corner.\(names[corner.rawValue])"
    }

    private static func sourceSize(_ model: ImageComparisonModel, side: ImageComparisonSide) -> CGSize {
        side == .left ? model.preview!.leftSourceSize : model.preview!.rightSourceSize
    }

    private static func outwardDelta(_ corner: ImageTransformCorner) -> NSPoint {
        switch corner {
        case .topLeft: return NSPoint(x: -18, y: 12)
        case .topRight: return NSPoint(x: 18, y: 12)
        case .bottomRight: return NSPoint(x: 18, y: -12)
        case .bottomLeft: return NSPoint(x: -18, y: -12)
        }
    }

    private static func dragCorner(_ model: ImageComparisonModel, side: ImageComparisonSide,
                                   corner: ImageTransformCorner, delta: NSPoint, hitOffset: NSPoint = .zero) async throws {
        try await settled(model)
        _ = try control(cornerID(side, corner))
        let canvasID = model.mode == .sideBySide ? "image.canvas.\(side.rawValue)" : "image.canvas.combined"
        let frame = try accessibilityFrame(try control(canvasID))
        let preview = model.preview!
        let before = model.transform(for: side)
        let point = (side == .left ? preview.leftCorners : preview.rightCorners)[corner.rawValue]
        let origin = window.convertPoint(fromScreen: NSPoint(
            x: frame.minX + point.x * frame.width / CGFloat(preview.width) + hitOffset.x,
            y: frame.maxY - point.y * frame.height / CGFloat(preview.height) + hitOffset.y))
        try await dragWindowPoint(origin, description: cornerID(side, corner), delta: delta, holdForRender: true)
        try await settled(model)
        log("Corner result \(cornerID(side, corner)): before=\(before), after=\(model.transform(for: side)), interacting=\(model.isInteracting)")
        check(!model.isInteracting, "\(side).\(corner) mouse-up completes its interaction state")
    }

    private static func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.005 && abs(a.y - b.y) < 0.005
    }

    private static func settled(_ model: ImageComparisonModel) async throws {
        try await wait("latest transformed preview") { model.preview != nil && !model.isRendering && model.error == nil &&
            model.preview?.leftTransform == model.leftTransform.normalized &&
            model.preview?.rightTransform == model.rightTransform.normalized &&
            model.preview?.overlapOnly == model.overlapOnly }
        // A SwiftUI binding may have published before its debounced render starts.
        try await pause()
        try await wait("latest transformed preview settled") { model.preview != nil && !model.isRendering && model.error == nil &&
            model.preview?.leftTransform == model.leftTransform.normalized &&
            model.preview?.rightTransform == model.rightTransform.normalized &&
            model.preview?.overlapOnly == model.overlapOnly }
    }

    private static func assertControls(_ model: ImageComparisonModel) async throws {
        for side in ["left", "right"] {
            let target: ImageComparisonSide = side == "left" ? .left : .right
            let components = model.aspectLocked(for: target) ? ["scale", "rotation"] : ["width", "height", "rotation"]
            for component in components {
                let prefix = "image.\(side).\(component)"
                let slider = try control(prefix + ".slider")
                let field = try control(prefix + ".field")
                check(slider is NSSlider || string(slider, "accessibilityRole") == "AXSlider", "\(prefix) exposes an accessible slider")
                check(field is NSTextField || string(field, "accessibilityRole") == "AXTextField", "\(prefix) exposes an editable value")
                for element in [slider, field] {
                    if let view = element as? NSView {
                        let rect = view.convert(view.bounds, to: window.contentView)
                        check(rect.width > 12 && rect.height > 10 && window.contentView!.bounds.contains(rect),
                              "\(prefix) control remains inside the actual window")
                    }
                }
            }
        }
    }

    private static func changeSlider(_ id: String, value: Double) async throws {
        let object = try control(id)
        if let slider = object as? NSSlider {
            // SwiftUI can bridge its logical range through a normalized native
            // slider. Select the requested logical value through that range.
            let logical = id.contains(".rotation.") ? -180.0...180.0 : 10.0...400.0
            let fraction = (value - logical.lowerBound) / (logical.upperBound - logical.lowerBound)
            slider.doubleValue = slider.minValue + fraction * (slider.maxValue - slider.minValue)
            slider.sendAction(slider.action, to: slider.target)
        } else {
            let setter = NSSelectorFromString("setAccessibilityValue:")
            guard object.responds(to: setter) else { throw CheckError(description: "No value setter for \(id)") }
            object.perform(setter, with: NSNumber(value: value))
        }
        try await pause()
    }

    private static func editField(_ id: String, value: String) async throws {
        let editor = try focusField(id)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        window.makeFirstResponder(nil)
        try await pause()
    }

    private static func focusField(_ id: String) throws -> NSTextView {
        guard let field = try control(id) as? NSTextField else {
            throw CheckError(description: "Missing native text field for \(id)")
        }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw CheckError(description: "No field editor for \(id)") }
        return editor
    }

    private static func chooseMode(_ index: Int) async throws {
        let candidates = objects().compactMap { $0 as? NSSegmentedControl }
        guard let picker = candidates.first(where: { $0.segmentCount == ImageComparisonMode.allCases.count }) else {
            throw CheckError(description: "No native image mode segmented control")
        }
        picker.selectedSegment = index
        picker.sendAction(picker.action, to: picker.target)
        try await pause()
    }

    private static func press(_ id: String) async throws {
        let object = try control(id)
        if let button = object as? NSButton { button.performClick(nil) }
        else {
            let action = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: action) else { throw CheckError(description: "No press action for \(id)") }
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            let invoke = unsafeBitCast(object.method(for: action), to: Action.self)
            check(invoke(object, action), "\(id) accepts its accessibility action")
        }
        try await pause()
    }

    private static func dragCanvas(_ id: String, delta: NSPoint) async throws {
        try await dragElement(try control(id), description: id, delta: delta)
    }

    private static func accessibilityFrame(_ object: NSObject) throws -> NSRect {
        if let element = object as? NSAccessibilityElement { return element.accessibilityFrame() }
        if let view = object as? NSView { return view.accessibilityFrame() }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { throw CheckError(description: "Missing accessible frame") }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
    }

    private static func dragElement(_ object: NSObject, description: String, delta: NSPoint) async throws {
        let frame = try accessibilityFrame(object)
        let origin = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        try await dragWindowPoint(origin, description: description, delta: delta)
    }

    private static func dragWindowPoint(_ origin: NSPoint, description: String, delta: NSPoint,
                                        holdForRender: Bool = false) async throws {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if NSApp.keyWindow !== window { window.makeKeyAndOrderFront(nil) }
        try await wait("native drag test window active") { NSApp.isActive && NSApp.keyWindow === window }
        log("Native drag \(description): windowPoint=\(origin), delta=\(delta), active=\(NSApp.isActive), key=\(window.isKeyWindow)")
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp].enumerated() {
            let fraction = Double(min(index, 2)) / 2
            guard let event = NSEvent.mouseEvent(with: type,
                                                location: NSPoint(x: origin.x + delta.x * fraction, y: origin.y + delta.y * fraction),
                                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: index,
                                                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            // Queue our own app events together, so a native mouse-tracking loop
            // can consume the drag and mouse-up without blocking this async task.
            NSApp.postEvent(event, atStart: false)
            // Let an intermediate raster/layout publish before continuing a
            // corner gesture, so a moving canvas cannot hide behind one event batch.
            if holdForRender && index == 1 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        try await pause()
    }

    private static func control(_ id: String) throws -> NSObject {
        let matches = objects().filter { string($0, "accessibilityIdentifier") == id }
        if let native = matches.first(where: { $0 is NSControl }) { return native }
        if let cell = matches.first as? NSCell, let native = cell.controlView { return native }
        guard let result = matches.first else { throw CheckError(description: "Missing accessible control: \(id)") }
        return result
    }

    private static func objects() -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func descend(_ object: NSObject, depth: Int) {
            guard depth < 45, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                for child in children { descend(child, depth: depth + 1) }
            }
            if let view = object as? NSView {
                for child in view.subviews { descend(child, depth: depth + 1) }
            }
        }
        if let view = window.contentView { descend(view, depth: 0) }
        return result
    }

    private static func string(_ object: NSObject, _ attribute: String) -> String {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }

    private static func stage(_ name: String, width: Double, height: Double, dark: Bool, language: AppLanguage) async throws {
        AppSettings.shared.language = language
        AppAppearance.shared.isDark = dark
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: height), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        try await pause()
        window.contentView?.layoutSubtreeIfNeeded()
        guard let full = window.contentView?.superview,
              let bitmap = full.bitmapImageRepForCachingDisplay(in: full.bounds) else {
            throw CheckError(description: "No actual full-window bitmap for \(name)")
        }
        full.cacheDisplay(in: full.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CheckError(description: "No PNG for \(name)") }
        try data.write(to: output.appendingPathComponent(name + ".png"))
        let tree = objects().map { object in
            [String(describing: type(of: object)), string(object, "accessibilityIdentifier"), string(object, "accessibilityLabel"), string(object, "accessibilityValue")].joined(separator: " | ")
        }.joined(separator: "\n")
        try tree.write(to: output.appendingPathComponent(name + "-accessibility.txt"), atomically: true, encoding: .utf8)
        check(window.frame.width == width && window.frame.height == height && bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0,
              "\(name) captures the complete real window at the requested size")
        log("Rendered \(name)")
    }

    private static func writeFixture(_ url: URL, crop: Bool) throws {
        let width = crop ? 320 : 480, height = crop ? 220 : 320
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CheckError(description: "Unable to allocate PNG fixture")
        }
        for y in 0..<height {
            for x in 0..<width {
                let sx = x + (crop ? 80 : 0), sy = y + (crop ? 50 : 0)
                let card = (46..<420).contains(sx) && (35..<275).contains(sy)
                let header = card && sy < 95
                let circle = pow(Double(sx - 128), 2) + pow(Double(sy - 170), 2) < 48 * 48
                let line = (215..<380).contains(sx) && ((135..<148).contains(sy) || (171..<184).contains(sy) || (207..<220).contains(sy))
                let color = circle ? NSColor(deviceRed: 0.94, green: 0.58, blue: 0.23, alpha: 1)
                    : header ? NSColor(deviceRed: 0.16, green: 0.36, blue: 0.62, alpha: 1)
                    : line ? NSColor(deviceRed: 0.25, green: 0.62, blue: 0.57, alpha: 1)
                    : card ? NSColor(deviceRed: 0.96, green: 0.98, blue: 1, alpha: 1)
                    : NSColor(deviceRed: 0.84, green: 0.90, blue: 0.95, alpha: 1)
                bitmap.setColor(color, atX: x, y: y)
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CheckError(description: "Unable to encode PNG fixture") }
        try data.write(to: url)
    }

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
    private static func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() {
            if Date() > deadline { throw CheckError(description: "Timeout: \(label)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private static func pause() async throws { try await Task.sleep(nanoseconds: 250_000_000) }
    private static func check(_ value: Bool, _ description: String) {
        if !value { failures.append(description); log("FAIL: " + description) }
    }
    private static func log(_ value: String) {
        report.append(value); print(value); fflush(stdout)
        try? report.joined(separator: "\n").write(to: output.appendingPathComponent("progress.txt"), atomically: true, encoding: .utf8)
    }
}
