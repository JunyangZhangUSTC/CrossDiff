import AppKit
import Foundation
import CrossDiffCore

extension Notification.Name {
    static let crossDiffPluginsChanged = Notification.Name("CrossDiff.pluginsChanged")
}

struct PluginAppError: LocalizedError {
    let zh: String
    let en: String
    var errorDescription: String? { L(zh, en) }
}

struct AvailablePlugin: Identifiable {
    let package: PluginPackage
    let installation: PluginInstallation?
    let bundled: Bool
    let enabled: Bool
    var id: String { package.manifest.id }
}

struct FailedPlugin: Identifiable {
    let installation: PluginInstallation
    let error: String
    var id: String { installation.id }
}

/// A run captures a validated package version. Changing the installed version
/// invalidates views through the manager's revision and cancels their old tasks.
struct PluginExecution: Sendable {
    let package: PluginPackage
    let helperURL: URL
    let executableURL: URL?
    let approvedDigest: String?

    func compare(_ inputs: [PluginInput]) async throws -> PluginComparisonResult {
        let request = PluginComparisonRequest(protocolVersion: 1, runID: UUID().uuidString,
            mode: .pairwise, inputs: inputs, options: [:])
        return try await PluginRunner.run(package: package, request: request, helperURL: helperURL,
            nativeExecutableURL: executableURL, approvedNativeDigest: approvedDigest)
    }
}

@MainActor
final class PluginManager: ObservableObject {
    static let shared = PluginManager()
    @Published private(set) var plugins: [AvailablePlugin] = []
    @Published private(set) var failedPlugins: [FailedPlugin] = []
    @Published private(set) var storageError: String?
    @Published private(set) var revision = UUID()
    @Published var pendingPackage: PluginPackage?
    @Published var message: String?
    @Published private(set) var downloading = false
    @Published private(set) var officialInstallingID: String?
    private(set) var officialCatalog: OfficialPluginCatalog?
    private var officialCatalogFailure: Error?
    var officialPlugins: [OfficialPlugin] { officialCatalog?.plugins ?? [] }
    var officialCatalogError: String? { officialCatalogFailure.map(localizedErrorDescription) }
    private var pendingQuarantine: Data?
    private var store: PluginStore?
    private var bundled: [PluginPackage] = []
    private var disabledBundled: Set<String> = []
    private let preferencesURL: URL
    private let inspectionDirectory: URL
    private var downloadTask: Task<Void, Never>?

