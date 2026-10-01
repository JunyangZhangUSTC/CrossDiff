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
    static func package(_ id: String) -> PluginPackage {
        let script = "function compare(request) { return {}; }"
        return PluginPackage(manifest: PluginManifest(id: id, version: "1.0.0",
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
            print("PASS: bundled plugins remain available with an explanation when the external registry is corrupt")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
