import Foundation
import Darwin
import CrossDiffCore

@main
enum PluginCoreChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
        count += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; return }
        throw Failure(description: message)
    }
    static func manifest(id: String = "org.example.lines", version: String = "1.0.0", runtime: PluginRuntimeProfile = .restrictedJavaScript, modes: [PluginComparisonMode] = [.pairwise]) -> PluginManifest {
        PluginManifest(id: id, version: version,
                       name: .init(zhHans: "行比较", en: "Line comparison"),
                       summary: .init(zhHans: "比较文字", en: "Compare text"),
                       runtime: runtime, inputKind: .text,
                       fileExtensions: ["txt"], resultView: "table", supportedModes: modes,
                       minHostProtocol: 1, maxHostProtocol: 1)
    }
    static func scriptPackage(version: String, script: String = "abc") -> PluginPackage {
        PluginPackage(manifest: manifest(version: version), script: script, sha256: PluginPackage.digest(of: Data(script.utf8)))
    }
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let request = PluginComparisonRequest(protocolVersion: 1, runID: "run-1", mode: .pairwise,
            inputs: [.init(id: "a", role: .left, name: "左", content: .object(["text": .string("甲\n乙")])),
                     .init(id: "b", role: .right, name: "右", content: .object(["text": .string("甲\n丙")]))], options: [:])
        try request.validate(for: manifest())
        let decoded = try JSONDecoder().decode(PluginComparisonRequest.self, from: JSONEncoder().encode(request))
        try expect(decoded.inputs[0].content["text"]?.stringValue == "甲\n乙", "JSON input must retain original Unicode and newlines")
        let malformed = PluginComparisonRequest(protocolVersion: 1, runID: "run-1", mode: .pairwise,
            inputs: [request.inputs[0], request.inputs[0]], options: [:])
        try rejects("pairwise requires distinct left and right inputs") { try malformed.validate(for: manifest()) }
        let packageJSON = """
        {"formatVersion":1,"manifest":\(String(data: try JSONEncoder().encode(manifest()), encoding: .utf8)!),
         "script":"abc","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}
        """
        let package = try PluginPackage.decode(data: Data(packageJSON.utf8))
        try expect(package.payloadData == Data("abc".utf8), "package decoding must preserve script bytes")
        let tampered = packageJSON.replacingOccurrences(of: "\"script\":\"abc\"", with: "\"script\":\"abd\"")
        try rejects("a changed payload must not pass the declared digest") { _ = try PluginPackage.decode(data: Data(tampered.utf8)) }
        let traversal = packageJSON.replacingOccurrences(of: "org.example.lines", with: "../outside")
        try rejects("plugin IDs must not escape the store") { _ = try PluginPackage.decode(data: Data(traversal.utf8)) }
        let result = PluginComparisonResult(runID: "run-1", schema: "crossdiff.table/1",
            summary: .init(zhHans: "有变化", en: "Changed"), payload: .object(["rows": .array([])]))
        try result.validate(for: request, manifest: manifest())
        let stale = PluginComparisonResult(runID: "previous-run", schema: "crossdiff.table/1",
            summary: result.summary, payload: result.payload)
        try rejects("stale worker output must not replace the current comparison") { try stale.validate(for: request, manifest: manifest()) }
        let unknown = PluginComparisonResult(runID: "run-1", schema: "arbitrary/99",
            summary: result.summary, payload: result.payload)
        try rejects("unknown results must not be rendered as a supported table") { try unknown.validate(for: request, manifest: manifest()) }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = fixtures.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try PluginStore(root: root)
        let installed = try store.install(package)
        try expect(installed.activeVersion == "1.0.0" && installed.isEnabled, "a validated plugin is available after installation")
        try store.setEnabled(false, for: package.manifest.id)
        let reopened = try PluginStore(root: root)
        try expect(reopened.list().first?.isEnabled == false, "disabled state survives reopening the store")
        let retained = try reopened.package(id: package.manifest.id)
        try expect(retained == package, "disabled installation retains its immutable package")
        let upgrade = scriptPackage(version: "1.1.0", script: "abcd")
        _ = try reopened.install(upgrade)
        try expect(reopened.list().first?.previousVersion == "1.0.0", "updates retain the previous version")
        try reopened.rollback(id: package.manifest.id)
        let rolledBack = try reopened.package(id: package.manifest.id)
        try expect(rolledBack == package, "rollback restores the exact previous algorithm")
        let collision = scriptPackage(version: "1.0.0", script: "changed")
        try rejects("an installed version cannot be replaced by different code") { _ = try reopened.install(collision) }
        let afterConflict = try reopened.package(id: package.manifest.id)
        try expect(afterConflict == package, "a version collision leaves the current algorithm unchanged")
        try reopened.uninstall(id: package.manifest.id)
        let removed = try PluginStore(root: root)
        try expect(removed.list().isEmpty, "uninstall survives reopening")
        let nativeBytes = Data("native fixture; never executed".utf8)
        let native = PluginPackage(manifest: manifest(id: "org.example.native", runtime: .trustedExecutable),
                                   executable: nativeBytes, sha256: PluginPackage.digest(of: nativeBytes))
        let nativeStore = try PluginStore(root: fixtures.appendingPathComponent(UUID().uuidString))
        try rejects("native installation must never imply full trust") { _ = try nativeStore.install(native) }
        try rejects("approval for another native payload is insufficient") {
            _ = try nativeStore.install(native, approvedNativeDigest: String(repeating: "0", count: 64))
        }
        let quarantine = Data("0083;5f000001;CrossDiff core checks;".utf8)
        let nativeInstall = try nativeStore.install(native, approvedNativeDigest: native.sha256, sourceQuarantine: quarantine)
        try expect(nativeInstall.approvedNativeDigest == native.sha256, "approval is bound to the installed digest")
        guard let executableURL = try nativeStore.executableURL(id: native.manifest.id) else { throw Failure(description: "native payload must be extracted") }
        try expect(FileManager.default.isExecutableFile(atPath: executableURL.path), "native payload receives executable permissions")
        var quarantineBytes = [UInt8](repeating: 0, count: 4096)
        let quarantineCount = getxattr(executableURL.path, "com.apple.quarantine", &quarantineBytes, quarantineBytes.count, 0, XATTR_NOFOLLOW)
        try expect(quarantineCount == quarantine.count && Data(quarantineBytes.prefix(max(0, quarantineCount))) == quarantine,
                   "native extraction preserves the source quarantine instead of clearing it")
        let nativeV2Bytes = Data("another native fixture; never executed".utf8)
        let nativeV2 = PluginPackage(manifest: manifest(id: native.manifest.id, version: "1.1.0", runtime: .trustedExecutable),
                                     executable: nativeV2Bytes, sha256: PluginPackage.digest(of: nativeV2Bytes))
        try rejects("native updates cannot reuse approval for different bytes") {
            _ = try nativeStore.install(nativeV2, approvedNativeDigest: native.sha256)
        }
        let retainedNative = try nativeStore.package(id: native.manifest.id)
        try expect(retainedNative == native, "failed native approval leaves the active code unchanged")
        _ = try nativeStore.install(nativeV2, approvedNativeDigest: nativeV2.sha256)
        let nativeRollback = try nativeStore.rollback(id: native.manifest.id)
        try expect(nativeRollback.approvedNativeDigest == native.sha256, "rollback restores approval for the old digest only")
        let restoredNativeURL = try nativeStore.executableURL(id: native.manifest.id)
        try expect(restoredNativeURL == executableURL, "native rollback uses the immutable prior payload")
        try Data("tampered".utf8).write(to: executableURL, options: .atomic)
        try rejects("changed extracted native code is never returned for execution") { _ = try nativeStore.executableURL(id: native.manifest.id) }
        try nativeStore.setEnabled(false, for: native.manifest.id)
        try rejects("tampered native installation cannot be enabled again") {
            try nativeStore.setEnabled(true, for: native.manifest.id)
        }
        try expect(nativeStore.list().first?.isEnabled == false, "failed native validation preserves disabled state")
        let newlineID = packageJSON.replacingOccurrences(of: "org.example.lines", with: "org.example.lines\\n")
        try rejects("identifiers cannot hide a trailing newline") { _ = try PluginPackage.decode(data: Data(newlineID.utf8)) }
        let stableRoot = fixtures.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stable = try PluginStore(root: stableRoot)
        _ = try stable.install(package)
        guard chmod(stableRoot.path, 0o500) == 0 else { throw Failure(description: "cannot create read-only fixture") }
        defer { chmod(stableRoot.path, 0o700) }
        try rejects("failed metadata write must abort a new version") { _ = try stable.install(upgrade) }
        try rejects("failed disable must retain enabled state") { try stable.setEnabled(false, for: package.manifest.id) }
        try rejects("failed uninstall must retain the current installation") { try stable.uninstall(id: package.manifest.id) }
        try expect(stable.list().first?.activeVersion == "1.0.0" && stable.list().first?.isEnabled == true,
                   "memory keeps the last committed active state after write failures")
        guard chmod(stableRoot.path, 0o700) == 0 else { throw Failure(description: "cannot restore fixture permissions") }
        let afterFailure = try PluginStore(root: stableRoot)
        let stablePackage = try afterFailure.package(id: package.manifest.id)
        try expect(stablePackage == package && afterFailure.list().first?.isEnabled == true,
                   "failed writes preserve the last committed state across reopening")
        _ = try stable.install(upgrade)
        try rejects("a stale store instance cannot overwrite a newer registry") {
            try afterFailure.setEnabled(false, for: package.manifest.id)
        }
        let collisionStore = try PluginStore(root: fixtures.appendingPathComponent(UUID().uuidString), reservedBundledIDs: [package.manifest.id])
        try rejects("caller-reserved bundled IDs cannot be replaced externally") { _ = try collisionStore.install(package) }
        try expect(collisionStore.list().isEmpty, "reserved ID failure leaves no registration")
        let normalStore = try PluginStore(root: fixtures.appendingPathComponent(UUID().uuidString))
        let unreserved = PluginPackage(manifest: manifest(id: "org.crossdiff.not-reserved"), script: "abc", sha256: package.sha256)
        _ = try normalStore.install(unreserved)
        try expect(normalStore.list().first?.id == unreserved.manifest.id, "IDs are reserved only by the caller's supplied list")
        let localPackage = fixtures.appendingPathComponent(UUID().uuidString + ".crossdiffplugin")
        try package.encoded().write(to: localPackage)
        let linkedPackage = fixtures.appendingPathComponent(UUID().uuidString + ".crossdiffplugin")
        try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: localPackage)
        try rejects("package loading refuses a symbolic link") { _ = try PluginPackage.load(from: linkedPackage) }
        try rejects("package loading refuses a directory") { _ = try PluginPackage.load(from: fixtures) }
        try rejects("oversized encoded input is rejected before decoding") {
            _ = try PluginPackage.decode(data: Data(repeating: 32, count: PluginPackage.maximumPackageBytes + 1))
        }
        let mixed = PluginPackage(manifest: manifest(), script: "abc", executable: Data([1]), sha256: package.sha256)
        try rejects("mixed script and executable payloads are not valid") { try mixed.validate() }
        let threeWay = PluginComparisonRequest(runID: "merge", mode: .threeWayMerge,
            inputs: [.init(id: "base", role: .base, name: "Base", content: .null),
                     .init(id: "ours", role: .ours, name: "Ours", content: .null),
                     .init(id: "theirs", role: .theirs, name: "Theirs", content: .null)])
        try threeWay.validate(for: manifest(modes: [.threeWayMerge]))
        try rejects("pairwise-only plugins cannot receive three-way inputs") { try threeWay.validate(for: manifest()) }
        let peers = PluginComparisonRequest(runID: "peers", mode: .multiSubject,
            inputs: (0..<3).map { .init(id: "peer-\($0)", role: .peer, name: "Peer", content: .null) })
        try peers.validate(for: manifest(modes: [.multiSubject]))
        let wrongRoles = PluginComparisonRequest(runID: "wrong", mode: .threeWayMerge, inputs: peers.inputs)
        try rejects("three peers are not silently treated as a three-way merge") {
            try wrongRoles.validate(for: manifest(modes: [.threeWayMerge]))
        }
        print("PASS: \(count) plugin core checks")
    }
}
