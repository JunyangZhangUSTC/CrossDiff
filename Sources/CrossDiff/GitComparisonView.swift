import SwiftUI
import CrossDiffCore

@MainActor
struct GitComparisonView: View {
    @ObservedObject var model: GitComparisonModel
    let execution: PluginExecution
    let executionID: String
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    private var theme: ComparisonTheme { ComparisonTheme(isDark: colorScheme == .dark) }
    private var comparingCommits: Bool { model.state.leftKind == .commit && model.state.rightKind == .commit }
    private var includesWorkingTree: Bool { model.state.leftKind == .workingTree || model.state.rightKind == .workingTree }

    var body: some View {
        VStack(spacing: 0) {
            repositoryBar
            Divider()
            revisionBar
            Divider()
            if let error = model.errorMessage { errorBanner(error) }
            HSplitView {
                sidebar.frame(minWidth: 180, idealWidth: 220, maxWidth: 240)
                detail.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: theme.canvas))
        .foregroundStyle(Color(nsColor: theme.text))
        .tint(Color(nsColor: theme.accent))
        .onDisappear { model.cancel() }
        .task(id: executionID) {
            let allowNetwork = model.allowInitialNetwork
            model.allowInitialNetwork = false
            await model.open(execution: execution, allowNetwork: allowNetwork, executionID: executionID)
        }
    }