    init(directory: URL? = nil, bundledDirectory: URL? = nil, catalogURL: URL? = nil) {
        let data = directory ?? ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CrossDiff")
        preferencesURL = data.appendingPathComponent("plugin-preferences.json")
        inspectionDirectory = data.appendingPathComponent("Plugins/inspections")
        if let catalog = catalogURL ?? Bundle.main.url(forResource: "OfficialPlugins", withExtension: "json") {
            do { officialCatalog = try OfficialPluginCatalog.load(from: catalog) }
            catch { officialCatalogFailure = error }
        }
        do {
            let resources = bundledDirectory ?? ProcessInfo.processInfo.environment["CROSSDIFF_BUNDLED_PLUGINS_DIR"].map { URL(fileURLWithPath: $0) }
                ?? Bundle.main.resourceURL?.appendingPathComponent("Plugins")
            if let resources, FileManager.default.fileExists(atPath: resources.path) {
                for url in try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "crossdiffplugin" {
                    let package = try PluginPackage.load(from: url)
                    guard package.manifest.runtime == .restrictedJavaScript,
                          !bundled.contains(where: { $0.manifest.id == package.manifest.id }) else {
                        throw PluginAppError(zh: "内置插件清单无效。", en: "Invalid bundled plugin inventory.")
                    }
                    bundled.append(package)
                }
            }
        } catch { message = localizedErrorDescription(error) }
        do {
            if FileManager.default.fileExists(atPath: preferencesURL.path) {
                disabledBundled = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: preferencesURL))
            }
        } catch { message = localizedErrorDescription(error) }
        do {
            store = try PluginStore(root: data.appendingPathComponent("Plugins"), reservedBundledIDs: Set(bundled.map { $0.manifest.id }))
        } catch {
            storageError = localizedErrorDescription(error)
            message = storageError
        }
        refresh()
    }

    var enabledPlugins: [AvailablePlugin] { plugins.filter { $0.enabled && $0.package.manifest.supportedModes.contains(.pairwise) } }
    func plugin(id: String?) -> AvailablePlugin? { plugins.first { $0.id == id } }
    func matching(_ url: URL) -> AvailablePlugin? {
        // Built-in text formats remain text by default. Users can explicitly
        // choose a structural plugin from Compare, without hijacking file open.
        let ext = url.pathExtension.lowercased()
        guard !["txt", "md", "markdown", "html", "htm", "json", "xml", "yaml", "yml"].contains(ext) else { return nil }
        return enabledPlugins.first { $0.package.manifest.fileExtensions.contains(ext) }
    }

    func execution(for id: String) throws -> PluginExecution {
        guard let entry = plugin(id: id), entry.enabled else {
            throw PluginAppError(zh: "此插件尚未安装或已停用。", en: "This plugin is missing or disabled.")
        }
        let package = entry.bundled ? entry.package : try storeRequired().package(id: id)
        try package.validate()
        let helper = ProcessInfo.processInfo.environment["CROSSDIFF_PLUGIN_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CrossDiffPluginHost")
        return PluginExecution(package: package, helperURL: helper,
            executableURL: entry.bundled ? nil : try storeRequired().executableURL(id: id),
            approvedDigest: entry.installation?.approvedNativeDigest)
    }

    func inspect(_ url: URL) {
        do {
            guard pendingPackage == nil, !downloading else {
                throw PluginAppError(zh: "请先完成或取消当前插件下载和安装。", en: "Finish or cancel the current plugin download and installation first.")
            }
            let package = try PluginPackage.load(from: url)
            try validateExternal(package)
            pendingQuarantine = try Self.quarantine(at: url)
            pendingPackage = package
            NativeMenuController.shared.showPlugins(nil)
        } catch { message = localizedErrorDescription(error); NativeMenuController.shared.showPlugins(nil) }
    }

    func cancelInstall() { pendingPackage = nil; pendingQuarantine = nil }

    func installPending(trustNative: Bool) {
        guard let package = pendingPackage else { return }
        do {
            try validateExternal(package)
            if package.manifest.runtime == .trustedExecutable && !trustNative {
                throw PluginAppError(zh: "完全信任插件需要单独授权。", en: "A full-trust plugin requires explicit authorization.")
            }
            if package.manifest.runtime == .trustedExecutable { try verifyNativePackage(package) }
            _ = try storeRequired().install(package,
                approvedNativeDigest: trustNative ? package.sha256 : nil, sourceQuarantine: pendingQuarantine)
            cancelInstall()
            refresh()
        } catch { message = localizedErrorDescription(error) }
    }

    func setEnabled(_ enabled: Bool, id: String) {
        perform {
            if bundled.contains(where: { $0.manifest.id == id }) {
                var updated = disabledBundled
                if enabled { updated.remove(id) } else { updated.insert(id) }
                try JSONEncoder().encode(updated).write(to: preferencesURL, options: .atomic)
                disabledBundled = updated
            } else { try storeRequired().setEnabled(enabled, for: id) }
        }
    }
    func uninstall(_ id: String) {
        perform {
            if try !storeRequired().uninstall(id: id) {
                message = L("插件已卸载，部分未启用的文件无法清理。", "The plugin was uninstalled, but some inactive files could not be removed.")
            }
        }
    }
    func rollback(_ id: String) { perform { try storeRequired().rollback(id: id) } }
    private func perform(_ action: () throws -> Void) {
        do { try action(); refresh() } catch { message = localizedErrorDescription(error) }
    }
    private func verifyNativePackage(_ package: PluginPackage) throws {
        // Installation runs no package code. Security assessment checks a private
        // staging copy before committing version or trust state.
        try FileManager.default.createDirectory(at: inspectionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try inspectionDirectory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw PluginValidationError.unsafeStore }
        let path = inspectionDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        guard let executable = package.executable else { throw PluginValidationError.invalidPayload }
        try executable.write(to: path, options: .withoutOverwriting)
        if let quarantine = pendingQuarantine {
            let status = quarantine.withUnsafeBytes { setxattr(path.path, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, XATTR_NOFOLLOW) }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path.path)
        try PluginRunner.verifyNativeExecutable(at: path, expectedDigest: package.sha256)
    }

    private func validateExternal(_ package: PluginPackage) throws {
        try package.validate()
        guard !bundled.contains(where: { $0.manifest.id == package.manifest.id }) else {
            throw PluginAppError(zh: "此标识属于内置插件，请通过更新 CrossDiff 升级。", en: "This identifier belongs to a bundled plugin. Update CrossDiff to upgrade it.")
        }
    }
    private func storeRequired() throws -> PluginStore {
        guard let store else { throw PluginAppError(zh: "插件存储不可用，请检查目录权限。", en: "Plugin storage is unavailable. Check directory permissions.") }
        return store
    }
    private func refresh() {
        var entries = bundled.map { AvailablePlugin(package: $0, installation: nil, bundled: true, enabled: !disabledBundled.contains($0.manifest.id)) }
        var failures: [FailedPlugin] = []
        if let store {
            for installation in store.list() {
                // Full gives bundled packages precedence. Preserve the external
                // registration and versions for a later switch back to Base.
                guard !bundled.contains(where: { $0.manifest.id == installation.id }) else { continue }
                do {
                    entries.append(AvailablePlugin(package: try store.package(id: installation.id), installation: installation, bundled: false, enabled: installation.isEnabled))
                } catch {
                    failures.append(FailedPlugin(installation: installation, error: localizedErrorDescription(error)))
                }
            }
        }
        plugins = entries.sorted { $0.id < $1.id }
        failedPlugins = failures
        revision = UUID()
        NotificationCenter.default.post(name: .crossDiffPluginsChanged, object: self)
    }

    func download(from address: String, configuration: URLSessionConfiguration = .ephemeral) {
        guard !downloading, pendingPackage == nil else { return }
        guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            message = L("请输入不包含账号密码的 HTTPS 插件链接。", "Enter an HTTPS plugin URL without credentials."); return
        }
        downloading = true
        downloadTask = Task {
            defer { downloading = false; downloadTask = nil }
            do {
                let data = try await PluginDownload.fetch(url, configuration: configuration)
                try Task.checkCancellation()
                let package = try PluginPackage.decode(data: data)
                try validateExternal(package)
                guard pendingPackage == nil else {
                    throw PluginAppError(zh: "请先完成或取消当前插件安装。", en: "Finish or cancel the current plugin installation first.")
                }
                // Preserve provenance for native code; downloading never grants trust.
                pendingQuarantine = Data("0083;00000000;CrossDiff;".utf8)
                pendingPackage = package
            } catch is CancellationError { }
            catch { message = localizedErrorDescription(error) }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }

    /// Authorizes one exact restricted package from the bundled inventory.
    /// Arbitrary links, native code and replacements keep their review flow.
    func installOfficial(_ entry: OfficialPlugin, configuration: URLSessionConfiguration = .ephemeral) {
        guard !downloading, pendingPackage == nil else { return }
        guard officialPlugins.contains(entry), plugin(id: entry.id) == nil,
              !failedPlugins.contains(where: { $0.id == entry.id }), storageError == nil else {
            message = L("此插件已安装或无法安装。请先在已安装列表中检查状态。", "This plugin is already installed or unavailable. Check its status in Installed."); return
        }
        downloading = true
        officialInstallingID = entry.id
        downloadTask = Task {
            defer { downloading = false; officialInstallingID = nil; downloadTask = nil }
            do {
                let bytes = try await PluginDownload.fetch(entry.url, configuration: configuration)
                try Task.checkCancellation()
                let package = try await Task.detached(priority: .userInitiated) { try entry.verifiedPackage(from: bytes) }.value
                try Task.checkCancellation()
                guard plugin(id: entry.id) == nil, !failedPlugins.contains(where: { $0.id == entry.id }), pendingPackage == nil else {
                    throw PluginAppError(zh: "插件安装状态已改变，请检查已安装列表。", en: "Plugin installation state changed. Check Installed.")
                }
                try validateExternal(package)
                _ = try storeRequired().install(package)
                refresh()
            } catch is CancellationError { }
            catch { message = localizedErrorDescription(error) }
        }
    }

    private static func quarantine(at url: URL) throws -> Data? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard size < 65_536 else { throw PluginValidationError.sizeLimit }
        if size == 0 { return Data() }
        var bytes = Data(count: size)
        let count = bytes.withUnsafeMutableBytes { getxattr(url.path, "com.apple.quarantine", $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard count == size else { throw POSIXError(.EIO) }
        return bytes
    }
}
