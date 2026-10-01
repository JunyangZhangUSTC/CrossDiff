import Foundation
import CrossDiffCore

@MainActor final class NativeMenuController {
    static let shared = NativeMenuController()
    func showPlugins(_ sender: Any?) { }
}
private struct Failure: Error { let description: String }
private var count = 0
private func check(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
    guard try value() else { throw Failure(description: description) }
    count += 1; print("PASS: " + description)
}
private func rejects(_ description: String, _ body: () throws -> Void) throws {
    do { try body(); throw Failure(description: description) }
    catch let failure as Failure { throw failure }
    catch { count += 1; print("PASS: " + description) }
}
private final class CatalogTransport: URLProtocol {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var wait = false
    private static var hits = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return hits }
    static func respond(_ data: Data, waiting: Bool = false) {
        lock.lock(); payload = data; wait = waiting; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.hits += 1; let data = Self.payload; let waiting = Self.wait; Self.lock.unlock()
        if waiting { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@main private enum OfficialPluginChecks {
    static func package(id: String = "org.crossdiff.pdf", version: String = "0.1.0", runtime: PluginRuntimeProfile = .restrictedJavaScript) -> PluginPackage {
        let script = "function compare(request) { return {}; }"
        let payload = runtime == .restrictedJavaScript ? Data(script.utf8) : Data([1, 2, 3])
        return PluginPackage(manifest: PluginManifest(id: id, version: version,
            name: PluginLocalizedText(zhHans: "PDF 文档对比", en: "PDF Comparison"),
            summary: PluginLocalizedText(zhHans: "原生页面与文字差异", en: "Native pages and text differences"),
            runtime: runtime, inputKind: .pdf, fileExtensions: ["pdf"], resultView: "documentPages"),
            script: runtime == .restrictedJavaScript ? script : nil,
            executable: runtime == .trustedExecutable ? payload : nil, sha256: PluginPackage.digest(of: payload))
    }
    static func entry(_ bytes: Data, id: String = "org.crossdiff.pdf", version: String = "0.1.0") -> [String: Any] {
        let asset = "CrossDiff-Plugin-PDF-0.1.0.crossdiffplugin"
        return ["id": id, "version": version, "name": ["zhHans": "PDF 文档对比", "en": "PDF Comparison"],
                "summary": ["zhHans": "原生页面与文字差异", "en": "Native pages and text differences"],
                "asset": asset, "url": "https://github.com/JunyangZhangUSTC/CrossDiff/releases/download/v0.8.0/" + asset,
                "sha256": PluginPackage.digest(of: bytes), "size": bytes.count]
    }
    static func data(_ entries: [[String: Any]], tag: String = "v0.8.0", format: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": format, "releaseTag": tag, "plugins": entries], options: [.sortedKeys])
    }
    @MainActor static func wait(_ manager: PluginManager) async throws {
        let deadline = Date().addingTimeInterval(4)
        while manager.downloading && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        try check(!manager.downloading, "download finishes or cancels promptly")
    }
    @MainActor static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bytes = try package().encoded(), record = entry(bytes)
            let catalogBytes = try data([record])
            let catalog = try OfficialPluginCatalog.decode(catalogBytes), official = catalog.plugins[0]
            try check(catalog.releaseTag == "v0.8.0" && official.id == "org.crossdiff.pdf", "valid bundled catalog preserves release and plugin identity")
            try check(try official.verifiedPackage(from: bytes) == package(), "exact whole-package checksum verifies before installation")
            try rejects("duplicate identifiers rejected") { _ = try OfficialPluginCatalog.decode(data([record, record])) }
            for (key, value) in [
                ("url", "https://github.com/Other/Repo/releases/download/v0.8.0/plugin.crossdiffplugin"),
                ("url", (record["url"] as! String) + "?token=secret"),
                ("url", (record["url"] as! String).replacingOccurrences(of: "v0.8.0", with: "v0.8.1")),
                ("url", (record["url"] as! String).replacingOccurrences(of: "https://", with: "http://")),
                ("asset", "../PDF.crossdiffplugin"), ("id", "thirdparty.plugin"),
                ("sha256", String(repeating: "A", count: 64)), ("version", "latest")
            ] {
                var invalid = record; invalid[key] = value
                try rejects("catalog rejects invalid " + key + ": " + value) { _ = try OfficialPluginCatalog.decode(data([invalid])) }
            }
            for size in [0, -1, PluginPackage.maximumPackageBytes + 1] {
                var invalid = record; invalid["size"] = size
                try rejects("catalog bounds package size \(size)") { _ = try OfficialPluginCatalog.decode(data([invalid])) }
            }
            var extra = record; extra["trustNative"] = true
            try rejects("unknown schema fields cannot grant authority") { _ = try OfficialPluginCatalog.decode(data([extra])) }
            try rejects("unsupported catalog version rejected") { _ = try OfficialPluginCatalog.decode(data([record], format: 2)) }
            try rejects("release traversal rejected") { _ = try OfficialPluginCatalog.decode(data([record], tag: "../tag")) }
            try rejects("corrupt bytes rejected before package parsing") { _ = try official.verifiedPackage(from: Data(repeating: 1, count: bytes.count)) }
            try rejects("truncated bytes rejected") { _ = try official.verifiedPackage(from: bytes.dropLast()) }
            for altered in [package(id: "org.crossdiff.other"), package(version: "0.2.0"), package(runtime: .trustedExecutable)] {
                let alteredBytes = try altered.encoded()
                let matchingDigest = try OfficialPluginCatalog.decode(data([entry(alteredBytes)])).plugins[0]
                try rejects("identity, version or native runtime mismatch rejected despite matching digest") { _ = try matchingDigest.verifiedPackage(from: alteredBytes) }
            }
            var incompatible = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            var manifest = incompatible["manifest"] as! [String: Any]
            manifest["minHostProtocol"] = 99; manifest["maxHostProtocol"] = 100; incompatible["manifest"] = manifest
            let incompatibleBytes = try JSONSerialization.data(withJSONObject: incompatible)
            let incompatibleEntry = try OfficialPluginCatalog.decode(data([entry(incompatibleBytes)])).plugins[0]
            try rejects("host protocol mismatch rejected despite matching digest") { _ = try incompatibleEntry.verifiedPackage(from: incompatibleBytes) }

            let catalogURL = root.appendingPathComponent("OfficialPlugins.json")
            try catalogBytes.write(to: catalogURL)
            let bundles = root.appendingPathComponent("bundles")
            try FileManager.default.createDirectory(at: bundles, withIntermediateDirectories: true)
            let manager = PluginManager(directory: root.appendingPathComponent("base"), bundledDirectory: bundles, catalogURL: catalogURL)
            try check(manager.officialPlugins.count == 1 && CatalogTransport.requests == 0, "launch and catalog discovery do not request the network")
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogTransport.self]
            CatalogTransport.respond(bytes)
            manager.installOfficial(official, configuration: config)
            try await wait(manager)
            try check(manager.plugin(id: official.id)?.enabled == true && manager.pendingPackage == nil, "user click verifies installs and enables without an extra preview")
            try check(manager.plugin(id: official.id)?.installation?.approvedNativeDigest == nil, "official installation grants no native trust")
            let requests = CatalogTransport.requests
            manager.installOfficial(official, configuration: config)
            try check(!manager.downloading && CatalogTransport.requests == requests, "installed identity cannot trigger automatic replacement or duplicate download")

            manager.pendingPackage = package(version: "0.0.9"); manager.installPending(trustNative: false)
            manager.pendingPackage = package(); manager.installPending(trustNative: false)
            manager.setEnabled(false, id: official.id)
            let bundleURL = bundles.appendingPathComponent("PDF.crossdiffplugin")
            try bytes.write(to: bundleURL)
            let full = PluginManager(directory: root.appendingPathComponent("base"), bundledDirectory: bundles, catalogURL: catalogURL)
            try check(full.storageError == nil && full.plugins.count == 1 && full.plugin(id: official.id)?.bundled == true, "Base to Full prefers bundled PDF without corrupting or duplicating registry")
            full.installOfficial(official, configuration: config)
            try check(!full.downloading, "bundled plugin is never overwritten by catalog installation")
            try FileManager.default.removeItem(at: bundleURL)
            let baseAgain = PluginManager(directory: root.appendingPathComponent("base"), bundledDirectory: bundles, catalogURL: catalogURL)
            try check(baseAgain.plugin(id: official.id)?.bundled == false && baseAgain.plugin(id: official.id)?.enabled == false && baseAgain.plugin(id: official.id)?.installation?.previousVersion == "0.0.9", "Full back to Base restores preserved PDF, disabled state and rollback history")

            baseAgain.rollback(official.id)
            try check(baseAgain.plugin(id: official.id)?.package.manifest.version == "0.0.9", "rollback still works after changing editions")
            let waiting = PluginManager(directory: root.appendingPathComponent("waiting"), bundledDirectory: bundles, catalogURL: catalogURL)
            CatalogTransport.respond(bytes, waiting: true)
            waiting.installOfficial(official, configuration: config)
            try await Task.sleep(nanoseconds: 30_000_000)
            waiting.cancelDownload(); try await wait(waiting)
            try check(waiting.plugins.isEmpty && waiting.pendingPackage == nil, "cancelled official download leaves installation state untouched")
            CatalogTransport.respond(Data(repeating: 1, count: bytes.count))
            waiting.installOfficial(official, configuration: config); try await wait(waiting)
            try check(waiting.plugins.isEmpty && waiting.message != nil, "tampered download reports error and installs nothing")
            let forged = try OfficialPluginCatalog.decode(data([entry(bytes, id: "org.crossdiff.forged")])).plugins[0]
            let beforeForgery = CatalogTransport.requests
            waiting.installOfficial(forged, configuration: config)
            try check(!waiting.downloading && CatalogTransport.requests == beforeForgery, "entry not in app catalog cannot start network or installation")
            CatalogTransport.respond(bytes)
            waiting.download(from: official.url.absoluteString, configuration: config); try await wait(waiting)
            try check(waiting.plugins.isEmpty && waiting.pendingPackage?.manifest.id == official.id, "arbitrary HTTPS download retains explicit review even for official-looking address")
            waiting.cancelInstall()
            try Data("bad catalog".utf8).write(to: catalogURL)
            let corrupt = PluginManager(directory: root.appendingPathComponent("corrupt"), bundledDirectory: bundles, catalogURL: catalogURL)
            try check(corrupt.officialPlugins.isEmpty && corrupt.officialCatalogError != nil && corrupt.storageError == nil, "invalid catalog disables official downloads without damaging local installation")
            let noCatalog = PluginManager(directory: root.appendingPathComponent("missing"), bundledDirectory: bundles)
            try check(noCatalog.officialPlugins.isEmpty && noCatalog.officialCatalogError == nil, "development build without catalog remains usable")
            print("PASS: \(count) official plugin catalog and installation checks (offline transport)")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
