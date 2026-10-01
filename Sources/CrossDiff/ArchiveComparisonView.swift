import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
struct ArchiveComparisonView: View {
    let left: URL
    let right: URL
    @ObservedObject var model: ArchiveComparisonModel
    let execute: @Sendable ([PluginInput]) async throws -> PluginComparisonResult
    var executionID: String = ""
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var mode = ArchiveDisplayMode.paths
    @State private var differencesOnly = false
    @State private var query = ""
    @State private var selection: ArchiveOutlineNode?
    @State private var showsInformation = false
    @State private var reloadGeneration = 0
    @State private var startedReloadGeneration = 0
    private var theme: ComparisonTheme { appearance.colors }
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [ArchiveComparisonRow] {
        model.rows.filter { (!differencesOnly || $0.state != .same) && (search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)) }
    }
    private var matchingGroups: [ArchiveContentGroup] {
        model.groups.filter { search.isEmpty || ($0.left + $0.right).contains { $0.path.localizedCaseInsensitiveContains(search) } }
    }
    private var unknownCount: Int { model.rows.filter { $0.state == .unknown }.count }
    private var differenceCount: Int { model.rows.filter { $0.state != .same && $0.state != .unknown }.count }
    private var isPartial: Bool {
        model.result?.status == .partial || model.leftSnapshot?.isComplete == false || model.rightSnapshot?.isComplete == false
    }
    private var runIdentity: [String] { [left.absoluteString, right.absoluteString, executionID, String(reloadGeneration)] }

    var body: some View {
        VStack(spacing: 0) {
            sourceHeaders
            Divider()
            controls
            Divider()
            if model.isLoading {
                loadingView
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(L("无法完成归档比较", "Archive Comparison Incomplete"), systemImage: "archivebox")
                } description: {
                    Text(localizedErrorDescription(error))
                } actions: {
                    Button(L("重新比较", "Compare Again"), action: reload)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.result != nil {
                ZStack {
                    NativeArchiveOutlineView(rows: model.rows, groups: model.groups,
                        dataID: model.result?.runID ?? runIdentity.joined(separator: "\n"), mode: mode,
                        query: query, differencesOnly: differencesOnly, theme: theme,
                        language: settings.language, selection: $selection)
                    if (mode == .paths ? matches.isEmpty : matchingGroups.isEmpty) {
                        emptyView.padding(.top, 30).allowsHitTesting(false)
                    }
                }
                Divider()
                selectionInformation
                Divider()
                resultBar
            } else {
                ContentUnavailableView {
                    Label(model.isCancelled ? L("比较已取消", "Comparison Canceled") : L("准备比较归档", "Ready to Compare Archives"),
                          systemImage: "archivebox")
                } description: {
                    Text(L("只读检查文件内容，不在磁盘上解压。", "Reads file contents without extracting to disk."))
                } actions: {
                    Button(L("开始比较", "Start Comparison"), action: reload)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(Color(nsColor: theme.text))
        .background(Color(nsColor: theme.canvas))
        .tint(Color(nsColor: theme.accent))
        .environment(\.locale, settings.locale)
        .task(id: runIdentity) {
            let force = reloadGeneration != startedReloadGeneration
            startedReloadGeneration = reloadGeneration
            await model.load(left: left, right: right, execute: execute, force: force, executionID: executionID)
        }
        .onChange(of: model.result == nil) { _, isEmpty in if isEmpty { selection = nil; showsInformation = false } }
    }

    private var sourceHeaders: some View {
        HStack(spacing: 0) {
            sourceHeader(left, snapshot: model.leftSnapshot, isLeft: true)
            Rectangle().fill(Color(nsColor: theme.separator)).frame(width: 1)
            sourceHeader(right, snapshot: model.rightSnapshot, isLeft: false)
        }
        .frame(height: 70).background(Color(nsColor: theme.chrome))
    }
    private func sourceHeader(_ url: URL, snapshot: ArchiveSnapshot?, isLeft: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: snapshot.map { $0.sourceKind == .folder ? "folder" : "archivebox" } ?? "doc")
                .font(.system(size: 22, weight: .light)).foregroundStyle(Color(nsColor: theme.accent))
                .frame(width: 27)
            VStack(alignment: .leading, spacing: 5) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(url.path)
                HStack(spacing: 5) {
                    Text(isLeft ? L("左侧", "Left") : L("右侧", "Right"))
                    if let snapshot {
                        Text("·")
                        Text(snapshot.sourceKind == .folder ? L("文件夹", "Folder") : L("压缩包", "Archive"))
                        Text("·")
                        Text(L("\(snapshot.entries.count) 项", "\(snapshot.entries.count) items")).monospacedDigit()
                    }
                }.font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).frame(maxWidth: .infinity, alignment: .leading)
        .help(url.path)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isLeft ? "archive.source.left" : "archive.source.right")
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker(L("归档比较视图", "Archive Comparison View"), selection: $mode) {
                ForEach(ArchiveDisplayMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 230).id(settings.language)
            .accessibilityIdentifier("archive.mode")
            if mode == .paths {
                Toggle(L("仅差异", "Changes Only"), isOn: $differencesOnly)
                    .toggleStyle(.checkbox).fixedSize()
                    .accessibilityIdentifier("archive.differencesOnly")
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                TextField(L("筛选路径", "Filter Paths"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityIdentifier("archive.search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(nsColor: theme.secondaryText)) }
                        .buttonStyle(.plain).help(L("清除筛选", "Clear Filter"))
                        .accessibilityLabel(L("清除路径筛选", "Clear Path Filter"))
                        .accessibilityIdentifier("archive.search.clear")
                }
            }
            .padding(.horizontal, 8).frame(width: 190, height: 27)
            .background(Color(nsColor: theme.canvas), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: theme.separator), lineWidth: 0.6))
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(model.isLoading)
                .help(L("重新读取并比较", "Reload and Compare"))
                .accessibilityLabel(L("重新读取并比较归档", "Reload and Compare Archives"))
                .accessibilityIdentifier("archive.reload")
        }
        .controlSize(.small).padding(.horizontal, 18).frame(height: 47)
        .background(Color(nsColor: theme.chrome))
    }

    private var loadingView: some View {
        VStack(spacing: 15) {
            Image(systemName: "archivebox").font(.system(size: 31, weight: .ultraLight)).foregroundStyle(Color(nsColor: theme.secondaryText))
            Text(model.phase.title).font(.system(size: 13, weight: .medium))
            ProgressView(value: min(1, max(0, model.progress))).frame(width: 240)
            Text(L("流式读取并校验内容 · 不写入原文件", "Reading and Verifying Contents · Source Files Stay Unchanged"))
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
            Button(L("取消", "Cancel")) { model.cancel() }.accessibilityIdentifier("archive.cancel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: mode == .content ? "square.stack.3d.up" : "folder").font(.system(size: 31, weight: .ultraLight))
            Text(emptyTitle).font(.system(size: 15, weight: .medium))
            Text(emptyDescription).font(.system(size: 12)).multilineTextAlignment(.center).frame(maxWidth: 450)
        }
        .foregroundStyle(Color(nsColor: theme.secondaryText))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var emptyTitle: String {
        if mode == .content { return search.isEmpty ? L("未发现跨路径的相同内容", "No Matching Contents Across Paths") : L("没有匹配的内容组", "No Matching Content Groups") }
        if model.rows.isEmpty { return L("两侧均为空目录", "Both Directories Are Empty") }
        return L("没有匹配项", "No Matching Items")
    }
    private var emptyDescription: String {
        if mode == .content { return L("这里只显示已验证相同、并且出现在不同路径的文件；不据此推断移动或重命名。", "This view shows verified identical files found at different paths. It does not infer moves or renames.") }
        if model.rows.isEmpty { return L("目录清单已完整读取，没有文件或子目录。", "Both listings were read completely and contain no files or subfolders.") }
        return L("调整路径筛选，或关闭“仅差异”查看全部内容。", "Adjust the path filter or turn off Changes Only to see all items.")
    }

    private var selectionInformation: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: selection?.symbol ?? "info.circle").foregroundStyle(Color(nsColor: theme.secondaryText))
            if let selection {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.path.isEmpty ? selection.title : selection.path)
                        .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text(selection.detail).font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText)).lineLimit(2)
                }.help(selection.tooltip)
            } else {
                Text(mode == .paths ? L("展开目录查看文件；选择条目查看完整路径与校验状态。", "Expand folders to browse files. Select an item for its full path and verification status.") :
                        L("相同内容按组展示；左右成员保留各自路径。", "Identical contents are grouped; each side retains its own paths."))
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 10).frame(minHeight: 52, alignment: .leading)
        .background(Color(nsColor: theme.chrome))
        .accessibilityIdentifier("archive.selectionInfo")
    }

    private var resultBar: some View {
        HStack(spacing: 12) {
            if mode == .paths {
                Text(L("\(matches.count) / \(model.rows.count) 项", "\(matches.count) / \(model.rows.count) items"))
                Text(L("\(differenceCount) 项差异", "\(differenceCount) changed items"))
                if unknownCount > 0 { Text(L("\(unknownCount) 项未验证", "\(unknownCount) unverified")) }
            } else {
                Text(L("\(matchingGroups.count) / \(model.groups.count) 组相同内容", "\(matchingGroups.count) / \(model.groups.count) matching content \(model.groups.count == 1 ? "group" : "groups")"))
            }
            Spacer(minLength: 4)
            Button { showsInformation.toggle() } label: {
                Label(isPartial ? L("部分结果", "Partial Result") : L("比较说明", "Comparison Details"),
                      systemImage: isPartial ? "exclamationmark.circle" : "info.circle")
            }
            .buttonStyle(.borderless).foregroundStyle(Color(nsColor: isPartial ? theme.accent : theme.secondaryText))
            .accessibilityIdentifier("archive.diagnostics")
            .popover(isPresented: $showsInformation, arrowEdge: .top) { diagnosticInformation }
            Label(L("只读", "Read Only"), systemImage: "lock")
        }
        .font(.system(size: 11)).monospacedDigit().lineLimit(1)
        .foregroundStyle(Color(nsColor: theme.secondaryText))
        .padding(.horizontal, 18).frame(height: 34)
        .background(Color(nsColor: theme.chrome))
    }

    private var diagnosticInformation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isPartial ? L("部分内容未验证", "Some Contents Are Unverified") : L("只读内容比较", "Read-only Content Comparison"),
                  systemImage: isPartial ? "exclamationmark.circle" : "checkmark.shield")
                .font(.system(size: 15, weight: .semibold))
            Text(L("只在内存中流式读取压缩内容，不写出解压文件。不跟随链接，不修改任何来源。相同状态基于文件内容，未比较时间、权限或其他文件属性。",
                   "Compressed contents are read as streams without extracting files to disk. Links are not followed and sources stay unchanged. Equality refers to file contents, not timestamps, permissions, or other attributes."))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let snapshot = model.leftSnapshot { snapshotInformation(snapshot, isLeft: true) }
                    if let snapshot = model.rightSnapshot { snapshotInformation(snapshot, isLeft: false) }
                    if let result = model.result {
                        ForEach(Array(result.diagnostics.enumerated()), id: \.offset) { _, item in
                            Text(item.localized).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 260)
            Text(L("受限或不支持的条目会标为未验证；损坏、加密、路径冲突或超出读取限额时会停止比较。",
                   "Unsupported entries are marked unverified. Corruption, encryption, conflicting paths, or reading limits stop the comparison."))
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 450)
        .foregroundStyle(Color(nsColor: theme.text)).background(Color(nsColor: theme.canvas))
    }
    private func snapshotInformation(_ snapshot: ArchiveSnapshot, isLeft: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text((isLeft ? L("左侧", "Left") : L("右侧", "Right")) + " · " + snapshot.sourceURL.lastPathComponent)
                .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(L("\(snapshot.entries.count) 项 · 已读取 \(ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: settings.locale).format(snapshot.totalExpandedBytes))",
                   "\(snapshot.entries.count) items · \(ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: settings.locale).format(snapshot.totalExpandedBytes)) read"))
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
            ForEach(snapshot.entries.filter { $0.issue != nil }, id: \.path) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text(entry.issue?.localizedDescription ?? "").font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reload() {
        selection = nil; showsInformation = false
        reloadGeneration += 1
    }
}
