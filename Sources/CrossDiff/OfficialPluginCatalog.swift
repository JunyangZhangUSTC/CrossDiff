import Foundation
import CrossDiffCore

/// Ships inside the app. Reading this inventory never requests the network;
/// remote bytes cannot add trusted entries or grant native execution approval.
struct OfficialPluginCatalog: Decodable, Sendable {
    let formatVersion: Int
    let releaseTag: String
    let plugins: [OfficialPlugin]

    static func load(from url: URL) throws -> Self {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, (1...131_072).contains(size) else { throw invalid() }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 131_072,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "releaseTag", "plugins"],
              let entries = object["plugins"] as? [[String: Any]] else { throw invalid() }
        for entry in entries {
            guard Set(entry.keys) == ["id", "version", "name", "summary", "asset", "url", "sha256", "size"] else { throw invalid() }
            for key in ["name", "summary"] {
                guard let text = entry[key] as? [String: Any], Set(text.keys) == ["zhHans", "en"] else { throw invalid() }
            }
        }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.formatVersion == 1, catalog.releaseTag.hasPrefix("v"),
              validVersion(String(catalog.releaseTag.dropFirst())), catalog.plugins.count <= 32,
              Set(catalog.plugins.map(\.id)).count == catalog.plugins.count,
              Set(catalog.plugins.map(\.asset)).count == catalog.plugins.count else { throw invalid() }
        for plugin in catalog.plugins { try plugin.validate(releaseTag: catalog.releaseTag) }
        return catalog
    }

    fileprivate static func validVersion(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#, options: .regularExpression) != nil
    }
    fileprivate static func invalid() -> PluginAppError {
        PluginAppError(zh: "官方插件目录无效，请重新下载 CrossDiff。", en: "The official plugin catalog is invalid. Download CrossDiff again.")
    }
}

struct OfficialPlugin: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let version: String
    let name: PluginLocalizedText
    let summary: PluginLocalizedText
    let asset: String
    let url: URL
    let sha256: String
    let size: Int

    fileprivate func validate(releaseTag: String) throws {
        guard id.utf8.count <= 128, id.range(of: #"^org\.crossdiff\.[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil,
              OfficialPluginCatalog.validVersion(version),
              asset.utf8.count <= 160, asset.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.crossdiffplugin$"#, options: .regularExpression) != nil,
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...PluginPackage.maximumPackageBytes).contains(size),
              [name.zhHans, name.en].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }),
              [summary.zhHans, summary.en].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4096 }),
              url.absoluteString == "https://github.com/JunyangZhangUSTC/CrossDiff/releases/download/\(releaseTag)/\(asset)",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw OfficialPluginCatalog.invalid()
        }
    }

    func verifiedPackage(from data: Data) throws -> PluginPackage {
        guard data.count == size, PluginPackage.digest(of: data) == sha256 else {
            throw PluginAppError(zh: "插件下载的大小或校验和不符，未进行安装。请重试或重新下载 CrossDiff。",
                                 en: "The plugin download does not match its expected size or checksum. Nothing was installed. Retry or download CrossDiff again.")
        }
        let package = try PluginPackage.decode(data: data)
        guard package.manifest.id == id, package.manifest.version == version,
              package.manifest.runtime == .restrictedJavaScript else {
            throw PluginAppError(zh: "下载的插件与官方目录或受限运行要求不符，未进行安装。",
                                 en: "The downloaded plugin does not match the official catalog or restricted runtime requirements. Nothing was installed.")
        }
        return package
    }
}
