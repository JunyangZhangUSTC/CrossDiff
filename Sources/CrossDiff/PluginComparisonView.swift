import SwiftUI
import CrossDiffCore

struct PluginTableRow: Identifiable {
    let id: Int
    let label: String
    let left: String
    let right: String
    let state: String
}

@MainActor
final class PluginTableModel: ObservableObject {
    @Published private(set) var rows: [PluginTableRow] = []
    @Published private(set) var result: PluginComparisonResult?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var generation = UUID()

    func load(left: URL, right: URL, execute: PluginExecution) async {
        let token = UUID(); generation = token
        loading = true; error = nil; result = nil; rows = []
        do {
            let worker = Task.detached(priority: .userInitiated) {
                let urls = [left, right]
                var inputs: [PluginInput] = []
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    if execute.package.manifest.inputKind == .pdf {
                        let document = try PDFComparisonDecoder.load(url)
                        inputs.append(PluginInput(id: index == 0 ? "left" : "right", role: index == 0 ? .left : .right,
                            name: url.lastPathComponent, content: document.pluginContent))
                        continue
                    }
                    let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 2 * 1024 * 1024 else {
                        throw PluginAppError(zh: "文本插件每侧最多读取 2 MiB 的普通文件。", en: "Text plugins accept regular files up to 2 MiB per side.")
                    }
                    let text = try TextFileIO.read(url).text
                    guard text.utf8.count <= 4 * 1024 * 1024 else { throw PluginValidationError.sizeLimit }
                    inputs.append(PluginInput(id: index == 0 ? "left" : "right", role: index == 0 ? .left : .right,
                        name: url.lastPathComponent, content: .object(["text": .string(text)])))
                }
                return inputs
            }
            let inputs = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            let comparison = try await execute.compare(inputs)
            let parsed = try Self.parse(comparison)
            try Task.checkCancellation()
            guard generation == token else { return }
            rows = parsed; result = comparison
        } catch is CancellationError { }
        catch { if generation == token, !Task.isCancelled { self.error = localizedErrorDescription(error) } }
        if generation == token { loading = false }
    }

    static func parse(_ result: PluginComparisonResult) throws -> [PluginTableRow] {
        guard result.schema == "crossdiff.table/1", let values = result.payload["rows"]?.arrayValue,
              values.count <= 10_000 else { throw PluginValidationError.invalidField("table rows") }
        return try values.enumerated().map { index, value in
            guard let label = value["label"]?.stringValue, let left = value["left"]?.stringValue,
                  let right = value["right"]?.stringValue, let state = value["state"]?.stringValue,
                  ["same", "changed", "added", "removed", "unknown"].contains(state),
                  [label, left, right].allSatisfy({ $0.utf8.count <= 32_768 }) else {
                throw PluginValidationError.invalidField("table row")
            }
            return PluginTableRow(id: index, label: label, left: left, right: right, state: state)
        }
    }
}

