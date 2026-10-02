import Foundation
import CrossDiffCore

private actor ExecutionProbe {
    var count = 0, active = 0, maximumActive = 0
    var holding = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    func hold() { holding = true }
    func release() {
        holding = false
        let continuations = waiting; waiting = []
        for continuation in continuations { continuation.resume() }
    }
    func run(_ inputs: [PluginInput], _ options: [String: PluginJSONValue]) async -> PluginComparisonResult {
        count += 1; let number = count
        active += 1; maximumActive = max(maximumActive, active)
        if holding { await withCheckedContinuation { waiting.append($0) } }
        active -= 1
        // The execution seam deliberately ignores cancellation. The model must
        // reject an obsolete result even from an uncooperative provider.
        return PluginComparisonResult(runID: "model-\(number)", schema: "crossdiff.office/1",
            summary: .init(zhHans: "\(number)", en: "\(number)"), payload: .object(["rows": .array([])]))
    }
}

@main enum OfficeModelChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }; checks += 1
    }
    @MainActor static func wait(_ message: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Timed out: " + message)
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let left = root.appendingPathComponent("model-left.xlsx"), right = root.appendingPathComponent("model-right.xlsx")
        let probe = ExecutionProbe()
        let execute: OfficeComparisonModel.Execute = { inputs, options in await probe.run(inputs, options) }
        let model = OfficeComparisonModel()
        var notifications = 0
        model.onStateChanged = { notifications += 1 }
        await model.load(left: left, right: right, execute: execute, executionID: "model-check")
        try check(model.error == nil && model.comparison != nil && !model.isLoading && !model.isComparing, "Initial import and comparison complete")
        try check(model.leftSection?.name == "Alpha" && model.rightSection?.name == "Alpha", "Initial pairing uses the same sheet name across reordered sheets")
        let firstCount = await probe.count
        let firstNotifications = notifications
        model.state.onlyDifferences = true
        try await Task.sleep(nanoseconds: 140_000_000)
        let filteredCount = await probe.count
        try check(firstCount == filteredCount && notifications > firstNotifications, "Only-differences selection persists without rerunning the provider")
        let leftBeta = try require(model.leftDocument?.sections.first { $0.name == "Beta" })
        model.selectSection(leftBeta.id, side: .left)
        try await wait("left navigation rerun") { !model.isComparing }
        try check(model.leftSection?.name == "Beta" && model.rightSection?.name == "Beta", "Left navigation follows a same-name sheet across a different position")
        let rightAlpha = try require(model.rightDocument?.sections.first { $0.name == "Alpha" })
        model.selectSection(rightAlpha.id, side: .right)
        try await wait("right navigation rerun") { !model.isComparing }
        try check(model.leftSection?.name == "Beta" && model.rightSection?.name == "Alpha", "Right selection remains independent")
        let snapshot = model.leftDocument
        let original = try Data(contentsOf: left)
        try Data("modified after import".utf8).write(to: left)
        defer { try? original.write(to: left) }
        model.state.keyColumns = [1]
        try await wait("key rerun from snapshot") { !model.isComparing }
        try check(model.error == nil && model.leftDocument == snapshot, "Changing keys compares the immutable snapshot without rereading a changed source")
        let saved = StoredComparison(kind: "plugin", left: .init(path: left.path), right: .init(path: right.path), pluginID: "org.crossdiff.office", officeState: model.state)
        let restored = try JSONDecoder().decode(StoredComparison.self, from: JSONEncoder().encode(saved))
        try check(restored.officeState == model.state && restored.left.text.isEmpty && restored.right.text.isEmpty, "Session persists only selection and key state, not imported document contents")
        let restoredModel = OfficeComparisonModel(state: restored.officeState!)
        try check(restoredModel.state == model.state, "A restored model retains navigation and filters")
        model.invalidateSources()
        await model.load(left: left, right: right, execute: execute, executionID: "model-check")
        try check(model.error != nil && model.comparison == nil && !model.isLoading, "Explicit reload detects changed invalid source and clears the stale result")
        try original.write(to: left)
        await model.load(left: left, right: right, execute: execute, executionID: "model-check")
        try check(model.error == nil && model.comparison != nil, "A failed reload can recover after the source is repaired")
        await probe.hold()
        let before = await probe.count
        model.state.keyColumns = [2]
        try await wait("held provider starts") { await probe.count == before + 1 }
        model.state.keyColumns = [1, 2]
        try await Task.sleep(nanoseconds: 150_000_000)
        let heldCount = await probe.count
        try check(heldCount == before + 1 && model.comparison == nil, "A newer request waits for the cancelled predecessor and clears obsolete display")
        await probe.release()
        try await wait("latest provider finishes") { !model.isComparing && model.comparison != nil }
        let maximumActive = await probe.maximumActive
        try check(model.result?.summary.en == String(before + 2) && maximumActive == 1, "Late cancelled output cannot replace the newest result; provider runs never overlap")
        await probe.hold()
        let beforeCancel = await probe.count
        model.state.keyColumns = []
        try await wait("cancelled provider starts") { await probe.count == beforeCancel + 1 }
        model.cancel()
        await probe.release()
        try await Task.sleep(nanoseconds: 140_000_000)
        try check(!model.isComparing && !model.isLoading && model.comparison == nil, "Closing or cancelling cannot publish a late provider result")
        let mismatched = OfficeComparisonModel()
        let mismatchCount = await probe.count
        await mismatched.load(left: left, right: root.appendingPathComponent("wrong.docx"), execute: execute, executionID: "mixed")
        let afterMismatch = await probe.count
        try check(mismatched.error != nil && afterMismatch == mismatchCount, "Mixed Office families fail before file import or plugin execution")
        let empty = OfficeComparisonModel()
        let emptyURL = root.appendingPathComponent("model-empty.xlsx")
        await empty.load(left: emptyURL, right: emptyURL, execute: execute, executionID: "empty")
        try check(empty.error == nil && empty.comparison != nil && empty.leftSection == nil && !empty.isLoading && !empty.isComparing, "An empty workbook completes without a stuck loading state")
        let invalid = OfficeComparisonModel(state: OfficeWorkspaceState(keyColumns: [0]))
        try check(invalid.state == OfficeWorkspaceState(), "Invalid restored matching state falls back safely")
        print("Office model checks: \(checks) passed")
    }
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(description: "Missing fixture section") }; return value
    }
}
