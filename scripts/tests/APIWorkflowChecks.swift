import AppKit
import CrossDiffCore

@MainActor enum APIWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-api-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: real API plugin, paste/file creation, HTTP/cURL/HAR, rules, credential masking, persistence, stale-result protection, native themes, base installation" : "FAIL: " + D.failures.joined(separator: "; ")
            try? (D.report + [verdict]).joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            print(verdict); exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static let leftSource = """
    curl 'https://api.example.test/v1/profile?tag=one&tag=two' -H 'Content-Type: application/json' -H 'Authorization: Bearer DEMO_LEFT_ONLY' -H 'X-Request-ID: request-a' --data-raw '{"user":{"name":"Jun","age":25,"role":"reader"},"token":"DEMO_TOKEN_LEFT","nullable":null,"timestamp":1000}'
    """
    static let rightSource = """
    POST https://api.example.test/v1/profile?tag=one&tag=three HTTP/1.1
    Content-Type: application/json
    Authorization: Bearer DEMO_RIGHT_ONLY
    X-Request-ID: request-b

    {"user":{"name":"Jun","age":"25","role":"editor"},"token":"DEMO_TOKEN_RIGHT","active":true,"timestamp":1001}
    """
    static func run() async throws {
        let root = D.output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        try await D.wait("own native window") {
            D.window = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
            return D.window != nil
        }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        D.check(APIComparisonPresentation.summaryURL("https://example:x@localhost.test/profile?token=DEMO_QUERY#secret") == "https://localhost.test/profile", "compact API headings omit userinfo, query and fragments")
        let first = try await create(left: .text(leftSource), right: .text(rightSource))
        let model = first.apiComparisonModel
        try await ready(model)
        D.check(first.left.path == nil && first.right.path == nil && !first.dirty, "API creation retains pasted input without a fake file or dirty text editor")
        let rows = model.comparison!.rows
        D.check(rows.contains { $0.path == "/user/age" && $0.leftType == "number" && $0.rightType == "string" && $0.state == .changed }, "actual restricted plugin shows number-to-string JSON change")
        D.check(rows.contains { $0.path == "/nullable" && $0.left == "null" && $0.right == nil && $0.state == .removed }, "missing differs from explicit JSON null")
        D.check(rows.filter { $0.section == "request.query" && $0.label == "tag" }.count == 2, "repeated query fields remain individually visible")
        D.check(rows.contains { $0.sensitive && $0.state == .changed }, "credential masking does not suppress comparison")
        AppSettings.shared.language = .simplifiedChinese
        try await press("api.differencesOnly")
        try await render("api-changes-light", width: 1220, height: 790, dark: false)
        D.check(!accessibleText().contains("DEMO_LEFT_ONLY"), "hidden credential values are absent from the accessibility hierarchy")
        try await search("/user/age")
        try await render("api-search-light", width: 1220, height: 790, dark: false)
        let filteredText = accessibleText()
        try filteredText.write(to: D.output.appendingPathComponent("search-accessibility.txt"), atomically: true, encoding: .utf8)
        D.check(filteredText.contains("/user/age") && !filteredText.contains("/authorization/0"), "native field search filters the structured comparison")
        try await search("DEMO_LEFT_ONLY")
        D.check(accessibleText().contains("没有符合筛选的字段"), "masked credential values cannot be discovered through search")
        try await search("")
        try await press("api.showCredentials")
        D.check(accessibleText().contains("DEMO_LEFT_ONLY"), "explicit reveal displays the credential value")
        try await press("api.showCredentials")
        AppSettings.shared.language = .english
        try await render("api-changes-dark-narrow", width: 860, height: 580, dark: true)
        model.applyRules(headers: ["X-Request-ID"], pointers: ["/timestamp", "/user"])
        try await ready(model)
        D.check(model.comparison!.rows.filter { $0.state == .ignored }.count >= 5, "explicit header and JSON subtree rules mark affected rows")
        try await press("api.showIgnored")
        try await render("api-rules-light-narrow", width: 860, height: 620, dark: false)
        try await press("api.ignoreRules")
        try await render("api-rules-popover", width: 860, height: 790, dark: false)
        try await renderPopover("api-ignore-popover-light")
        AppAppearance.shared.isDark = true; try await D.pause()
        try await renderPopover("api-ignore-popover-dark")
        // Clicking the same popover's Cancel closes only this process's transient UI.
        try await pressTitle("Cancel")
        let restored = try JSONDecoder().decode([StoredComparison].self, from: JSONEncoder().encode([first.snapshot]))[0]
        D.check(restored.apiState == model.state && restored.left.text == leftSource, "rules and original pasted input persist through actual session snapshots")
        model.clearRules(); try await ready(model)
        D.check(!model.comparison!.rows.contains { $0.state == .ignored }, "clearing rules reclassifies the original values")
        try selectSection(3); try await D.pause()
        D.check(!accessibleText().contains("DEMO_LEFT_ONLY"), "raw source is not exposed by selecting its tab")
        try await press("api.revealSource")
        D.check(accessibleText().contains("DEMO_LEFT_ONLY"), "source disclosure requires its explicit action")
        try await render("api-source-dark", width: 1220, height: 790, dark: true)

        let leftHAR = root.appendingPathComponent("previous.har")
        let leftHARText = try har(age: 25), rightHARText = try har(age: 26)
        try leftHARText.write(to: leftHAR, atomically: true, encoding: .utf8)
        let jsonHAR = root.appendingPathComponent("recording.json"), textHTTP = root.appendingPathComponent("recording.txt")
        try leftHARText.write(to: jsonHAR, atomically: true, encoding: .utf8)
        try rightSource.write(to: textHTTP, atomically: true, encoding: .utf8)
        let apiType = NewComparisonType(kind: .plugin, pluginID: "org.crossdiff.api")
        try apiType.validate(jsonHAR); try apiType.validate(textHTTP)
        D.check(PluginManager.shared.matching(jsonHAR) == nil && PluginManager.shared.matching(textHTTP) == nil, "explicit API import accepts JSON/TXT without taking over ordinary text opening")
        let original = try Data(contentsOf: leftHAR)
        let second = try await create(left: .file(leftHAR), right: .text(rightHARText))
        let harModel = second.apiComparisonModel
        try await ready(harModel)
        D.check(harModel.leftDocument?.exchanges.count == 2 && harModel.rightDocument?.exchanges.count == 2, "HAR imports independent lists rather than guessing pairs")
        harModel.selectEntry("1", side: .left); harModel.selectEntry("1", side: .right)
        try await ready(harModel)
        D.check(harModel.leftExchange?.response?.statusCode == "200" && harModel.comparison!.rows.contains { $0.section == "response.body" && $0.path == "/age" && $0.state == .changed }, "HAR entry selection compares selected response structures")
        AppSettings.shared.language = .simplifiedChinese
        try await render("api-har-light", width: 1220, height: 790, dark: false)
        AppSettings.shared.language = .english
        try await render("api-har-dark-narrow", width: 860, height: 620, dark: true)
        let restoredHAR = try JSONDecoder().decode(StoredComparison.self, from: JSONEncoder().encode(second.snapshot))
        D.check(restoredHAR.apiState?.leftEntryID == "1" && restoredHAR.apiState?.rightEntryID == "1", "both explicit HAR entry selections persist")
        D.check(try Data(contentsOf: leftHAR) == original, "comparison never rewrites input files")

        let external = PluginManager(directory: root.appendingPathComponent("base-plugin-data"), bundledDirectory: root.appendingPathComponent("no-bundled-plugins"))
        external.pendingPackage = try PluginPackage.load(from: root.appendingPathComponent("Plugins/API.crossdiffplugin"))
        external.installPending(trustNative: false)
        D.check(external.plugin(id: "org.crossdiff.api")?.enabled == true, "base edition can install the real restricted API package")
        let execution = try external.execution(for: "org.crossdiff.api")
        try await snapshotAndSchedulingChecks(root: root, execute: { try await execution.compare($0, options: $1) })
    }
    static func create(left: NewComparisonInput, right: NewComparisonInput) async throws -> ComparisonSession {
        let store = WorkspaceStore.shared
        store.beginNewComparison()
        try await D.wait("API creation sheet") { store.newComparison != nil && D.window.attachedSheet != nil }
        guard let draft = store.newComparison, let type = draft.types.first(where: { $0.pluginID == "org.crossdiff.api" }) else {
            throw D.CheckError(description: "Missing API creation entry")
        }
        draft.select(type); draft.setInput(left, side: .left); draft.setInput(right, side: .right)
        D.check(draft.canCreate, "API supports this explicit pair of paste/file inputs")
        draft.create()
        try await D.wait("API creation completes") { store.newComparison == nil && D.window.attachedSheet == nil && store.selected?.pluginID == "org.crossdiff.api" }
        return store.selected!
    }
    static func har(age: Int) throws -> String {
        let entries: [[String: Any]] = [
            ["request": ["method": "GET", "url": "https://api.example.test/health", "httpVersion": "HTTP/1.1", "headers": [], "queryString": []],
             "response": ["status": 204, "statusText": "No Content", "httpVersion": "HTTP/1.1", "headers": [], "content": ["mimeType": "text/plain", "size": 0, "text": ""]]],
            ["request": ["method": "GET", "url": "https://api.example.test/profile", "httpVersion": "HTTP/1.1", "headers": [], "queryString": []],
             "response": ["status": 200, "statusText": "OK", "httpVersion": "HTTP/1.1", "headers": [["name": "Content-Type", "value": "application/json"]], "content": ["mimeType": "application/json", "text": "{\"age\":\(age),\"name\":\"Jun\"}"]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["log": ["version": "1.2", "entries": entries]], options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    static func snapshotAndSchedulingChecks(root: URL, execute: @escaping APIComparisonModel.Execute) async throws {
        let source = root.appendingPathComponent("snapshot.http")
        let original = "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"value\":1}"
        try original.write(to: source, atomically: true, encoding: .utf8)
        let left = StoredTextSide(path: source.path), right = StoredTextSide(text: original)
        let model = APIComparisonModel()
        await model.load(left: left, right: right, execute: execute, executionID: "snapshot")
        try await ready(model)
        let replacement = original.replacingOccurrences(of: "1}", with: "2}")
        try replacement.write(to: source, atomically: true, encoding: .utf8)
        model.applyRules(headers: ["Date"], pointers: [])
        try await ready(model)
        D.check(model.comparison!.rows.first { $0.path == "/value" }?.state == .same, "rule changes compare the retained imported snapshot")
        model.invalidateSources()
        await model.load(left: left, right: right, execute: execute, executionID: "snapshot")
        try await ready(model)
        D.check(model.comparison!.rows.first { $0.path == "/value" }?.state == .changed, "manual reload imports an external source change")
        let counter = ExecutionCounter()
        let observed: APIComparisonModel.Execute = { inputs, options in
            await counter.begin()
            await withCheckedContinuation { continuation in DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { continuation.resume() } }
            do { let result = try await execute(inputs, options); await counter.end(); return result }
            catch { await counter.end(); throw error }
        }
        await model.load(left: left, right: right, execute: observed, executionID: "scheduling")
        try await ready(model)
        for index in 0..<20 { model.applyRules(headers: ["X-\(index)"], pointers: index == 19 ? ["/value"] : []) }
        try await ready(model)
        D.check(model.comparison!.rows.first { $0.path == "/value" }?.state == .ignored, "rapid changes publish only the final comparison rules")
        let maximum = await counter.maximum
        D.check(maximum == 1, "superseded API plugin runs are joined before another begins")
        let missing = StoredTextSide(text: "HTTP/1.1 200 OK\nContent-Type: application/json")
        await model.load(left: missing, right: missing, execute: execute, executionID: "unknown")
        try await ready(model)
        let bodyRows = model.comparison!.rows.filter { $0.section == "response.body" }
        D.check(!bodyRows.isEmpty && bodyRows.allSatisfy { $0.state == .unknown } && !model.diagnostics.isEmpty, "missing response bodies remain explicitly unknown, never equal or added/removed")
        let composed = "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"value\":\"caf\u{e9}\"}"
        let decomposed = "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"value\":\"cafe\u{301}\"}"
        model.clearRules()
        await model.load(left: .init(text: composed), right: .init(text: composed), execute: execute, executionID: "unicode")
        try await ready(model)
        await model.load(left: .init(text: decomposed), right: .init(text: composed), execute: execute, executionID: "unicode")
        try await ready(model)
        D.check(model.leftDocument!.source.utf8.elementsEqual(decomposed.utf8) && model.comparison!.rows.contains { $0.path == "/value" && $0.state == .changed }, "canonically equivalent source strings retain distinct imported bytes and trigger comparison")
        let dualKeys = "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"caf\u{e9}\":1,\"cafe\u{301}\":2}"
        let parsed = APIComparisonPresentation.parseRuleLines("/caf\u{e9}\n/cafe\u{301}\n/name ", trimWhitespace: false)
        D.check(parsed.count == 3 && parsed.last == "/name ", "rule editor retains distinct Unicode pointers and intentional spaces")
        await model.load(left: .init(text: dualKeys), right: .init(text: dualKeys), execute: execute, executionID: "unicode-rules")
        try await ready(model)
        model.applyRules(headers: [], pointers: ["/caf\u{e9}"]); try await ready(model)
        D.check(model.comparison!.rows.filter { $0.state == .ignored }.count == 1 && model.comparison!.rows.first { $0.state == .ignored }!.path.utf8.elementsEqual("/caf\u{e9}".utf8), "first Unicode pointer ignores exactly its own code points")
        model.applyRules(headers: [], pointers: ["/cafe\u{301}"]); try await ready(model)
        D.check(model.comparison!.rows.filter { $0.state == .ignored }.count == 1 && model.comparison!.rows.first { $0.state == .ignored }!.path.utf8.elementsEqual("/cafe\u{301}".utf8), "changing to a canonically equivalent pointer invalidates the comparison")
        model.cancel()
    }
    actor ExecutionCounter {
        var active = 0, maximum = 0
        func begin() { active += 1; maximum = max(maximum, active) }
        func end() { active -= 1 }
    }
    static func ready(_ model: APIComparisonModel) async throws {
        let deadline = Date().addingTimeInterval(45)
        while model.isLoading || model.isComparing || model.comparison == nil {
            if let error = model.error { throw error }
            if Date() > deadline { throw D.CheckError(description: "API comparison timeout") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if let error = model.error { throw error }
        try await D.pause()
    }
    static func render(_ name: String, width: Double, height: Double, dark: Bool) async throws {
        AppAppearance.shared.isDark = dark
        D.window.setContentSize(NSSize(width: width, height: height)); D.window.orderFront(nil)
        try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
        let view = D.window.contentView!.superview ?? D.window.contentView!
        let bitmap = try D.capture(view, rect: view.bounds, name: name)
        D.check(bitmap.pixelsWide >= Int(width), "\(name) renders the actual full parent window")
    }
    static func renderPopover(_ name: String) async throws {
        guard let window = NSApp.windows.first(where: { $0 !== D.window && $0.isVisible && $0.contentView != nil && $0.frame.width > 250 && $0.frame.height > 100 }) else {
            throw D.CheckError(description: "Missing rules popover window")
        }
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let view = window.contentView!.superview ?? window.contentView!
        _ = try D.capture(view, rect: view.bounds, name: name)
    }
    static func press(_ identifier: String) async throws {
        let matches = objects().filter { string($0, "accessibilityIdentifier") == identifier }
        guard let object = matches.first(where: { $0 is NSControl }) ?? matches.first else { throw D.CheckError(description: "Missing control: \(identifier)") }
        try perform(object); try await D.pause()
    }
    static func search(_ value: String) async throws {
        guard let field = objects().compactMap({ $0 as? NSTextField }).first(where: {
            $0.isEditable && ($0.placeholderString?.contains("字段") == true || $0.placeholderString?.contains("field") == true)
        }) else { throw D.CheckError(description: "Missing native API search field") }
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await D.pause()
    }
    static func pressTitle(_ title: String) async throws {
        guard let object = objects().first(where: { string($0, "accessibilityLabel") == title || ($0 as? NSButton)?.title == title }) else { throw D.CheckError(description: "Missing button: \(title)") }
        try perform(object); try await D.pause()
    }
    static func perform(_ object: NSObject) throws {
        if let button = object as? NSButton { button.performClick(nil); return }
        let action = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: action) else { throw D.CheckError(description: "Control cannot press") }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        D.check(unsafeBitCast(object.method(for: action), to: Action.self)(object, action), "native control dispatches its action")
    }
    static func selectSection(_ index: Int) throws {
        guard let picker = objects().compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount == 4 && ["全部", "All"].contains($0.label(forSegment: 0) ?? "") }) else {
            throw D.CheckError(description: "Missing API section control")
        }
        picker.selectedSegment = index
        D.check(picker.sendAction(picker.action, to: picker.target), "native section control dispatches selection")
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
        for window in NSApp.windows where window.isVisible { if let view = window.contentView { descend(view, depth: 0) } }
        return result
    }
    static func string(_ object: NSObject, _ attribute: String) -> String {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    static func accessibleText() -> String {
        objects().flatMap { [string($0, "accessibilityValue"), string($0, "accessibilityLabel")] }.joined(separator: "\n")
    }
}