struct PluginComparisonView: View {
    @ObservedObject var session: ComparisonSession
    @ObservedObject private var manager = PluginManager.shared
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        Group {
            if let id = session.pluginID, let plugin = manager.plugin(id: id), plugin.enabled,
               let left = session.left.path, let right = session.right.path {
                PluginResultView(session: session, plugin: plugin, left: URL(fileURLWithPath: left), right: URL(fileURLWithPath: right))
                    .id("\(session.id)-\(manager.revision)")
            } else {
                ContentUnavailableView {
                    Label(L("此比较需要插件", "This Comparison Needs a Plugin"), systemImage: "puzzlepiece.extension")
                } description: {
                    Text(L("文件路径和会话已保留。安装或启用对应插件后即可继续。", "Your file paths and session are retained. Install or enable the corresponding plugin to continue."))
                    if let id = session.pluginID { Text(id).font(.caption.monospaced()) }
                } actions: {
                    Button(L("管理插件…", "Manage Plugins…")) { NativeMenuController.shared.showPlugins(nil) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct PluginResultView: View {
    let session: ComparisonSession
    let plugin: AvailablePlugin
    let left: URL
    let right: URL
    @State private var execution: PluginExecution?
    @State private var failure: String?

    var body: some View {
        Group {
            if let execution {
                if plugin.package.manifest.resultView == "archiveTree" {
                    ArchiveComparisonView(left: left, right: right, model: session.archiveComparisonModel,
                        execute: { try await execution.compare($0) },
                        executionID: plugin.package.manifest.version + plugin.package.sha256 + PluginManager.shared.revision.uuidString)
                } else if plugin.package.manifest.resultView == "photography" {
                    PhotoComparisonView(left: left, right: right, model: session.photoComparisonModel,
                        execute: { try await execution.compare($0) },
                        executionID: plugin.package.manifest.version + plugin.package.sha256 + PluginManager.shared.revision.uuidString)
                } else if plugin.package.manifest.resultView == "documentPages" {
                    PDFComparisonView(left: left, right: right, model: session.pdfComparisonModel,
                        pluginName: plugin.package.manifest.name.localized, execute: { try await execution.compare($0) },
                        executionID: plugin.package.manifest.version + plugin.package.sha256 + PluginManager.shared.revision.uuidString)
                } else {
                    PluginTableView(left: left, right: right, name: plugin.package.manifest.name.localized,
                        execution: execution, model: session.pluginTableModel)
                }
            } else if let failure {
                ContentUnavailableView(L("无法运行插件", "Unable to Run Plugin"), systemImage: "exclamationmark.triangle", description: Text(failure))
            } else { ProgressView() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            do { execution = try PluginManager.shared.execution(for: plugin.id) }
            catch { failure = localizedErrorDescription(error) }
        }
    }
}

private struct PluginTableView: View {
    let left: URL
    let right: URL
    let name: String
    let execution: PluginExecution
    @ObservedObject var model: PluginTableModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var differencesOnly = false
    @State private var reloadID = UUID()
    private var theme: ComparisonTheme { ComparisonTheme(isDark: colorScheme == .dark) }
    private var visibleRows: [PluginTableRow] { differencesOnly ? model.rows.filter { $0.state != "same" } : model.rows }
    private struct RunIdentity: Hashable {
        let left: URL
        let right: URL
        let version: String
        let digest: String
        let reload: UUID
    }
    private var runIdentity: RunIdentity {
        RunIdentity(left: left, right: right, version: execution.package.manifest.version,
                    digest: execution.package.sha256, reload: reloadID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(name, systemImage: "tablecells").font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle(L("仅差异", "Changes Only"), isOn: $differencesOnly).toggleStyle(.checkbox)
                Button { reloadID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("重新读取并比较", "Reload and Compare"))
            }.padding(.horizontal, 18).frame(height: 44).controlSize(.small)
            Divider()
            if model.loading { ProgressView(L("正在比较…", "Comparing…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error = model.error {
                ContentUnavailableView(L("比较未完成", "Comparison Incomplete"), systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(visibleRows) {
                    TableColumn(L("项目", "Item")) { row in Text(row.label).font(.system(.body, design: .monospaced)).textSelection(.enabled) }.width(min: 110, ideal: 180, max: 300)
                    TableColumn(left.lastPathComponent) { row in cell(row.left, state: row.state, removed: true) }
                    TableColumn(right.lastPathComponent) { row in cell(row.right, state: row.state, removed: false) }
                }
                if let result = model.result {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.summary.localized)
                            Spacer()
                            Text(result.status == .partial ? L("部分结果", "Partial Result") : L("只读比较", "Read-only Comparison"))
                        }
                        ForEach(Array(result.diagnostics.enumerated()), id: \.offset) { _, diagnostic in Text(diagnostic.localized) }
                    }.font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText)).padding(12)
                }
            }
        }.background(Color(nsColor: theme.canvas)).foregroundStyle(Color(nsColor: theme.text))
        .task(id: runIdentity) { await model.load(left: left, right: right, execute: execution) }
    }
    private func cell(_ text: String, state: String, removed: Bool) -> some View {
        let marked = state == "changed" || state == (removed ? "removed" : "added")
        return Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .foregroundStyle(Color(nsColor: marked ? theme.differenceForeground(isRemoval: removed) : theme.text))
            .padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
            .background(marked ? Color(nsColor: theme.differenceBackground(isRemoval: removed)) : Color.clear)
    }
}
