import SwiftUI
import CrossDiffCore

/// Observe input changes independently of the workspace's tab collection.
@MainActor
struct FolderComparisonSessionView: View {
    @ObservedObject var session: ComparisonSession
    let store: WorkspaceStore

    var body: some View {
        if let left = session.left.path, let right = session.right.path {
            FolderComparisonView(left: URL(fileURLWithPath: left), right: URL(fileURLWithPath: right),
                                 model: session.folderComparisonModel,
                                 onChooseFolder: { store.chooseFolder(for: session, side: $0) },
                                 onOpenPair: store.openPair)
        }
    }
}

@MainActor
struct FolderComparisonView: View {
    let left: URL
    let right: URL
    let onChooseFolder: (Side) -> Void
    let onOpenPair: (URL, URL) -> Void
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @ObservedObject var model: FolderComparisonModel
    @State private var showingIgnoreRules = false
    @State private var ignoreDraft = ""
    private var theme: ComparisonTheme { appearance.colors }

    init(left: URL, right: URL, model: FolderComparisonModel, onChooseFolder: @escaping (Side) -> Void, onOpenPair: @escaping (URL, URL) -> Void) {
        self.left = left; self.right = right; self.model = model
        self.onChooseFolder = onChooseFolder; self.onOpenPair = onOpenPair
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                rootLabel(left, side: .left)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                rootLabel(right, side: .right)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            controls
            Divider()
            pathBar
            Divider()
            if model.scanning { scanProgress; Divider() }
            NativeFolderComparisonTable(rows: model.browserProjection.rows,
                                        mode: model.browserMode, sort: model.effectiveSortOrder,
                                        selection: $model.selection, showModifiedDates: model.showModifiedDates,
                                        isDark: appearance.isDark,
                                        allowsExpansion: model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                        onToggleFolder: model.toggleFolder, onOpen: open, onSort: model.setSort)
            .overlay {
                if model.browserProjection.rows.isEmpty && !model.filtering {
                    if model.scanning && model.result == nil {
                        ContentUnavailableView(L("正在建立文件清单", "Building File Inventory"), systemImage: "folder.badge.gearshape",
                                               description: Text(L("先检查路径和大小，再核验需要比较的文件内容。", "Checking paths and sizes before verifying file contents.")))
                    } else if !model.scanning {
                        ContentUnavailableView(model.result?.isComplete == true ? L("没有匹配的差异", "No Matching Differences") : L("比较尚未完成", "Comparison Incomplete"),
                                               systemImage: model.result?.isComplete == true ? "checkmark.circle" : "folder",
                                               description: Text(model.result?.isComplete == true ? L("调整搜索或状态筛选，选择“全部”查看相同文件。", "Adjust the search or status filter; choose All to see identical files.") : L("点击重新比较，完成内容核验。", "Click Compare Again to finish verifying file contents.")))
                    }
                }
            }
            if !model.selection.isEmpty { selectionBar }
            Divider()
            HStack(spacing: 12) {
                if model.busy && !model.scanning { ProgressView().controlSize(.small) }
                Text(model.status).lineLimit(1).help(model.status)
                if model.displayingPreviousScan && !model.scanning {
                    Text(L("显示上次结果 · 需重新比较", "Previous results · Compare again"))
                        .foregroundStyle(Color(nsColor: theme.accent))
                }
                Spacer(minLength: 4)
                if let result = model.result {
                    Text(L("已忽略 \(result.ignoredCount) 项", "Ignored: \(result.ignoredCount)"))
                        .help(model.ignoredNames.sorted().joined(separator: ", "))
                }
                if let date = model.completedAt {
                    Text(date, format: .dateTime.hour().minute().second().locale(settings.locale))
                        .help(L("上次比较完成时间；点击重新比较以读取最新改动。", "Last comparison completed. Use Compare Again to read subsequent changes."))
                }
            }.font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText)).padding(.horizontal, 20).padding(.vertical, 9)
        }
        .background(Color(nsColor: theme.canvas))
        .foregroundStyle(Color(nsColor: theme.text))
        .tint(Color(nsColor: theme.accent))
        .task(id: [left.path, right.path]) { model.loadIfNeeded(left: left, right: right) }
        .sheet(item: $model.preview) { plan in copyPreview(plan) }
        .alert(L("文件夹比较", "Folder Comparison"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("好", "OK")) { model.error = nil }
        } message: { Text(model.error.map(localizedErrorDescription) ?? "") }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker(L("目录展示", "Folder View"), selection: $model.browserMode) {
                Text(L("目录", "Tree")).tag(FolderBrowserMode.tree)
                Text(L("列表", "List")).tag(FolderBrowserMode.list)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 116)
                .id(settings.language)
                .accessibilityIdentifier("folders.mode")
            TextField(L("搜索相对路径", "Search relative paths"), text: $model.query)
                .textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 230)
                .accessibilityIdentifier("folders.filter")
            Menu {
                ForEach(FolderBrowserFilter.allCases, id: \.self) { filter in
                    Button {
                        model.statusFilter = filter
                    } label: {
                        if model.statusFilter == filter {
                            Label("\(filterTitle(filter)) · \(model.browserProjection.counts.count(for: filter))", systemImage: "checkmark")
                        } else {
                            Text("\(filterTitle(filter)) · \(model.browserProjection.counts.count(for: filter))")
                        }
                    }
                }
            } label: {
                Label(filterTitle(model.statusFilter), systemImage: "line.3.horizontal.decrease")
            }.fixedSize().accessibilityIdentifier("folders.status-filter")
            Spacer(minLength: 0)
            Button { model.collapseAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help(L("收起全部目录", "Collapse All Folders"))
                .accessibilityLabel(L("收起全部目录", "Collapse All Folders"))
                .accessibilityIdentifier("folders.collapse-all")
                .disabled(model.browserMode != .tree || model.expandedPaths.isEmpty || !model.query.isEmpty)
            Menu {
                Toggle(L("显示修改时间", "Show Modification Dates"), isOn: $model.showModifiedDates)
                    .accessibilityIdentifier("folders.dates")
            } label: { Image(systemName: "rectangle.split.3x1") }
                .help(L("显示列", "Visible Columns"))
                .accessibilityLabel(L("显示列", "Visible Columns"))
            Button {
                ignoreDraft = model.ignoredNames.sorted().joined(separator: "\n")
                showingIgnoreRules = true
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .help(L("忽略规则", "Ignore Rules"))
                .accessibilityLabel(L("忽略规则", "Ignore Rules"))
                .disabled(model.busy).accessibilityIdentifier("folders.ignore")
                .popover(isPresented: $showingIgnoreRules, arrowEdge: .bottom) { ignoreRules }
            Button { model.scan(left: left, right: right) } label: { Image(systemName: "arrow.clockwise") }
                .help(L("重新比较", "Compare Again")).accessibilityLabel(L("重新比较", "Compare Again"))
                .disabled(model.busy).accessibilityIdentifier("folders.reload")
            Divider().frame(height: 18)
            Button { model.prepare(paths: model.selection, toRight: false) } label: { Image(systemName: "arrow.left.to.line") }
                .help(L("复制到左", "Copy to Left")).accessibilityLabel(L("复制到左", "Copy to Left"))
                .disabled(!model.canCopy(toRight: false)).accessibilityIdentifier("folders.copy-left")
            Button { model.prepare(paths: model.selection, toRight: true) } label: { Image(systemName: "arrow.right.to.line") }
                .help(L("复制到右", "Copy to Right")).accessibilityLabel(L("复制到右", "Copy to Right"))
                .disabled(!model.canCopy(toRight: true)).accessibilityIdentifier("folders.copy-right")
        }.controlSize(.small).buttonStyle(.bordered)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(nsColor: theme.chrome))
    }

    private var pathBar: some View {
        HStack(spacing: 7) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(model.scopePath.isEmpty).help(L("上一级", "Parent Folder"))
                .accessibilityLabel(L("上一级", "Parent Folder"))
                .accessibilityIdentifier("folders.up")
            Button(L("全部目录", "All Folders")) { model.openFolder("") }
                .accessibilityIdentifier("folders.root")
            if !model.scopePath.isEmpty {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color(nsColor: theme.secondaryText))
                Text(model.scopePath).lineLimit(1).truncationMode(.middle).help(model.scopePath)
            }
            Spacer(minLength: 12)
            if model.filtering { ProgressView().controlSize(.mini) }
            Text(L("\(model.browserProjection.counts.count(for: .differences)) 项需关注 · \(model.browserProjection.counts.total) 项",
                   "\(model.browserProjection.counts.count(for: .differences)) to review · \(model.browserProjection.counts.total) items"))
                .monospacedDigit().foregroundStyle(Color(nsColor: theme.secondaryText))
                .help(L("统计当前目录及其子目录；不重复计算父目录。折叠不会改变数量。", "Counts this folder and its descendants without counting ancestors twice. Collapsing does not change totals."))
        }.font(.system(size: 11)).buttonStyle(.plain).controlSize(.small)
            .padding(.horizontal, 18).padding(.vertical, 8)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.selection.count == 1 ? "doc.text.magnifyingglass" : "doc.on.doc")
                .foregroundStyle(Color(nsColor: theme.secondaryText))
            if model.selection.count == 1, let path = model.selection.first {
                Text(path).lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
            } else {
                Text(L("已选择 \(model.selection.count) 项", "\(model.selection.count) items selected"))
            }
            Spacer(minLength: 8)
            Text(L("双击目录进入 · 双击文件比较", "Double-click a folder to browse, a file to compare"))
                .foregroundStyle(Color(nsColor: theme.secondaryText)).lineLimit(1)
        }.font(.system(size: 11)).padding(.horizontal, 18).padding(.vertical, 9)
            .background(Color(nsColor: theme.chrome))
    }

    private func filterTitle(_ filter: FolderBrowserFilter) -> String {
        switch filter {
        case .all: return L("全部", "All")
        case .differences: return L("需关注", "To Review")
        case .changed: return L("内容改动", "Modified")
        case .leftOnly: return L("仅左侧", "Left Only")
        case .rightOnly: return L("仅右侧", "Right Only")
        case .issues: return L("问题", "Issues")
        case .pending: return L("待校验", "Pending")
        }
    }

    private var scanProgress: some View {
        HStack(spacing: 12) {
            if let progress = model.progress, progress.stage == .comparing {
                ProgressView(value: Double(progress.completedPairs), total: Double(max(1, progress.totalPairs)))
                    .frame(width: 120)
                Text(L("校验内容 \(progress.completedPairs) / \(progress.totalPairs)", "Verifying contents \(progress.completedPairs) / \(progress.totalPairs)"))
                    .monospacedDigit()
                Text(ByteCountFormatStyle(style: .file, locale: settings.locale).format(progress.bytesRead))
                    .foregroundStyle(Color(nsColor: theme.secondaryText))
                    .help(L("本次已读取的文件内容", "File contents read during this comparison"))
            } else {
                ProgressView().controlSize(.small)
                Text(L("扫描目录 · 已发现 \(model.progress?.discoveredItems ?? 0) 项", "Scanning folders · \(model.progress?.discoveredItems ?? 0) items found"))
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            if model.displayingPreviousScan {
                Text(L("显示上次结果", "Showing previous results")).foregroundStyle(Color(nsColor: theme.secondaryText))
            } else if model.sortOrder.key == .status {
                Text(L("校验后按状态排序", "Status sorting after verification")).foregroundStyle(Color(nsColor: theme.secondaryText))
            }
            Button(L("取消", "Cancel")) { model.cancel() }
                .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("folders.cancel")
        }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 10)
            .background(Color(nsColor: theme.accent).opacity(0.06))
    }

    private var draftNames: [String] {
        ignoreDraft.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var validDraft: Bool { draftNames.allSatisfy { !$0.contains("/") && $0 != "." && $0 != ".." } }
    private var ignoreRules: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("忽略规则", "Ignore Rules")).font(.headline)
            Text(L("仅用于当前比较。每行一个完整文件名或文件夹名，在任意层级精确匹配；不使用通配符或路径。", "For this comparison only. Enter one exact file or folder name per line, matched at any depth. Wildcards and paths are not supported."))
                .font(.caption).foregroundStyle(Color(nsColor: theme.secondaryText)).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $ignoreDraft).font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden).padding(6).frame(height: 135)
                .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: theme.separator)))
                .accessibilityIdentifier("folders.ignore.names")
            if !validDraft {
                Text(L("请输入名称，不要使用路径、. 或 ..。", "Enter names without paths, . or .. ."))
                    .font(.caption).foregroundStyle(Color(nsColor: theme.differenceForeground(isRemoval: true)))
            }
            HStack {
                Button(L("恢复默认", "Restore Defaults")) { ignoreDraft = FolderComparison.ignoredNames.sorted().joined(separator: "\n") }
                Spacer()
                Button(L("取消", "Cancel")) { showingIgnoreRules = false }
                Button(L("应用并比较", "Apply & Compare")) {
                    model.applyIgnoredNames(Set(draftNames), left: left, right: right)
                    showingIgnoreRules = false
                }.disabled(!validDraft).keyboardShortcut(.defaultAction).accessibilityIdentifier("folders.ignore.apply")
            }.controlSize(.small)
        }.padding(20).frame(width: 390)
            .background(Color(nsColor: theme.canvas)).foregroundStyle(Color(nsColor: theme.text))
            .preferredColorScheme(appearance.isDark ? .dark : .light)
    }

    private func rootLabel(_ url: URL, side: Side) -> some View {
        let title = side == .left ? L("左侧", "Left") : L("右侧", "Right")
        let action = side == .left ? L("更换左侧文件夹", "Change Left Folder") : L("更换右侧文件夹", "Change Right Folder")
        return HStack(spacing: 10) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.accentColor.opacity(0.8))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(title) · \(url.lastPathComponent)").font(.headline)
                    .lineLimit(1).truncationMode(.middle).help(url.lastPathComponent)
                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(url.path)
            }
            Spacer(minLength: 0)
            Button { onChooseFolder(side) } label: {
                Label(L("更换…", "Change…"), systemImage: "folder")
            }
            .buttonStyle(.bordered).controlSize(.small).fixedSize()
            .disabled(!model.canReplaceRoots)
            .help(action).accessibilityLabel(action)
            .accessibilityIdentifier(side == .left ? "folders.replace-left" : "folders.replace-right")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open(_ entry: FolderEntry) {
        if entry.isDirectory { model.openFolder(entry.path); return }
        guard entry.canOpenPair, let result = model.displayedResult else { return }
        onOpenPair(result.leftRoot.appendingPathComponent(entry.path), result.rightRoot.appendingPathComponent(entry.path))
    }

    private func copyPreview(_ plan: FolderCopyPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("确认复制 \(plan.actions.count) 个文件", plan.actions.count == 1 ? "Confirm Copying 1 File" : "Confirm Copying \(plan.actions.count) Files")).font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text(L("从：\(plan.sourceRoot.path)", "From: \(plan.sourceRoot.path)"))
                Text(L("到：\(plan.targetRoot.path)", "To: \(plan.targetRoot.path)"))
            }.font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text(L("新增 \(plan.actions.filter { $0.operation == .add }.count) 项 · 覆盖 \(plan.actions.filter { $0.operation == .overwrite }.count) 项", "Add: \(plan.actions.filter { $0.operation == .add }.count) · Overwrite: \(plan.actions.filter { $0.operation == .overwrite }.count)"))
                .font(.headline)
            List(plan.actions) { action in
                HStack {
                    Text(action.path).lineLimit(1).truncationMode(.middle).help(action.path)
                    Spacer()
                    Text(action.operation.title).foregroundStyle(action.operation == .overwrite ? .orange : .green)
                }
            }.frame(minHeight: 180)
            Text(L("将立即写入目标文件夹。执行前会重新检查文件是否变化；符号链接不会被复制。中途出错时，已完成的复制会保留。", "This writes to the destination folder immediately. Files are checked again for changes before copying. Symbolic links are not copied. If an error occurs, completed copies are kept."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("取消", "Cancel"), role: .cancel) { model.preview = nil }.keyboardShortcut(.cancelAction)
                Button(L("确认复制", "Copy Files")) { model.execute(plan, left: left, right: right) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580, height: 450)
    }
}
