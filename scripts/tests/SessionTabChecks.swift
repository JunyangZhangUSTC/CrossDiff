import AppKit
import SwiftUI
import CrossDiffCore

/// Measures the real session card and its ancestor scroll viewport in a shipping
/// window. Test data, renders and restored sessions stay in the isolated build root.
@MainActor
enum SessionTabChecks {
    struct CheckError: Error { let description: String }
    static var window: NSWindow!
    static var report: [String] = []
    static var failures: [String] = []
    static var output: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]!) }

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-session-tab-checks/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-session-tab-checks/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { failures.append("Interrupted: \(error)") }
            let verdict = failures.isEmpty ? "PASS: overflowing session cards remain visible on selection, creation, close and resize; manual wheel scrolling survives unrelated refresh; hover scroller drags; real first-click selection/close; two/one/two tabs and bilingual light/dark renders"
                : "FAIL: " + failures.joined(separator: "; ")
            log(verdict)
            try? report.joined(separator: "\n").write(to: output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(failures.isEmpty ? 0 : 8)
        }
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await wait("own application window") {
            window = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
            return window != nil
        }
        AppSettings.shared.language = .english
        AppAppearance.shared.isDark = false
        window.appearance = NSAppearance(named: .aqua)
        window.setFrame(NSRect(x: -10000, y: -10000, width: 1220, height: 790), display: true)
        window.orderFront(nil)
        let store = WorkspaceStore.shared
        let fixtures = (1...12).map { index in
            let name = String(format: "%02d", index) + "-长名称-session-overflow-regression-source-file.txt"
            return ComparisonSession(left: .init(text: "unchanged\n", path: output.appendingPathComponent(name).path, savedText: "unchanged\n"),
                                     right: .init(text: "unchanged\n", savedText: "unchanged\n"))
        }
        store.sessions = fixtures
        store.selectedID = fixtures[0].id
        try await wait("twelve real session cards") { objects().contains { string($0, "accessibilityIdentifier") == tabID(fixtures[0]) } }
        try await pause()
        try await checkFirstClicks(fixtures)
        if ProcessInfo.processInfo.environment["CROSSDIFF_TAB_CLICKS_ONLY"] == "1" { return }
        store.sessions = fixtures
        store.selectedID = fixtures[0].id
        try await pause()
        logScrollViews()
        let scroll = try tabScrollView()
        check((scroll.documentView?.bounds.width ?? 0) > scroll.contentView.bounds.width + 500, "fixture genuinely overflows the native viewport")
        store.selectedID = fixtures.last!.id
        try await pause()
        try await pause()
        try capture("session-tabs-selected-last-light-1220")
        try assertVisible(fixtures.last!, label: "last selected card after switching from first of 12 long tabs")

        for index in [0, 5, 11] {
            store.selectedID = fixtures[index].id
            try await pause()
            try assertVisible(fixtures[index], label: "switch to tab \(index + 1)")
        }
        window.setFrame(NSRect(x: -10000, y: -10000, width: 860, height: 580), display: true)
        try await pause()
        try assertVisible(fixtures.last!, label: "selected last tab after resizing to 860 points")
        store.close(fixtures[2])
        try await pause()
        check(store.selectedID == fixtures.last!.id, "closing an earlier tab preserves selection")
        try assertVisible(fixtures.last!, label: "selected card after closing a preceding tab")

        store.newText()
        guard let added = store.selected else { throw CheckError(description: "New Text created no selected session") }
        added.left.path = output.appendingPathComponent("13-newly-created-long-name-session-overflow-check.txt").path
        try await pause()
        try assertVisible(added, label: "newly created long-name tab")
        added.left.path = output.appendingPathComponent("13-renamed-session-with-a-different-and-even-longer-comparison-filename.txt").path
        try await pause()
        try assertVisible(added, label: "selected tab after its title changes")

        // A short title lets the real dirty marker change the card's fitting width;
        // the resulting editor refresh still must not undo deliberate browsing.
        added.left.path = output.appendingPathComponent("13-short.txt").path
        try await pause()
        try assertVisible(added, label: "selected tab after shortening its title")

        let manualScroll = try tabScrollView()
        let selectedOffset = manualScroll.contentView.bounds.minX
        try wheel(manualScroll, horizontal: 220, vertical: 0)
        try await pause()
        let manualOffset = manualScroll.contentView.bounds.minX
        check(manualOffset < selectedOffset - 15, "horizontal wheel input moves the actual tab viewport")
        added.right.text = "Unrelated editor refresh\n"
        try await pause()
        try await pause()
        let refreshedScroll = try tabScrollView()
        check(abs(refreshedScroll.contentView.bounds.minX - manualOffset) < 2,
              "unrelated editor content and dirty-state refresh do not pull manual scrolling back to the active tab")
        let beforeVertical = refreshedScroll.contentView.bounds.minX
        try wheel(refreshedScroll, horizontal: 0, vertical: 80)
        try await pause()
        check(refreshedScroll.contentView.bounds.minX < beforeVertical - 5,
              "ordinary vertical mouse-wheel input scrolls the horizontal session strip")
        added.right.text = "" // Keep close checks free of an unsaved-content alert.

        try await setHover(false)
        let scroller = try tabScroller()
        check(scroller.isHiddenOrHasHiddenAncestor || scroller.alphaValue < 0.05,
              "overflow scroller is hidden after the pointer leaves the strip")
        try await setHover(true)
        check(!scroller.isHiddenOrHasHiddenAncestor && scroller.alphaValue > 0.5 && scroller.isEnabled,
              "pointer entry reveals an enabled native horizontal scroller")
        let beforeScrollerWheel = refreshedScroll.contentView.bounds.minX
        try wheel(scroller, horizontal: 60, vertical: 0)
        try await pause()
        check(refreshedScroll.contentView.bounds.minX < beforeScrollerWheel - 5,
              "wheel input over the visible scrollbar reaches the owning tab viewport")
        guard let bar = scroller.superview else { throw CheckError(description: "Missing scrollbar container") }
        let beforeBarWheel = refreshedScroll.contentView.bounds.minX
        try wheel(bar, horizontal: 0, vertical: 60)
        try await pause()
        check(refreshedScroll.contentView.bounds.minX < beforeBarWheel - 5,
              "wheel input in the tab strip's scrollbar lane reaches the owning tab viewport")
        check(store.selectedID == added.id, "wheel input over the scrollbar and its lane does not change selection")
        try capture("session-tabs-hover-scroller-light-860")
        try await dragScroller(scroller, in: refreshedScroll)
        try await setHover(false)

        store.selectedID = fixtures[0].id
        try await pause()
        try assertVisible(fixtures[0], label: "selection after manual wheel and scroller drag")
        store.selectedID = added.id
        try await pause()
        for (suffix, language, dark, width, height) in [
            ("en-light-1220", AppLanguage.english, false, 1220.0, 790.0),
            ("zh-light-860", .simplifiedChinese, false, 860.0, 580.0),
            ("zh-dark-1220", .simplifiedChinese, true, 1220.0, 790.0),
            ("en-dark-860", .english, true, 860.0, 580.0)
        ] {
            AppSettings.shared.language = language
            AppAppearance.shared.isDark = dark
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: height), display: true)
            try await pause()
            try assertVisible(added, label: "selected tab in \(suffix)")
            try capture("session-tabs-" + suffix)
        }

        store.sessions = [fixtures[0], added]
        store.selectedID = added.id
        try await pause()
        try assertVisible(added, label: "two-tab state")
        try await setHover(true)
        let smallScroller = try tabScroller()
        check(smallScroller.isHiddenOrHasHiddenAncestor || smallScroller.alphaValue < 0.05,
              "hover does not show a scrollbar when two tabs fit")
        store.close(fixtures[0])
        try await pause()
        check(store.sessions.count == 1 && store.selectedID == added.id, "two-to-one transition keeps the remaining session active")
        check(!objects().contains { string($0, "accessibilityIdentifier") == tabID(added) }, "single-session state removes the tab strip")
        store.sessions.append(fixtures[0]); store.selectedID = fixtures[0].id
        try await pause()
        try assertVisible(fixtures[0], label: "one-to-two transition restores a visible selected card")
    }

    /// Exercise NSWindow's actual mouse dispatch. Calling a button's action, AX
    /// press, or assigning selectedID would bypass the broken hit-test path.
    static func checkFirstClicks(_ fixtures: [ComparisonSession]) async throws {
        let store = WorkspaceStore.shared
        for (label, location) in [
            ("title", NSPoint(x: 0.50, y: 0.50)),
            ("icon", NSPoint(x: 16.0 / 320, y: 0.50)),
            ("left padding", NSPoint(x: 2.0 / 320, y: 0.50)),
            ("top padding", NSPoint(x: 0.50, y: 27.0 / 29)),
            ("bottom padding", NSPoint(x: 0.50, y: 2.0 / 29))
        ] {
            store.sessions = fixtures
            store.selectedID = fixtures[0].id
            try await focusSourceEditor(fixtures[0])
            try await setHover(false)
            try await setHover(true)
            try await assertSingleClick(fixtures[1], fraction: location, label: "editor focused / first hover entry / " + label)
        }
        store.sessions = fixtures
        store.selectedID = fixtures[0].id
        try await focusSourceEditor(fixtures[0])
        let scroll = try tabScrollView()
        try wheel(scroll, horizontal: -380, vertical: 0)
        try await pause()
        try await assertSingleClick(fixtures[2], fraction: NSPoint(x: 0.50, y: 0.50), label: "editor focused / after manual scrolling / title")

        for index in [1, 0] {
            store.sessions = fixtures
            store.selectedID = fixtures[0].id
            try await focusSourceEditor(fixtures[0])
            let closeFrame = try closeButtonFrame(fixtures[index])
            let beforeIDs = store.sessions.map(\.id)
            log("Native close click: card=\(NSStringFromRect(try tabFrame(fixtures[index]))), closeButton=\(NSStringFromRect(closeFrame))")
            try await click(at: window.convertPoint(fromScreen: NSPoint(x: closeFrame.midX, y: closeFrame.midY)))
            check(store.sessions.map(\.id) == beforeIDs.filter { $0 != fixtures[index].id },
                  "one real click on \(index == 0 ? "active" : "inactive") tab's actual close button closes only that tab")
            if index != 0 { check(store.selectedID == fixtures[0].id, "closing another tab leaves the current tab selected") }
        }
        store.sessions = fixtures
        store.selectedID = fixtures[0].id
        try await pause()
    }
    static func focusSourceEditor(_ session: ComparisonSession) async throws {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        try await wait("foreground tab-click test window") { NSApp.isActive && window.isKeyWindow }
        try await wait("source editor mounted before native tab click") {
            session.leftEditorState?.editor.window === window
        }
        window.makeFirstResponder(session.leftEditorState!.editor)
        try await pause()
        guard window.firstResponder === session.leftEditorState!.editor else {
            throw CheckError(description: "Cannot focus existing source NSTextView before tab click")
        }
    }
    /// AX SessionTab identifiers can resolve to their content-only accessibility
    /// group. Use the real direct hosting view to test the whole visual card.
    static func tabView(_ session: ComparisonSession) throws -> NSView {
        guard let document = try tabScrollView().documentView,
              let index = WorkspaceStore.shared.sessions.firstIndex(where: { $0.id == session.id }) else {
            throw CheckError(description: "Missing document or session for card geometry")
        }
        let cards = document.subviews.sorted { $0.frame.minX < $1.frame.minX }
        guard cards.count == WorkspaceStore.shared.sessions.count,
              index < cards.count, abs(cards[index].bounds.height - 29) < 0.5 else {
            throw CheckError(description: "Native session card geometry no longer matches the fixture")
        }
        return cards[index]
    }
    static func tabFrame(_ session: ComparisonSession) throws -> NSRect {
        let card = try tabView(session)
        return window.convertToScreen(card.convert(card.bounds, to: nil))
    }
    static func closeButtonFrame(_ session: ComparisonSession) throws -> NSRect {
        let card = try tabView(session)
        var candidates: [NSRect] = []
        for object in descendants(of: card) where string(object, "accessibilityRole") == "AXButton" {
            if let frame = try? accessibilityFrame(object), frame.width > 0, frame.width < 80, frame.height > 0 {
                candidates.append(frame)
            }
        }
        guard let frame = candidates.max(by: { $0.minX < $1.minX }) else {
            throw CheckError(description: "Missing actual close AX button frame")
        }
        return frame
    }
    static func assertSingleClick(_ session: ComparisonSession, fraction: NSPoint, label: String) async throws {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        try await wait("foreground condition immediately before click") { NSApp.isActive && window.isKeyWindow }
        let card = try tabView(session), frame = try tabFrame(session)
        let screenPoint = NSPoint(x: frame.minX + frame.width * fraction.x, y: frame.minY + frame.height * fraction.y)
        let point = window.convertPoint(fromScreen: screenPoint)
        let scroll = try tabScrollView(), clip = scroll.contentView
        let viewport = window.convertToScreen(clip.convert(clip.bounds, to: nil))
        guard viewport.contains(screenPoint) else { throw CheckError(description: "Click fixture outside viewport: " + label) }
        let firstResponder = String(describing: window.firstResponder.map { type(of: $0) })
        let hit = card.superview.flatMap { card.hitTest($0.convert(point, from: nil)) }
        let before = WorkspaceStore.shared.selectedID, beforeIDs = WorkspaceStore.shared.sessions.map(\.id)
        log("Native first click \(label): key=\(window.isKeyWindow), active=\(NSApp.isActive), card=\(NSStringFromRect(frame)), point=\(NSStringFromPoint(point)), hit=\(String(describing: hit.map { type(of: $0) })), priorResponder=\(firstResponder), selectedBefore=\(String(describing: before)), target=\(session.id)")
        try await click(at: point)
        let firstWorked = WorkspaceStore.shared.selectedID == session.id
        log("Native first click \(label): selectedAfter=\(String(describing: WorkspaceStore.shared.selectedID))")
        check(firstWorked && WorkspaceStore.shared.sessions.map(\.id) == beforeIDs,
              "one real click switches tabs without closing any: " + label)
        if !firstWorked {
            // Diagnostic retry uses exactly the same coordinates: distinguish a
            // swallowed first mouse-down from permanently dead card padding.
            try await click(at: point)
            log("Second identical click \(label): selected=\(WorkspaceStore.shared.selectedID == session.id)")
        }
    }
    static func click(at point: NSPoint) async throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw CheckError(description: "Cannot create native tab mouse event")
            }
            return value
        }
        // Queue release first in case AppKit enters a nested button tracking loop.
        // If it does not, drain that same release through NSWindow.sendEvent.
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        window.sendEvent(try event(.leftMouseDown))
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            window.sendEvent(release)
        }
        try await pause()
    }

    static func tabID(_ session: ComparisonSession) -> String { "session-tab." + session.id.uuidString }
    static func assertVisible(_ session: ComparisonSession, label: String) throws {
        guard let card = objects().first(where: { string($0, "accessibilityIdentifier") == tabID(session) }) else {
            throw CheckError(description: "Missing selected AX card: \(session.title)")
        }
        let frame = try accessibilityFrame(card)
        let scroll = try tabScrollView(), clip = scroll.contentView
        let viewport = window.convertToScreen(clip.convert(clip.bounds, to: nil))
        log("\(label): card=\(NSStringFromRect(frame)); viewport=\(NSStringFromRect(viewport)); clip=\(NSStringFromRect(clip.bounds))")
        let tolerance: CGFloat = 1.5
        check(frame.width > 40 && frame.height > 12 && frame.minX >= viewport.minX - tolerance
              && frame.maxX <= viewport.maxX + tolerance && frame.minY >= viewport.minY - tolerance
              && frame.maxY <= viewport.maxY + tolerance, label + " is fully inside the scroll viewport")
    }
    static func tabScrollView() throws -> NSScrollView {
        let candidates = views(window.contentView!).compactMap { $0 as? NSScrollView }.filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.bounds.height < 110 && $0.bounds.width > 400
        }
        guard candidates.count == 1, let scroll = candidates.first else {
            throw CheckError(description: "Expected one short, wide session scroll view; found \(candidates.count)")
        }
        return scroll
    }
    static func logScrollViews() {
        for scroll in views(window.contentView!).compactMap({ $0 as? NSScrollView }) {
            log("Scroll \(type(of: scroll)): frame=\(NSStringFromRect(scroll.frame)); clip=\(NSStringFromRect(scroll.contentView.bounds)); document=\(NSStringFromRect(scroll.documentView?.bounds ?? .zero)); horizontal=\(scroll.hasHorizontalScroller)")
        }
    }
    static func tabScroller() throws -> NSScroller {
        guard let scroller = views(window.contentView!).compactMap({ $0 as? NSScroller }).first(where: {
            $0.identifier?.rawValue == "session-tabs.scroller" || $0.accessibilityIdentifier() == "session-tabs.scroller"
        }) else { throw CheckError(description: "Missing native session-tabs.scroller") }
        return scroller
    }
    static func wheel(_ target: NSResponder, horizontal: Int32, vertical: Int32) throws {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
            throw CheckError(description: "Cannot construct scroll-wheel event")
        }
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(vertical))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(horizontal))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        guard let event = NSEvent(cgEvent: cg) else { throw CheckError(description: "Cannot bridge scroll-wheel event") }
        target.scrollWheel(with: event)
    }
    static func setHover(_ entered: Bool) async throws {
        let scroll = try tabScrollView()
        var current: NSView? = scroll
        var target: (NSView, NSTrackingArea)?
        while let view = current, view.bounds.height < 110 {
            view.updateTrackingAreas()
            if let area = view.trackingAreas.first(where: { $0.options.contains(.mouseEnteredAndExited) && $0.owner is NSView }) {
                target = (view, area); break
            }
            current = view.superview
        }
        guard let (view, area) = target, let owner = area.owner as? NSView else {
            throw CheckError(description: "Missing native pointer-entry/exit tracking area on the session strip")
        }
        let point = entered ? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            : NSPoint(x: view.bounds.midX, y: view.bounds.maxY + 20)
        guard let event = NSEvent.enterExitEvent(with: entered ? .mouseEntered : .mouseExited,
            location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else {
            throw CheckError(description: "Cannot construct pointer tracking event")
        }
        if entered { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
        try await pause()
    }
    static func dragScroller(_ scroller: NSScroller, in scroll: NSScrollView) async throws {
        let knob = scroller.rect(for: .knob)
        guard knob.width > 0 && knob.height > 0 else { throw CheckError(description: "Native scroller has no draggable knob") }
        let origin = scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        let before = scroll.contentView.bounds.minX
        let shift: CGFloat = before > 150 ? -100 : 100
        func event(_ type: NSEvent.EventType, fraction: CGFloat) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: type,
                location: NSPoint(x: origin.x + shift * fraction, y: origin.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw CheckError(description: "Cannot construct scroller drag event")
            }
            return value
        }
        // Queue the drag and release before mouseDown enters native event tracking.
        NSApp.postEvent(try event(.leftMouseDragged, fraction: 0.5), atStart: false)
        NSApp.postEvent(try event(.leftMouseDragged, fraction: 1), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, fraction: 1), atStart: false)
        scroller.mouseDown(with: try event(.leftMouseDown, fraction: 0))
        try await pause()
        check(abs(scroll.contentView.bounds.minX - before) > 20, "dragging the native scroller knob changes the actual tab viewport")
    }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func objects() -> [NSObject] {
        guard let content = window.contentView else { return [] }
        return descendants(of: content)
    }
    static func descendants(of root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func descend(_ object: NSObject, depth: Int) {
            guard depth < 60, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                for child in children { descend(child, depth: depth + 1) }
            }
            if let view = object as? NSView { for child in view.subviews { descend(child, depth: depth + 1) } }
        }
        descend(root, depth: 0)
        return result
    }
    static func string(_ object: NSObject, _ attribute: String) -> String {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    static func accessibilityFrame(_ object: NSObject) throws -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { throw CheckError(description: "Missing accessibility frame") }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
    }
    static func capture(_ name: String) throws {
        guard let view = window.contentView?.superview else { throw CheckError(description: "Missing window chrome") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckError(description: "Cannot allocate window render") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CheckError(description: "Cannot encode window render") }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
    static func wait(_ label: String, until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CheckError(description: "Timed out: " + label)
    }
    static func pause() async throws { try await Task.sleep(nanoseconds: 300_000_000) }
    static func check(_ condition: Bool, _ label: String) { if !condition { failures.append(label) }; log((condition ? "OK: " : "FAIL: ") + label) }
    static func log(_ value: String) {
        report.append(value); print(value); fflush(stdout)
        try? report.joined(separator: "\n").write(to: output.appendingPathComponent("progress.txt"), atomically: true, encoding: .utf8)
    }
}