    private var repositoryBar: some View {
        HStack(spacing: 11) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 20)).foregroundStyle(Color(nsColor: theme.accent))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(model.displayName).font(.system(size: 14, weight: .semibold))
                    Text(model.state.isRemote ? L("远程仓库", "Remote Repository") : L("本地仓库", "Local Repository"))
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
                Text(model.state.source).font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                    .textSelection(.enabled)
            }
            .lineLimit(1).truncationMode(.middle).help(model.state.source)
            Spacer(minLength: 8)
            if model.isLoading || model.isLoadingFile {
                ProgressView().controlSize(.small)
                Button(L("取消", "Cancel")) { model.cancel() }
                    .accessibilityIdentifier("git.cancel")
            } else {
                Button {
                    Task { await model.refresh(execution: execution) }
                } label: {
                    Label(model.needsConnection ? L("下载仓库", "Download Repository") : L("刷新", "Refresh"), systemImage: model.needsConnection ? "arrow.down.circle" : "arrow.clockwise")
                }
                .help(model.state.isRemote
                    ? L("从远程更新 CrossDiff 的仓库缓存，再重新比较。", "Update CrossDiff’s repository cache from the remote, then compare again.")
                    : L("重新读取提交、暂存区和工作区的最新状态，不修改文件或暂存内容。", "Reload the latest commits, staging area and working tree without changing files or staged content."))
                .accessibilityIdentifier("git.refresh")
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color(nsColor: theme.chrome))
    }

    private var revisionBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.supportsLocalSources { presetControls }
            HStack(alignment: .bottom, spacing: 10) {
                revisionInput(.left)
                Button {
                    model.swapRevisions()
                    Task { await model.compare(execution: execution) }
                } label: { Image(systemName: "arrow.left.arrow.right").frame(height: 17) }
                    .help(L("交换两侧来源", "Swap Sources"))
                    .accessibilityLabel(L("交换两侧来源", "Swap Sources"))
                    .accessibilityIdentifier("git.swap")
                    .disabled(model.repository == nil || model.isLoading)
                revisionInput(.right)
                comparisonOptions
                Button(L("比较", "Compare")) { Task { await model.compare(execution: execution) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCompare)
                    .accessibilityIdentifier("git.compare")
            }
        }
        .font(.system(size: 12)).controlSize(.small).buttonStyle(.bordered)
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var presetControls: some View {
        HStack(spacing: 10) {
            Menu {
                presetAction(.allChanges)
                presetAction(.staged)
                presetAction(.unstaged)
                if model.activePreset == .custom {
                    Divider()
                    Label(GitComparisonPreset.custom.title, systemImage: "checkmark")
                }
            } label: {
                Label(model.activePreset.title, systemImage: "square.stack.3d.up")
            }
            .fixedSize().disabled(model.isLoading)
            .accessibilityLabel(L("快捷比较", "Quick Comparison"))
            .accessibilityIdentifier("git.preset")
            Text(model.activePreset.description)
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                .lineLimit(1).truncationMode(.tail).help(model.activePreset.description)
            Spacer(minLength: 0)
        }
    }

    private func presetAction(_ preset: GitComparisonPreset) -> some View {
        Button {
            model.applyPreset(preset)
            Task { await model.compare(execution: execution) }
        } label: {
            if model.activePreset == preset { Label(preset.title, systemImage: "checkmark") }
            else { Text(preset.title) }
        }
    }

    private var comparisonOptions: some View {
        Menu {
            Toggle(L("包含未跟踪文件", "Include Untracked Files"), isOn: $model.state.includeUntracked)
                .disabled(!includesWorkingTree)
            Text(L("仅工作区生效；仍遵循 Git 忽略规则。", "Applies to the working tree; Git ignore rules still apply."))
            Divider()
            Toggle(L("识别重命名", "Detect Renames"), isOn: $model.state.detectRenames)
            Text(comparingCommits
                ? L("提交之间按 50% 相似度识别重命名。", "Commit comparisons detect renames at 50% similarity.")
                : L("涉及暂存区或工作区时，仅将内容完全相同的移动识别为重命名。", "With staging or working-tree sources, only moves with identical content are detected as renames."))
            Divider()
            Toggle(L("从共同祖先比较", "Compare from Merge Base"), isOn: $model.state.useMergeBase)
                .disabled(!comparingCommits)
            Text(L("共同祖先仅用于两个提交之间的比较。", "Merge-base comparison is available only between two commits."))
        } label: { Image(systemName: "slider.horizontal.3").frame(height: 17) }
        .help(L("更改选项后点击比较。工作区可包含未跟踪文件，忽略规则仍然生效；共同祖先仅用于提交之间。", "Click Compare after changing options. Working-tree comparisons can include untracked files while respecting ignore rules; merge base applies only between commits."))
        .accessibilityLabel(L("Git 比较选项", "Git Comparison Options"))
        .accessibilityIdentifier("git.options")
        .disabled(model.isLoading)
    }

    private func revisionInput(_ side: Side) -> some View {
        let kind = side == .left ? model.state.leftKind : model.state.rightKind
        let sideTitle = side == .left ? L("左侧", "Left") : L("右侧", "Right")
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(sideTitle).font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                if model.supportsLocalSources {
                    Menu {
                        sourceAction(.commit, side: side)
                        sourceAction(.index, side: side)
                        sourceAction(.workingTree, side: side)
                    } label: { Text(kind.title).font(.system(size: 11)) }
                        .menuStyle(.borderlessButton).fixedSize().disabled(model.isLoading)
                        .accessibilityLabel(side == .left ? L("左侧来源", "Left Source") : L("右侧来源", "Right Source"))
                        .accessibilityIdentifier(side == .left ? "git.source.left" : "git.source.right")
                } else {
                    Text(L("提交", "Commit")).font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
                }
            }
            if kind == .commit {
                HStack(spacing: 4) {
                    TextField(L("分支、标签或提交哈希", "Branch, tag, or commit hash"), text: Binding(
                        get: { side == .left ? model.state.leftRevision : model.state.rightRevision },
                        set: { model.setRevision($0, side: side) }
                    ))
                    .font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.compare(execution: execution) } }
                    .accessibilityIdentifier(side == .left ? "git.revision.left" : "git.revision.right")
                    Menu {
                        revisionChoices(side)
                    } label: { Image(systemName: "chevron.down") }
                    .menuIndicator(.hidden).fixedSize()
                    .help(L("选择分支、标签或最近提交", "Choose a Branch, Tag, or Recent Commit"))
                    .accessibilityLabel(side == .left ? L("选择左侧提交", "Choose Left Revision") : L("选择右侧提交", "Choose Right Revision"))
                    .accessibilityIdentifier(side == .left ? "git.revision.left.menu" : "git.revision.right.menu")
                }
                .disabled(model.repository == nil || model.isLoading)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: kind == .index ? "tray.full" : "folder")
                    Text(kind == .index ? L("已暂存的内容", "Staged contents") : L("磁盘上的当前内容", "Current contents on disk"))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color(nsColor: theme.secondaryText))
                .padding(.horizontal, 8).frame(height: 22)
                .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: theme.separator), lineWidth: 0.5))
                .help(L("点击比较或刷新读取最新状态；仅查看，不暂存、撤销或修改文件。", "Compare or refresh to read the latest state. Viewing does not stage, revert or change files."))
            }
        }
        .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
    }

    private func sourceAction(_ kind: GitRevisionSourceKind, side: Side) -> some View {
        Button {
            model.setSource(kind, side: side)
            Task { await model.compare(execution: execution) }
        } label: {
            if (side == .left ? model.state.leftKind : model.state.rightKind) == kind {
                Label(kind.title, systemImage: "checkmark")
            } else { Text(kind.title) }
        }
    }

    @ViewBuilder
    private func revisionChoices(_ side: Side) -> some View {
        Button("HEAD") { model.setRevision("HEAD", side: side) }
        let branches = model.references.filter { $0.kind == .branch }
        let remoteBranches = model.references.filter { $0.kind == .remoteBranch }
        let tags = model.references.filter { $0.kind == .tag }
        if !branches.isEmpty {
            Menu(L("分支", "Branches")) {
                ForEach(branches) { reference in
                    Button(reference.name) { model.setRevision(reference.fullName, side: side) }
                }
            }
        }
        if !remoteBranches.isEmpty {
            Menu(L("远程分支", "Remote Branches")) {
                ForEach(remoteBranches) { reference in
                    Button(reference.name) { model.setRevision(reference.fullName, side: side) }
                }
            }
        }
        if !tags.isEmpty {
            Menu(L("标签", "Tags")) {
                ForEach(tags) { reference in
                    Button(reference.name) { model.setRevision(reference.fullName, side: side) }
                }
            }
        }
        if !model.commits.isEmpty {
            Divider()
            Menu(L("最近提交", "Recent Commits")) {
                ForEach(model.commits) { commit in
                    Button("\(commit.shortID)  \(commit.subject)") { model.setRevision(commit.objectID, side: side) }
                }
            }
        }
    }

    private var sidebar: some View {
        let files = model.filteredFiles
        return VStack(spacing: 0) {
            VStack(spacing: 9) {
                Picker(L("文件筛选", "File Filter"), selection: $model.state.differencesOnly) {
                    Text(L("仅差异", "Changes")).tag(true)
                    Text(L("全部", "All")).tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().id(settings.language)
                .accessibilityIdentifier("git.files.filter")
                TextField(L("搜索文件路径", "Search file paths"), text: $model.pathFilter)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .accessibilityIdentifier("git.files.search")
            }
            .padding(12)
            Divider()
            GitFileTreeView(files: files, selectedID: model.selectedFile?.id,
                            expandAll: !model.pathFilter.isEmpty, theme: theme) { file in
                Task { await model.selectFile(file) }
            }
            .overlay {
                if files.isEmpty && !model.isLoading {
                    VStack(spacing: 9) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 24))
                        Text(model.comparison == nil ? L("等待比较", "Ready to Compare") : L("没有匹配的文件", "No Matching Files"))
                            .font(.system(size: 12, weight: .medium))
                        if model.comparison != nil {
                            Text(L("试试“全部”或调整搜索。", "Choose All or adjust your search."))
                                .font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(Color(nsColor: theme.secondaryText)).multilineTextAlignment(.center).padding(16)
                }
            }
            Divider()
            HStack {
                Text(L("\(files.count) 个文件", "\(files.count) files"))
                Spacer(minLength: 0)
                if let comparison = model.comparison {
                    Text(L("\(comparison.changedFiles.count) 项变化", "\(comparison.changedFiles.count) changed"))
                }
            }
            .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            .padding(.horizontal, 12).frame(height: 30)
        }
        .background(Color(nsColor: theme.chrome))
    }

    @ViewBuilder
    private var detail: some View {
        if let session = model.detailSession, let file = model.selectedFile, let comparison = model.comparison {
            GitReadOnlyDetailView(session: session, file: file, comparison: comparison, message: model.detailMessage)
                .id(session.id)
        } else if model.isLoading || model.isLoadingFile {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(model.isLoadingFile ? L("正在读取文件…", "Reading File…") : L("正在比较来源…", "Comparing Sources…"))
                    .font(.system(size: 13)).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.needsConnection {
            ContentUnavailableView {
                Label(L("下载仓库后开始比较", "Download the Repository to Compare"), systemImage: "arrow.down.circle")
            } description: {
                Text(L("仓库会保存在 CrossDiff 的本机缓存中，之后可离线查看提交。", "The repository will be stored in CrossDiff’s local cache for offline viewing."))
            } actions: {
                Button(L("下载仓库", "Download Repository")) { Task { await model.refresh(execution: execution) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("git.connect")
            }
        } else if let message = model.detailMessage {
            ContentUnavailableView(L("无法预览此文件", "File Preview Unavailable"), systemImage: "doc.badge.ellipsis", description: Text(message))
        } else {
            ContentUnavailableView(L("选择文件查看差异", "Select a File to See Its Differences"), systemImage: "doc.text.magnifyingglass",
                                   description: Text(L("从左侧目录选择文件，对照两侧来源的内容。", "Choose a file in the sidebar to compare its contents in both sources.")))
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text(error).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Color(nsColor: theme.differenceBackground(isRemoval: true)))
        .accessibilityIdentifier("git.error")
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
            Text(model.status).lineLimit(1)
            Spacer(minLength: 4)
            if let mergeBase = model.comparison?.mergeBaseObjectID {
                Text(L("共同祖先 \(mergeBase.prefix(8))", "Merge base \(mergeBase.prefix(8))"))
                    .lineLimit(1).help(mergeBase)
            }
            if let comparison = model.comparison {
                Text("\(comparison.leftSnapshot.shortLabel) → \(comparison.rightSnapshot.shortLabel)")
                    .font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    .help("\(comparison.leftSnapshot.displayName) → \(comparison.rightSnapshot.displayName)")
            }
        }
        .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
        .padding(.horizontal, 18).frame(height: 30)
        .background(Color(nsColor: theme.chrome))
    }
}

private struct GitFileTreeRow: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let depth: Int
    let file: GitFileChange?

    private final class Folder {
        let name: String
        let path: String
        var folders: [String: Folder] = [:]
        var files: [GitFileChange] = []
        init(name: String, path: String) { self.name = name; self.path = path }
    }

    static func build(_ files: [GitFileChange]) -> [GitFileTreeRow] {
        let root = Folder(name: "", path: "")
        for file in files {
            if Task.isCancelled { return [] }
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            var folder = root
            for part in parts.dropLast() {
                let name = String(part), key = Data(part.utf8).base64EncodedString()
                if let existing = folder.folders[key] { folder = existing }
                else {
                    let child = Folder(name: name, path: folder.path.isEmpty ? name : folder.path + "/" + name)
                    folder.folders[key] = child
                    folder = child
                }
            }
            folder.files.append(file)
        }
        var rows: [GitFileTreeRow] = []
        func append(_ folder: Folder, depth: Int) {
            for child in folder.folders.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                rows.append(GitFileTreeRow(id: "folder:" + Data(child.path.utf8).base64EncodedString(), name: child.name, path: child.path, depth: depth, file: nil))
                append(child, depth: depth + 1)
            }
            for file in folder.files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                rows.append(GitFileTreeRow(id: file.id, name: String(file.path.split(separator: "/", omittingEmptySubsequences: false).last ?? ""), path: file.path, depth: depth, file: file))
            }
        }
        append(root, depth: 0)
        return rows
    }
}

