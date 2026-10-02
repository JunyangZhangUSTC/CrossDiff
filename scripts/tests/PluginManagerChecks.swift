import Foundation
import CrossDiffCore

// This check exercises manager state without creating a window. Menu presentation
// is the UI boundary; packages, registry and validation are the production code.
@MainActor
final class NativeMenuController {
    static let shared = NativeMenuController()
    func showPlugins(_ sender: Any?) { }
}
private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

private final class WaitingDownloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { }
    override func stopLoading() { }
}

@main
private enum PluginManagerChecks {
    static func package(_ id: String, version: String = "1.0.0") -> PluginPackage {
        let script = "function compare(request) { return {}; }"
        return PluginPackage(manifest: PluginManifest(id: id, version: version,
            name: PluginLocalizedText(zhHans: "测试", en: "Fixture"), summary: PluginLocalizedText(zhHans: "测试比较", en: "Fixture comparison"),
            runtime: .restrictedJavaScript, inputKind: .text, fileExtensions: ["fixture"], resultView: "table"),
            script: script, sha256: PluginPackage.digest(of: Data(script.utf8)))
    }
    @MainActor static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundles = root.appendingPathComponent("bundled")
            try FileManager.default.createDirectory(at: bundles, withIntermediateDirectories: true)
            try package("dev.crossdiff.bundled-fixture").encoded().write(to: bundles.appendingPathComponent("fixture.crossdiffplugin"))
            let data = root.appendingPathComponent("data")
            let store = try PluginStore(root: data.appendingPathComponent("Plugins"))
            try store.install(package("dev.crossdiff.healthy-fixture"))
            try store.install(package("dev.crossdiff.broken-fixture"))
            let broken = data.appendingPathComponent("Plugins/versions/dev.crossdiff.broken-fixture/1.0.0/package.crossdiffplugin")
            try Data("corrupt package".utf8).write(to: broken)
            let manager = PluginManager(directory: data, bundledDirectory: bundles)
            try expect(Set(manager.plugins.map { $0.id }) == ["dev.crossdiff.bundled-fixture", "dev.crossdiff.healthy-fixture"],
                       "A corrupt installed package must not hide bundled or healthy plugins")
            try expect(manager.failedPlugins.count == 1 && manager.failedPlugins.first?.id == "dev.crossdiff.broken-fixture",
                       "The damaged installed plugin must remain visible with its error")
            try expect(manager.failedPlugins.first?.error.isEmpty == false, "Failed plugins need an explanation")
            manager.uninstall("dev.crossdiff.broken-fixture")
            try expect(manager.failedPlugins.isEmpty && manager.plugins.count == 2, "User can uninstall a corrupt package without affecting healthy plugins")
            print("PASS: corrupt installed package stays visible and can be uninstalled without hiding healthy plugins")
            let external = root.appendingPathComponent("external.crossdiffplugin")
            try package("dev.crossdiff.external-fixture").encoded().write(to: external)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WaitingDownloadProtocol.self]
            manager.download(from: "https://plugin.invalid/waiting", configuration: configuration)
            manager.inspect(external)
            try expect(manager.pendingPackage == nil, "A drop during download must not open a competing installation preview")
            manager.cancelDownload()
            let deadline = Date().addingTimeInterval(1)
            while manager.downloading, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            try expect(!manager.downloading, "Download cancellation must release installation state")
            manager.inspect(external)
            try expect(manager.pendingPackage?.manifest.id == "dev.crossdiff.external-fixture", "Installation should work again after cancelling download")
            manager.cancelInstall()
            print("PASS: download and local drop cannot compete for preview; cancellation permits the next installation")
            try Data("broken registry".utf8).write(to: data.appendingPathComponent("Plugins/state.json"))
            let unavailableStore = PluginManager(directory: data, bundledDirectory: bundles)
            try expect(unavailableStore.plugins.map { $0.id } == ["dev.crossdiff.bundled-fixture"],
                       "An unavailable external registry must not hide bundled plugins")
            try expect(unavailableStore.storageError?.isEmpty == false, "Unavailable storage needs a persistent explanation")
            unavailableStore.removeBundled("dev.crossdiff.bundled-fixture")
            try expect(unavailableStore.plugins.isEmpty && unavailableStore.removedBundledPlugins.count == 1,
                       "Bundled removal does not require a healthy external registry")
            unavailableStore.restoreBundled("dev.crossdiff.bundled-fixture")
            try expect(unavailableStore.plugins.first?.enabled == true,
                       "Bundled restoration remains available offline with a corrupt external registry")
            print("PASS: bundled plugins remain available with an explanation when the external registry is corrupt")
            try checkBundledRemoval(root: root)
            try checkHiddenRepairCleanup(root: root)
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func checkBundledRemoval(root: URL) throws {
        let id = "dev.crossdiff.removable-fixture"
        let bundles = root.appendingPathComponent("removal-bundles")
        let emptyBundles = root.appendingPathComponent("base-bundles")
        let data = root.appendingPathComponent("removal-data")
        try FileManager.default.createDirectory(at: bundles, withIntermediateDirectories: true)
        let bundleURL = bundles.appendingPathComponent("removable.crossdiffplugin")
        let bundledBytes = try package(id, version: "2.0.0").encoded()
        try bundledBytes.write(to: bundleURL)
        let externalRoot = data.appendingPathComponent("Plugins")
        let external = try PluginStore(root: externalRoot)
        try external.install(package(id))
        try external.install(package(id, version: "1.1.0"))
        try external.setEnabled(false, for: id)
        let preferencesURL = data.appendingPathComponent("plugin-preferences.json")
        try JSONEncoder().encode(Set([id])).write(to: preferencesURL)
        let manager = PluginManager(directory: data, bundledDirectory: bundles)
        try expect(manager.plugin(id: id)?.enabled == false && manager.removedBundledPlugins.isEmpty,
                   "Legacy disabled-ID preferences remain disabled without implying removal")
        manager.removeBundled(id)
        try expect(manager.plugin(id: id) == nil && manager.failedPlugins.isEmpty && manager.removedBundledPlugins.first?.id == id,
                   "Bundled removal hides the plugin and its external shadow registration")
        let savedPreferences = try Data(contentsOf: preferencesURL)
        let migrated = try JSONSerialization.jsonObject(with: savedPreferences) as? [String: Any]
        try expect((migrated?["removedIDs"] as? [String]) == [id] && (migrated?["disabledBundled"] as? [String]) == [id],
                   "First preference mutation migrates the legacy array without losing disabled state")
        manager.removeBundled(id)
        try expect(tryData(preferencesURL) == savedPreferences, "Repeated removal does not rewrite preferences")
        manager.setEnabled(true, id: id)
        try expect(manager.plugin(id: id) == nil && manager.message != nil, "Enable cannot bypass an explicit removal")
        do { _ = try manager.execution(for: id); throw CheckFailure(description: "Removed plugin must not execute") }
        catch is PluginAppError { }
        try expect(tryData(bundleURL) == bundledBytes, "Removing a bundled plugin never modifies its signed bundle bytes")
        let preserved = try PluginStore(root: externalRoot).list().first
        try expect(preserved?.activeVersion == "1.1.0" && preserved?.previousVersion == "1.0.0" && preserved?.isEnabled == false,
                   "Removal preserves external versions, rollback history and disabled state")
        let reopened = PluginManager(directory: data, bundledDirectory: bundles)
        let base = PluginManager(directory: data, bundledDirectory: emptyBundles)
        try expect(reopened.plugin(id: id) == nil && reopened.removedBundledPlugins.count == 1,
                   "Bundled removal survives restarting Full")
        try expect(base.plugin(id: id) == nil && base.failedPlugins.isEmpty && base.removedBundledPlugins.isEmpty,
                   "Full-to-Base transition cannot revive an old external installation")
        let upgradedBytes = try package(id, version: "3.0.0").encoded()
        try upgradedBytes.write(to: bundleURL)
        let upgraded = PluginManager(directory: data, bundledDirectory: bundles)
        try expect(upgraded.plugin(id: id) == nil && upgraded.removedBundledPlugins.first?.package.manifest.version == "3.0.0",
                   "An app update does not restore a removed identity")
        upgraded.restoreBundled(id)
        try expect(upgraded.plugin(id: id)?.enabled == true && upgraded.removedBundledPlugins.isEmpty,
                   "Explicit offline restore enables the current bundled version")
        let restoredPreferences = try Data(contentsOf: preferencesURL)
        upgraded.restoreBundled(id)
        try expect(tryData(preferencesURL) == restoredPreferences, "Repeated restore is harmless and does not rewrite preferences")
        let restored = PluginManager(directory: data, bundledDirectory: bundles)
        try expect(restored.plugin(id: id)?.enabled == true, "Restored enabled state survives restarting")
        restored.removeBundled("dev.crossdiff.unknown")
        try expect(restored.message != nil && restored.plugin(id: id)?.enabled == true,
                   "Unknown removal cannot alter existing plugins")

        guard chmod(data.path, 0o500) == 0 else { throw CheckFailure(description: "Cannot make preferences directory read-only") }
        defer { chmod(data.path, 0o700) }
        restored.message = nil; restored.removeBundled(id)
        try expect(restored.plugin(id: id)?.enabled == true && restored.removedBundledPlugins.isEmpty && restored.message != nil,
                   "A failed preference write does not publish a removal")
        guard chmod(data.path, 0o700) == 0 else { throw CheckFailure(description: "Cannot restore preferences permissions") }
        restored.removeBundled(id)
        guard chmod(data.path, 0o500) == 0 else { throw CheckFailure(description: "Cannot make preferences directory read-only") }
        restored.message = nil; restored.restoreBundled(id)
        try expect(restored.plugin(id: id) == nil && restored.removedBundledPlugins.count == 1 && restored.message != nil,
                   "A failed restore remains hidden in memory")
        let failedReopen = PluginManager(directory: data, bundledDirectory: bundles)
        try expect(failedReopen.plugin(id: id) == nil, "Failed restore remains hidden after restart")
        let reinstall = PluginManager(directory: data, bundledDirectory: emptyBundles)
        reinstall.pendingPackage = package(id, version: "1.1.0")
        reinstall.installPending(trustNative: false)
        try expect(reinstall.plugin(id: id) == nil && reinstall.pendingPackage != nil && reinstall.message != nil,
                   "Reinstall cannot unhide an identity when saving activation fails; review remains retryable")
        try expect(PluginManager(directory: data, bundledDirectory: emptyBundles).plugin(id: id) == nil,
                   "Failed reinstall activation remains hidden after restart")
        guard chmod(data.path, 0o700) == 0 else { throw CheckFailure(description: "Cannot restore preferences permissions") }
        reinstall.installPending(trustNative: false)
        try expect(reinstall.plugin(id: id)?.enabled == true && reinstall.pendingPackage == nil,
                   "Retrying explicit local reinstall restores and enables the existing package")
        let fullAgain = PluginManager(directory: data, bundledDirectory: bundles)
        try expect(fullAgain.plugin(id: id)?.enabled == true && fullAgain.removedBundledPlugins.isEmpty,
                   "Explicit reinstall clears removal and disabled preferences for a subsequent Full launch")
        fullAgain.removeBundled(id)
        let externalPackageURL = externalRoot.appendingPathComponent("versions/\(id)/1.1.0/package.crossdiffplugin")
        try Data("broken external package".utf8).write(to: externalPackageURL)
        let hiddenBroken = PluginManager(directory: data, bundledDirectory: emptyBundles)
        try expect(hiddenBroken.plugins.isEmpty && hiddenBroken.failedPlugins.isEmpty,
                   "A hidden external shadow cannot reappear as a failed-plugin row")
        let badRegistration = try Data(contentsOf: externalRoot.appendingPathComponent("state.json"))
        let validReplacement = package(id, version: "1.1.0")
        hiddenBroken.pendingPackage = PluginPackage(manifest: validReplacement.manifest,
            script: validReplacement.script, sha256: String(repeating: "0", count: 64))
        hiddenBroken.installPending(trustNative: false)
        try expect(tryData(externalRoot.appendingPathComponent("state.json")) == badRegistration
                   && tryData(externalPackageURL) == Data("broken external package".utf8),
                   "An invalid replacement cannot clean up a hidden broken installation")
        hiddenBroken.pendingPackage = validReplacement
        hiddenBroken.installPending(trustNative: false)
        try expect(hiddenBroken.plugin(id: id)?.enabled == true && hiddenBroken.pendingPackage == nil,
                   "A verified local reinstall repairs a hidden damaged external package after switching to Base")
        let repairedPackage = try PluginStore(root: externalRoot).package(id: id)
        try expect(repairedPackage == validReplacement,
                   "Repair installs the exact validated replacement package")
        let removeRepaired = PluginManager(directory: data, bundledDirectory: bundles)
        removeRepaired.removeBundled(id)
        try Data("broken external package".utf8).write(to: externalPackageURL)
        let offlineRestore = PluginManager(directory: data, bundledDirectory: bundles)
        offlineRestore.restoreBundled(id)
        try expect(offlineRestore.plugin(id: id)?.enabled == true && offlineRestore.failedPlugins.isEmpty,
                   "Offline bundled restore does not read a damaged external shadow")
        try expect(tryData(bundleURL) == upgradedBytes, "Removal and restoration leave the current app package byte-for-byte unchanged")
        print("PASS: bundled removal, offline restoration, legacy migration, edition transitions and write-failure recovery")
    }
    @MainActor static func checkHiddenRepairCleanup(root: URL) throws {
        let id = "dev.crossdiff.repair-fixture"
        let data = root.appendingPathComponent("repair-data")
        let storeRoot = data.appendingPathComponent("Plugins")
        let store = try PluginStore(root: storeRoot)
        let replacement = package(id)
        try store.install(replacement)
        do { try store.pruneUnregisteredFiles(id: id); throw CheckFailure(description: "Cleanup must not delete a registered plugin") }
        catch is PluginValidationError { }
        do { try store.pruneUnregisteredFiles(id: "../outside"); throw CheckFailure(description: "Cleanup must not accept a traversal ID") }
        catch is PluginValidationError { }
        let sentinel = root.appendingPathComponent("repair-sentinel")
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
        let sentinelFile = sentinel.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinelFile)
        let linkID = "dev.crossdiff.linked-residue"
        try FileManager.default.createSymbolicLink(at: storeRoot.appendingPathComponent("versions/" + linkID), withDestinationURL: sentinel)
        do { try store.pruneUnregisteredFiles(id: linkID); throw CheckFailure(description: "Cleanup must not follow a directory symlink") }
        catch is PluginValidationError { }
        try expect(tryData(sentinelFile) == Data("keep".utf8), "Unsafe cleanup attempts preserve unrelated files")
        let bundles = root.appendingPathComponent("repair-bundles")
        try FileManager.default.createDirectory(at: bundles, withIntermediateDirectories: true)
        try replacement.encoded().write(to: bundles.appendingPathComponent("fixture.crossdiffplugin"))
        let full = PluginManager(directory: data, bundledDirectory: bundles)
        full.removeBundled(id)
        let packageURL = storeRoot.appendingPathComponent("versions/\(id)/1.0.0/package.crossdiffplugin")
        try Data("broken".utf8).write(to: packageURL)
        let emptyBundles = root.appendingPathComponent("repair-empty-bundles")
        let base = PluginManager(directory: data, bundledDirectory: emptyBundles)
        let nativeBytes = Data("unsigned fixture, never executed".utf8)
        let native = PluginPackage(manifest: PluginManifest(id: id, version: "1.0.0",
            name: replacement.manifest.name, summary: replacement.manifest.summary,
            runtime: .trustedExecutable, inputKind: .text, fileExtensions: ["fixture"], resultView: "table"),
            executable: nativeBytes, sha256: PluginPackage.digest(of: nativeBytes))
        base.pendingPackage = native; base.installPending(trustNative: false)
        try expect(tryData(packageURL) == Data("broken".utf8)
                   && (try? PluginStore(root: storeRoot).list().count) == 1,
                   "An unapproved native replacement cannot remove the hidden old installation")
        base.pendingPackage = replacement
        let versions = storeRoot.appendingPathComponent("versions")
        guard chmod(versions.path, 0o500) == 0 else { throw CheckFailure(description: "Cannot block old plugin cleanup") }
        defer { chmod(versions.path, 0o700) }
        base.installPending(trustNative: false)
        try expect(base.plugin(id: id) == nil && base.pendingPackage != nil && base.message != nil,
                   "Failed old-file cleanup keeps the plugin hidden and the new installation retryable")
        let unregistered = try PluginStore(root: storeRoot)
        try expect(unregistered.list().isEmpty, "Cleanup failure never revives a damaged registered installation")
        guard chmod(versions.path, 0o700) == 0 else { throw CheckFailure(description: "Cannot restore plugin cleanup permissions") }
        let restarted = PluginManager(directory: data, bundledDirectory: emptyBundles)
        try expect(restarted.plugin(id: id) == nil, "Interrupted repair remains removed across restart")
        restarted.pendingPackage = replacement; restarted.installPending(trustNative: false)
        try expect(restarted.plugin(id: id)?.enabled == true && restarted.pendingPackage == nil,
                   "Explicit reinstall safely retries unregistered residue cleanup after permissions are fixed")
        try expect(tryData(sentinelFile) == Data("keep".utf8), "Successful repair leaves unrelated comparison files unchanged")
        print("PASS: hidden installation repair, invalid-input protection and cleanup-failure retry")
    }
    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
