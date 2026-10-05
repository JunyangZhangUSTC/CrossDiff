import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CrossDiffCore

struct PluginManagerView: View {
    @ObservedObject var manager: PluginManager
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var address = ""
    @State private var showDownload = false
    @State private var trustNative = false
    @State private var page = 0
    private struct Removal: Identifiable { let id: String; let name: String; let bundled: Bool }
    @State private var removal: Removal?
    private var theme: ComparisonTheme { appearance.colors }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 25, weight: .light)).foregroundStyle(Color(nsColor: theme.accent))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("扩展你的比较工具", "Extend Your Comparisons")).font(.system(size: 19, weight: .semibold))
                    Text(L("按需安装，本地运行。", "Install what you need. Run locally.")).font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                Spacer()
                Menu {
                    Button(L("从文件安装…", "Install from File…"), action: choosePackage)
                    Button(L("从 HTTPS 链接安装…", "Install from HTTPS URL…")) { showDownload.toggle() }
                } label: { Label(L("安装插件", "Install Plugin"), systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize().padding(8)
                .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: theme.separator), lineWidth: 0.5))
                .disabled(manager.pendingPackage != nil || manager.downloading)
            }.padding(22)
            Divider()
            if showDownload {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("https://…/plugin.crossdiffplugin", text: $address)
                            .textFieldStyle(.roundedBorder).disabled(manager.downloading)
                        if manager.downloading {
                            ProgressView().controlSize(.small)
                            Button(L("取消", "Cancel")) { manager.cancelDownload() }
                        } else {
                            Button(L("下载并检查", "Download & Inspect")) { manager.download(from: address) }.disabled(address.isEmpty || manager.pendingPackage != nil)
                        }
                    }
                    Text(L("仅在点击后联网下载；安装前会显示来源未验证提示与运行权限。", "Connects only when you click. Review permissions and unverified publisher information before installation."))
                        .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                }.padding(18).background(Color(nsColor: theme.chrome))
                Divider()
            }
            if let error = manager.storageError {
                VStack(alignment: .leading, spacing: 5) {
                    Label(L("本地插件存储不可用", "Local Plugin Storage Unavailable"), systemImage: "exclamationmark.triangle").font(.callout.bold())
                    Text(error).font(.caption)
                    Text(L("内置插件仍可使用。修复存储后重新启动 CrossDiff。", "Bundled plugins remain available. Restart CrossDiff after repairing storage."))
                        .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: theme.chrome))
                Divider()
            }
            HStack {
                Picker(L("插件列表", "Plugin List"), selection: $page) {
                    Text(L("已安装", "Installed")).tag(0)
                    Text(L("发现插件", "Discover")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                .id(settings.language).accessibilityIdentifier("plugins.sections")
                Spacer()
            }.padding(.horizontal, 22).padding(.vertical, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if page == 0 { installedSection } else { discoverSection }
                }.padding(.bottom, 12)
            }.id(page)
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "externaldrive")
                Text(L("也可以将插件文件拖入 CrossDiff 窗口。", "You can also drop a plugin file into a CrossDiff window."))
                Spacer()
                Text(L("实验性接口 v1", "Experimental API v1"))
            }.font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText)).padding(16)
        }
        .frame(minWidth: 650, minHeight: 460)
        .foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
        .tint(Color(nsColor: theme.accent)).preferredColorScheme(appearance.isDark ? .dark : .light)
        .environment(\.locale, settings.locale)
        .sheet(isPresented: Binding(get: { manager.pendingPackage != nil }, set: { if !$0 { manager.cancelInstall() } })) {
            if let package = manager.pendingPackage { installationPreview(package) }
        }
        .alert(L("插件", "Plugins"), isPresented: Binding(get: { manager.message != nil }, set: { if !$0 { manager.message = nil } })) {
            Button(L("好", "OK")) { manager.message = nil }
        } message: { Text(manager.message ?? "") }
        .sheet(item: $removal) { target in removalConfirmation(target) }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard let first = providers.first else { return false }
            first.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { Task { @MainActor in manager.inspect(url) } }
            }
            return true
        }
    }

    private func removalConfirmation(_ target: Removal) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: target.bundled ? "minus.circle" : "trash")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(target.bundled ? L("移除“\(target.name)”？", "Remove “\(target.name)”?")
                     : L("卸载“\(target.name)”？", "Uninstall “\(target.name)”?"))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("plugins.removal.title")
            }
            Text(target.bundled
                ? L("将从已安装列表和比较入口移除。原文件和比较会话会保留，可随时离线恢复。预装文件仍随应用保留，不会减小应用体积。",
                    "Remove it from Installed and comparison choices. Your files and sessions are kept, and you can restore it offline. Bundled files remain in the app; its size will not change.")
                : L("将删除此插件及其已安装的历史版本。原文件和比较会话会保留，重新安装后可继续使用。",
                    "Delete this plugin and its installed versions. Your files and comparison sessions are kept and can be used again after reinstalling."))
                .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("plugins.removal.message")
            HStack(spacing: 10) {
                Spacer()
                Button(L("取消", "Cancel")) { removal = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("plugins.removal.cancel")
                Button(target.bundled ? L("移除", "Remove") : L("卸载", "Uninstall"), role: .destructive) {
                    removal = nil
                    if target.bundled { manager.removeBundled(target.id) } else { manager.uninstall(target.id) }
                }
                .foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
                .accessibilityIdentifier("plugins.removal.confirm")
            }.padding(.top, 4).buttonStyle(.bordered)
        }.padding(24).frame(width: 460)
        .foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
        .preferredColorScheme(appearance.isDark ? .dark : .light)
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L("已安装", "Installed")).font(.headline)
                Text("\(manager.plugins.count + manager.failedPlugins.count)")
                    .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            }.padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 4)
            if manager.plugins.isEmpty && manager.failedPlugins.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(manager.removedBundledPlugins.isEmpty
                        ? L("还没有安装插件，选择你需要的比较功能。", "No plugins installed. Discover a comparison tool to get started.")
                        : L("还没有安装插件。选择需要的比较功能，或恢复下方的预装插件。",
                            "No plugins installed. Discover a comparison tool or restore a bundled plugin below."))
                        .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText))
                    Button(L("发现插件", "Discover Plugins")) { page = 1 }
                        .buttonStyle(.bordered).controlSize(.small)
                }.padding(22)
            }
            ForEach(manager.plugins) { plugin in
                pluginRow(plugin)
                Divider().padding(.leading, 64)
            }
            ForEach(manager.failedPlugins) { plugin in
                failedPluginRow(plugin)
                Divider().padding(.leading, 64)
            }
            if !manager.removedBundledPlugins.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("已移除的预装插件", "Removed Bundled Plugins")).font(.headline)
                    Text(L("保留在应用中，可随时离线恢复。", "Kept in the app and available to restore offline."))
                        .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 10)
                ForEach(manager.removedBundledPlugins) { plugin in
                    HStack(spacing: 12) {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(Color(nsColor: theme.secondaryText)).frame(width: 32)
                        Text(plugin.package.manifest.name.localized).font(.callout.weight(.medium))
                        Spacer()
                        restoreButton(plugin)
                    }.padding(.horizontal, 22).padding(.vertical, 10)
                }
            }
        }
    }

    private var discoverSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("官方插件", "Official Plugins")).font(.headline)
                Text(L("按需下载并安装，比较始终在本机完成。预装插件可以离线恢复。",
                       "Download what you need; comparisons stay local. Restore bundled plugins offline."))
                    .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
            ForEach(manager.officialPlugins) { entry in
                officialRow(entry).padding(.horizontal, 18).padding(.bottom, 10)
            }
            if let error = manager.officialCatalogError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).padding(.horizontal, 22).padding(.bottom, 16)
            } else if manager.officialPlugins.isEmpty {
                Text(L("此构建未附带官方插件目录。仍可从文件安装插件。", "This build has no official catalog. You can still install plugins from files."))
                    .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText))
                    .padding(.horizontal, 22).padding(.bottom, 16)
            }
        }
    }

    private func pluginActions(_ entry: AvailablePlugin) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 7) {
                Text(entry.enabled ? L("已启用", "Enabled") : L("已停用", "Disabled"))
                    .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                Toggle(L("启用插件", "Enable Plugin"), isOn: Binding(get: { entry.enabled }, set: { manager.setEnabled($0, id: entry.id) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel(entry.package.manifest.name.localized + " · " + L("启用插件", "Enable Plugin"))
                    .accessibilityIdentifier("plugins.toggle." + entry.id)
            }
            HStack(spacing: 8) {
                if entry.installation?.previousVersion != nil {
                    Menu {
                        Button(L("回退到上一版本", "Roll Back to Previous Version")) { manager.rollback(entry.id) }
                    } label: { Image(systemName: "arrow.uturn.backward") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(L("回退到上一版本", "Roll Back to Previous Version"))
                }
                Button(role: .destructive) {
                    removal = Removal(id: entry.id, name: entry.package.manifest.name.localized, bundled: entry.bundled)
                } label: {
                    Label(entry.bundled ? L("移除…", "Remove…") : L("卸载…", "Uninstall…"),
                          systemImage: entry.bundled ? "minus.circle" : "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier((entry.bundled ? "plugins.remove." : "plugins.uninstall.") + entry.id)
            }
        }.fixedSize(horizontal: true, vertical: false)
        .disabled(manager.downloading || manager.pendingPackage != nil)
    }

    private func restoreButton(_ entry: AvailablePlugin) -> some View {
        Button { manager.restoreBundled(entry.id) } label: {
            Label(L("恢复", "Restore"), systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(manager.downloading || manager.pendingPackage != nil)
        .accessibilityIdentifier("plugins.restore." + entry.id)
    }

    private func officialRow(_ entry: OfficialPlugin) -> some View {
        let installed = manager.plugin(id: entry.id)
        let failed = manager.failedPlugins.contains { $0.id == entry.id }
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: entry.id == "org.crossdiff.archive" ? "archivebox" : entry.id == "org.crossdiff.pdf" ? "doc.richtext" : "puzzlepiece.extension")
                .font(.system(size: 23, weight: .light)).foregroundStyle(Color(nsColor: theme.accent))
                .frame(width: 38, height: 42)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.name.localized).font(.system(size: 13, weight: .semibold))
                    Text(entry.version).font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                Text(entry.summary.localized).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(L("本地运行 · 受限权限", "Local processing · Restricted permissions"))
                    .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 7) {
                if manager.officialInstallingID == entry.id {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(L("正在安装…", "Installing…")).font(.callout)
                    }
                    Button(L("取消", "Cancel")) { manager.cancelDownload() }
                        .controlSize(.small).accessibilityIdentifier("plugins.official.cancel")
                } else if let installed {
                    Label(installed.bundled ? L("已内置", "Bundled") : L("已安装", "Installed"), systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(Color(nsColor: theme.secondaryText))
                    pluginActions(installed)
                    if installed.package.manifest.version != entry.version {
                        Text(L("已安装版本：", "Installed: ") + installed.package.manifest.version)
                            .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                    }
                } else if let removed = manager.removedBundledPlugins.first(where: { $0.id == entry.id }) {
                    restoreButton(removed)
                    Text(L("本机恢复 · 无需下载", "Restore locally · No download"))
                        .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                } else if failed {
                    Text(L("请检查安装状态", "Check installation"))
                        .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                } else {
                    Button {
                        manager.installOfficial(entry)
                    } label: {
                        Label(L("下载并安装", "Download & Install"), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(manager.downloading || manager.pendingPackage != nil || manager.storageError != nil)
                    .accessibilityIdentifier("plugins.official.install." + entry.id)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                        .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
        .padding(16)
        .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: theme.separator), lineWidth: 0.5))
        .accessibilityIdentifier("plugins.official." + entry.id)
    }

    private func pluginRow(_ entry: AvailablePlugin) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: entry.package.manifest.inputKind == .gitRepository ? "point.3.connected.trianglepath.dotted" : entry.package.manifest.inputKind == .videoAnalysis ? "film" : entry.package.manifest.inputKind == .officeDocument ? "doc.text.image" : entry.package.manifest.inputKind == .audioAnalysis ? "waveform" : entry.package.manifest.inputKind == .httpExchange ? "arrow.left.arrow.right.square" : entry.package.manifest.inputKind == .photoAnalysis ? "camera.aperture" : entry.package.manifest.inputKind == .archiveCatalog ? "archivebox" : entry.package.manifest.inputKind == .pdf ? "doc.richtext" : "tablecells")
                .font(.system(size: 21, weight: .light)).foregroundStyle(Color(nsColor: theme.accent))
                .frame(width: 32, height: 34)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(entry.package.manifest.name.localized).font(.headline)
                    Text(entry.package.manifest.version).font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                    Text(entry.bundled ? L("内置", "Bundled") : L("本地安装", "Local Installation"))
                        .font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(nsColor: theme.chrome), in: Capsule())
                }
                Text(entry.package.manifest.summary.localized).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(entry.package.manifest.runtime == .restrictedJavaScript
                    ? L("受限 JavaScript · 无文件与网络接口", "Restricted JavaScript · No file or network APIs")
                    : L("完全信任 · 可访问本机与网络", "Full Trust · Can access this computer and network"))
                    .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(entry.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(nsColor: theme.secondaryText)).textSelection(.enabled)
            }
            Spacer(minLength: 10)
            pluginActions(entry)

        }.padding(20)
    }

    private func failedPluginRow(_ entry: FailedPlugin) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 21, weight: .light)).foregroundStyle(Color(nsColor: theme.accent))
                .frame(width: 32, height: 34)
            VStack(alignment: .leading, spacing: 7) {
                Text(L("无法加载插件", "Unable to Load Plugin")).font(.headline)
                Text(entry.id + " · " + entry.installation.activeVersion).font(.caption.monospaced()).textSelection(.enabled)
                Text(entry.error).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(L("此插件已停止使用；可以卸载后重新安装。", "This plugin is unavailable. Uninstall it and reinstall a valid package."))
                    .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            Spacer(minLength: 10)
            Button(L("卸载…", "Uninstall…"), role: .destructive) {
                removal = Removal(id: entry.id, name: entry.id, bundled: false)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityIdentifier("plugins.uninstall." + entry.id)
        }.padding(20)
    }

    private func installationPreview(_ package: PluginPackage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L("检查插件", "Review Plugin"), systemImage: "puzzlepiece.extension").font(.title2.bold())
            Text(package.manifest.name.localized).font(.headline)
            Text(package.manifest.summary.localized).font(.callout)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text(L("版本", "Version")); Text(package.manifest.version) }
                GridRow { Text(L("标识", "Identifier")); Text(package.manifest.id).textSelection(.enabled) }
                GridRow { Text(L("发布者", "Publisher")); Text(L("未验证", "Unverified")) }
            }.font(.callout)
            Text(L("摘要检查只能验证包内数据完整，不能验证作者身份。请仅安装来源可信的插件。", "The digest checks package integrity, not publisher identity. Install plugins only from sources you trust."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText))
            if package.manifest.runtime == .trustedExecutable {
                Text(L("此插件运行原生代码，可读取本机文件、访问网络并启动其他程序。它不受 CrossDiff 的 JavaScript 限制；运行时还会检查代码签名与系统隔离标记。", "This plugin runs native code and can read local files, access the network, and start programs. CrossDiff's JavaScript restrictions do not apply. Code signatures and system quarantine are checked before execution."))
                    .font(.callout)
                Toggle(L("我信任此版本，并允许以完全信任模式运行", "I trust this version and allow full-trust execution"), isOn: $trustNative)
            } else {
                Text(L("受限 JavaScript：仅接收选中文件的比较数据，无文件、网络或进程接口。这是受限运行时，不是操作系统沙箱。", "Restricted JavaScript receives comparison data from selected files, with no file, network, or process APIs. This is a restricted runtime, not an operating-system sandbox."))
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { manager.cancelInstall() }.keyboardShortcut(.cancelAction)
                Button(L("安装", "Install")) { manager.installPending(trustNative: trustNative) }
                    .keyboardShortcut(.defaultAction).disabled(package.manifest.runtime == .trustedExecutable && !trustNative)
            }
        }.padding(24).frame(width: 520)
        .foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
        .onAppear { trustNative = false }
    }

    private func choosePackage() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "crossdiffplugin") ?? .data]
        panel.title = L("安装插件", "Install Plugin")
        if panel.runModal() == .OK, let url = panel.url { manager.inspect(url) }
    }
}
