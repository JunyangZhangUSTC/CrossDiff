import AppKit
import Combine
import UniformTypeIdentifiers
import CrossDiffCore

/// The chooser describes installed capabilities; a draft never owns a live session.
struct NewComparisonType: Identifiable, Equatable {
    let kind: ComparisonKind
    var pluginID: String? = nil
    var id: String { pluginID ?? kind.rawValue }
    @MainActor private var manifest: PluginManifest? { PluginManager.shared.plugin(id: pluginID)?.package.manifest }
    @MainActor var title: String {
        switch kind {
        case .text: return L("文本", "Text")
        case .folder: return L("文件夹", "Folders")
        case .image: return L("图片", "Images")
        case .binary: return L("二进制", "Binary")
        case .plugin:
            if pluginID == ArchiveComparisonModel.pluginID { return L("压缩包", "Archives") }
            if pluginID == "org.crossdiff.pdf" { return L("PDF 文档", "PDF Documents") }
            if pluginID == "org.crossdiff.photography" { return L("摄影", "Photography") }
            if pluginID == "org.crossdiff.api" { return L("API 对比", "API Compare") }
            if pluginID == "org.crossdiff.audio" { return L("音频", "Audio") }
            if pluginID == "org.crossdiff.video" { return L("视频", "Video") }
            if pluginID == "org.crossdiff.office" { return L("办公文档", "Office Documents") }
            return manifest?.name.localized ?? L("插件比较", "Plugin Comparison")
        }
    }
    @MainActor var subtitle: String {
        switch kind {
        case .text: return L("粘贴文字或选择文本、代码文件", "Paste text or choose text and code files")
        case .folder: return L("比较本地目录与文件内容", "Compare local directories and their files")
        case .image: return L("并排、叠加与像素差异", "Side by side, overlays and pixel differences")
        case .binary: return L("逐字节查看十六进制差异", "Inspect byte differences in hexadecimal")
        case .plugin:
            if acceptsFolders { return L("压缩包之间，或与本地文件夹比较", "Compare archives with archives or folders") }
            if pluginID == "org.crossdiff.pdf" { return L("页面对照与可提取文字差异", "Compare pages and extractable text") }
            if manifest?.inputKind == .photoAnalysis { return L("影调、配色与局部区域分析", "Analyze tone, color and selected regions") }
            if isAPI { return L("HTTP 请求与响应的结构化差异", "Structured HTTP request and response differences") }
            if manifest?.inputKind == .audioAnalysis { return L("波形、时频图与片段对应", "Waveforms, spectrograms and matching passages") }
            if manifest?.inputKind == .videoAnalysis { return L("联动播放、逐帧与局部画面对照", "Linked playback, frame stepping and regional inspection") }
            if isOffice { return L("Word、Excel 与 PowerPoint 内容差异", "Word, Excel and PowerPoint content differences") }
            return manifest?.summary.localized ?? ""
        }
    }
    @MainActor var symbol: String {
        if manifest?.inputKind == .photoAnalysis { return "camera.aperture" }
        if isAPI { return "arrow.left.arrow.right.square" }
        if manifest?.inputKind == .videoAnalysis { return "film" }
        if isOffice { return "doc.text.image" }
        if manifest?.inputKind == .audioAnalysis { return "waveform" }
        if kind == .plugin { return acceptsFolders ? "archivebox" : pluginID == "org.crossdiff.pdf" ? "doc.richtext" : "puzzlepiece.extension" }
        return kind.symbol
    }
    @MainActor var isAPI: Bool { manifest?.inputKind == .httpExchange }
    @MainActor var isOffice: Bool { manifest?.inputKind == .officeDocument }
    @MainActor var acceptsTextInput: Bool { kind == .text || isAPI }
    @MainActor var acceptsFolders: Bool { kind == .folder || manifest?.inputKind == .archiveCatalog }