@MainActor
private struct GitFileTreeView: View {
    let files: [GitFileChange]
    let selectedID: String?
    let expandAll: Bool
    let theme: ComparisonTheme
    let onSelect: (GitFileChange) -> Void
    @State private var rows: [GitFileTreeRow] = []
    @State private var collapsed: Set<String> = []

    private var visibleRows: [GitFileTreeRow] {
        guard !expandAll, !collapsed.isEmpty else { return rows }
        var hiddenDepth: Int?
        return rows.filter { row in
            if let depth = hiddenDepth {
                if row.depth > depth { return false }
                hiddenDepth = nil
            }
            if row.file == nil, collapsed.contains(row.id) { hiddenDepth = row.depth }
            return true
        }
    }

    var body: some View {
        List(selection: Binding<String?>(get: { selectedID }, set: { id in
            if let file = files.first(where: { $0.id == id }), id != selectedID { onSelect(file) }
        })) {
            ForEach(visibleRows) { row in
                HStack(spacing: 6) {
                    if row.file == nil {
                        Button {
                            if collapsed.contains(row.id) { collapsed.remove(row.id) }
                            else { collapsed.insert(row.id) }
                        } label: {
                            Image(systemName: collapsed.contains(row.id) && !expandAll ? "chevron.right" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold)).frame(width: 10, height: 20)
                        }
                        .buttonStyle(.plain).disabled(expandAll)
                        .accessibilityLabel(L("展开或收起 \(row.name)", "Expand or Collapse \(row.name)"))
                    } else { Color.clear.frame(width: 10, height: 1) }
                    Image(systemName: symbol(row.file)).frame(width: 14)
                        .foregroundStyle(Color(nsColor: row.file == nil ? theme.accent : theme.secondaryText))
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 1)
                    if let file = row.file, file.kind != .unchanged {
                        Text(marker(file.kind)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(color(file.kind)).help(file.kind.title)
                    }
                }
                .font(.system(size: 12)).padding(.leading, CGFloat(row.depth) * 12)
                .padding(.vertical, 1).contentShape(Rectangle()).help(help(row))
                .tag(row.id)
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .accessibilityLabel(row.name + (row.file.map { ", " + $0.kind.title } ?? ""))
            }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden)
        .accessibilityIdentifier("git.files.tree")
        .task(id: files) {
            let input = files
            let worker = Task.detached(priority: .userInitiated) { GitFileTreeRow.build(input) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            rows = result
        }
    }

    private func symbol(_ file: GitFileChange?) -> String {
        guard let file else { return "folder" }
        switch file.right?.kind ?? file.left?.kind {
        case .symbolicLink: return "link"
        case .submodule: return "shippingbox"
        default: return "doc.text"
        }
    }

    private func marker(_ kind: GitChangeKind) -> String {
        switch kind {
        case .added: return "A"
        case .deleted: return "D"
        case .modified: return "M"
        case .renamed: return "R"
        case .typeChanged: return "T"
        case .unchanged: return ""
        }
    }

    private func color(_ kind: GitChangeKind) -> Color {
        switch kind {
        case .added: return Color(nsColor: theme.differenceForeground(isRemoval: false))
        case .deleted: return Color(nsColor: theme.differenceForeground(isRemoval: true))
        case .unchanged: return Color(nsColor: theme.secondaryText)
        default: return Color(nsColor: theme.accent)
        }
    }

    private func help(_ row: GitFileTreeRow) -> String {
        guard let file = row.file else { return row.path }
        if file.kind == .renamed, let left = file.left, let right = file.right {
            return file.kind.title + "\n" + left.path + " → " + right.path
        }
        return file.kind.title + "\n" + row.path
    }
}