    @MainActor func validate(_ url: URL) throws {
        guard url.isFileURL else { throw PluginAppError(zh: "请选择本地文件或文件夹。", en: "Choose a local file or folder.") }
        let resource = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey])
        guard resource.isSymbolicLink != true else {
            throw PluginAppError(zh: "请选择原始文件或文件夹，暂不支持符号链接。", en: "Choose the original file or folder; symbolic links are not supported.")
        }
        if kind == .folder {
            guard resource.isDirectory == true else { throw PluginAppError(zh: "文件夹比较需要选择文件夹。", en: "Choose a folder for folder comparison.") }
            return
        }
        if kind == .plugin {
            guard let manifest, PluginManager.shared.enabledPlugins.contains(where: { $0.id == pluginID }) else {
                throw PluginAppError(zh: "此插件尚未安装或已停用，请在插件页启用后重试。", en: "This plugin is missing or disabled. Enable it in Plugins, then try again.")
            }
            if resource.isDirectory == true, acceptsFolders { return }
            if isOffice, ["doc", "xls", "ppt"].contains(url.pathExtension.lowercased()) {
                throw PluginAppError(zh: "请先将旧版 Office 文件转换为 .docx、.xlsx 或 .pptx，再进行比较。",
                                     en: "Convert legacy Office files to .docx, .xlsx or .pptx before comparing.")
            }
            guard resource.isRegularFile == true, manifest.fileExtensions.contains(url.pathExtension.lowercased()) else {
                throw PluginAppError(zh: "此项目不适用于所选比较类型。", en: "This item is not supported by the selected comparison type.")
            }
            return
        }
        guard resource.isRegularFile == true else { throw PluginAppError(zh: "请选择普通文件。", en: "Choose a regular file.") }
        if kind == .image, resource.contentType?.conforms(to: .image) != true {
            throw PluginAppError(zh: "图片比较需要选择图片文件。", en: "Choose an image file for image comparison.")
        }
        if kind == .text, try BinaryFileDetection.isLikelyBinary(url: url) {
            throw PluginAppError(zh: "此文件不是支持的文本文件，请选择二进制或其他比较类型。", en: "This is not a supported text file. Choose Binary or another comparison type.")
        }
    }
}

enum NewComparisonInput: Equatable, Sendable {
    case empty
    case text(String)
    case file(URL)
}

@MainActor
final class NewComparisonModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var selectedType: NewComparisonType?
    @Published var left: NewComparisonInput = .empty
    @Published var right: NewComparisonInput = .empty
    @Published private(set) var busy = false
    @Published private var failure: Error?
    var errorMessage: String? { failure.map(localizedErrorDescription) }
    private weak var store: WorkspaceStore?
    private var previousTypeID: String?
    private var task: Task<Void, Never>?
    private var pluginsObserver: AnyCancellable?

    init(store: WorkspaceStore) {
        self.store = store
        pluginsObserver = NotificationCenter.default.publisher(for: .crossDiffPluginsChanged).sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            if let type = self.selectedType, !self.types.contains(type) {
                self.failure = PluginAppError(zh: "所选插件已停用，请返回选择其他比较类型。", en: "The selected plugin is disabled. Go back and choose another comparison type.")
            }
        }
    }
    deinit { task?.cancel() }

    var types: [NewComparisonType] {
        [.init(kind: .text), .init(kind: .folder), .init(kind: .image), .init(kind: .binary)] +
            PluginManager.shared.enabledPlugins.map { .init(kind: .plugin, pluginID: $0.id) }
    }
    var canCreate: Bool {
        guard !busy, let type = selectedType, types.contains(type) else { return false }
        if type.isOffice, case .file(let first) = left, case .file(let second) = right,
           OfficeDocumentKind.from(fileExtension: first.pathExtension) != OfficeDocumentKind.from(fileExtension: second.pathExtension) { return false }
        return [left, right].allSatisfy {
            switch $0 {
            case .empty: return false
            case .text(let text):
                return type.acceptsTextInput && (!type.isAPI || (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 4 * 1024 * 1024))
            case .file: return true
            }
        }
    }
    func select(_ type: NewComparisonType) {
        guard !busy, types.contains(type) else { return }
        if previousTypeID != type.id {
            left = type.acceptsTextInput ? .text("") : .empty
            right = type.acceptsTextInput ? .text("") : .empty
        }
        previousTypeID = type.id; selectedType = type; failure = nil
    }
    func back() { guard !busy else { return }; selectedType = nil; failure = nil }
    func swap() { guard !busy else { return }; (left, right) = (right, left); failure = nil }
    func setInput(_ input: NewComparisonInput, side: Side) {
        guard !busy, let type = selectedType else { return }
        do {
            if case .file(let url) = input {
                try type.validate(url)
                let other = side == .left ? right : left
                if type.isOffice, case .file(let otherURL) = other,
                   OfficeDocumentKind.from(fileExtension: url.pathExtension) != OfficeDocumentKind.from(fileExtension: otherURL.pathExtension) {
                    throw PluginAppError(zh: "两侧需要同类 Office 文件，请选择两个 Word、两个 Excel 或两个 PowerPoint 文件。",
                                         en: "Choose the same Office format on both sides: two Word, Excel or PowerPoint files.")
                }
            }
            if case .text(let text) = input {
                guard type.acceptsTextInput else { return }
                if type.isAPI, text.utf8.count > 4 * 1024 * 1024 {
                    throw PluginAppError(zh: "每侧 API 输入最多 4 MiB。", en: "API input is limited to 4 MiB per side.")
                }
            }
            let normalized: NewComparisonInput = input == .empty && type.acceptsTextInput ? .text("") : input
            if side == .left { left = normalized } else { right = normalized }
            failure = nil
        } catch { failure = error }
    }
    func chooseFile(side: Side) {
        guard !busy, let type = selectedType else { return }
        let panel = NSOpenPanel()
        panel.title = side == .left ? L("选择左侧项目", "Choose Left Item") : L("选择右侧项目", "Choose Right Item")
        panel.prompt = L("选择", "Choose")
        panel.canChooseFiles = type.kind != .folder
        panel.canChooseDirectories = type.acceptsFolders
        panel.allowsMultipleSelection = false
        if type.kind == .image { panel.allowedContentTypes = [.image] }
        if let plugin = PluginManager.shared.plugin(id: type.pluginID), !type.acceptsFolders {
            panel.allowedContentTypes = plugin.package.manifest.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  self.store?.newComparison === self, self.selectedType == type else { return }
            self.setInput(.file(url), side: side)
        }
        if let parent = NativeMenuController.shared.comparisonWindow?.attachedSheet {
            panel.beginSheetModal(for: parent, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }
    func create() {
        guard !busy, let type = selectedType else { return }
        do {
            guard types.contains(type) else { throw PluginAppError(zh: "所选插件已停用，请返回选择其他比较类型。", en: "The selected plugin is disabled. Go back and choose another comparison type.") }
            guard canCreate else { return }
            for input in [left, right] { if case .file(let url) = input { try type.validate(url) } }
        } catch { failure = error; return }
        busy = true; failure = nil
        let leftInput = left, rightInput = right, kind = type.kind, pluginID = type.pluginID
        task = Task { [weak self] in
            do {
                let loader = Task.detached(priority: .userInitiated) {
                    let l = try Self.load(leftInput, isText: kind == .text)
                    try Task.checkCancellation()
                    let r = try Self.load(rightInput, isText: kind == .text)
                    return StoredComparison(kind: kind.rawValue, left: l, right: r, pluginID: pluginID)
                }
                let record = try await withTaskCancellationHandler { try await loader.value } onCancel: { loader.cancel() }
                guard let self, !Task.isCancelled, let store = self.store, store.newComparison === self else { return }
                // A plugin may have been disabled while file contents were loading.
                guard self.types.contains(type) else { throw PluginAppError(zh: "所选插件已停用。", en: "The selected plugin is disabled.") }
                let session = ComparisonSession(kind: kind, left: record.left, right: record.right, pluginID: pluginID)
                store.attach(session); store.selectedID = session.id; store.schedulePersistence()
                self.busy = false; store.newComparison = nil
            } catch {
                guard let self, !Task.isCancelled, self.store?.newComparison === self else { return }
                self.busy = false; self.failure = error
            }
        }
    }
    private nonisolated static func load(_ input: NewComparisonInput, isText: Bool) throws -> StoredTextSide {
        try Task.checkCancellation()
        switch input {
        case .text(let text): return .init(text: text, savedText: isText ? "" : text)
        case .file(let url):
            if isText {
                let file = try TextFileIO.read(url)
                return .init(text: file.text, path: url.path, encoding: file.encoding, signature: file.signature, savedText: file.text)
            }
            return .init(path: url.path)
        case .empty: throw CancellationError()
        }
    }
    func cancel() {
        task?.cancel(); busy = false
        if store?.newComparison === self { store?.newComparison = nil }
    }
    func showPlugins() {
        guard !busy else { return }
        store?.showPluginsAfterNewComparison = true
        cancel()
    }
}
