import SwiftUI
import CrossDiffCore

@MainActor
struct FolderComparisonView: View {
    let left: URL
    let right: URL
    let onOpenPair: (URL, URL) -> Void
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @ObservedObject var model: FolderComparisonModel
    @State private var showingIgnoreRules = false
    @State private var ignoreDraft = ""
    private var theme: ComparisonTheme { appearance.colors }

    init(left: URL, right: URL, model: FolderComparisonModel, onOpenPair: @escaping (URL, URL) -> Void) {
        self.left = left; self.right = right; self.model = model; self.onOpenPair = onOpenPair
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                rootLabel(left, title: L("左侧", "Left"))
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                rootLabel(right, title: L("右侧", "Right"))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            controls
            Divider()
            if model.scanning { scanProgress; Divider() }
            Table(model.visibleEntries, selection: $model.selection) {
                TableColumn(L("相对路径", "Relative Path")) { entry in
                    HStack(spacing: 7) {
                        Image(systemName: icon(entry)).foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                        Text(entry.path).lineLimit(1).help(entry.path)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(entry) }
                    .contextMenu { if entry.canOpenPair { Button(L("打开文件比较", "Compare Files")) { open(entry) } } }
                }.width(min: 250, ideal: 450)
                TableColumn(L("状态", "Status")) { entry in
                    Label(entry.status.title, systemImage: statusIcon(entry.status))
                        .foregroundStyle(statusColor(entry.status))
                        .help(entry.problem ?? entry.status.title)
                }.width(130)
                TableColumn(L("左侧大小", "Left Size")) { entry in sizeLabel(entry.left) }.width(100)
                TableColumn(L("右侧大小", "Right Size")) { entry in sizeLabel(entry.right) }.width(100)
            }
            .overlay {
                if model.visibleEntries.isEmpty && !model.filtering {
                    if model.scanning && model.result == nil {
                        ContentUnavailableView(L("正在建立文件清单", "Building File Inventory"), systemImage: "folder.badge.gearshape",
                                               description: Text(L("先检查路径和大小，再核验需要比较的文件内容。", "Checking paths and sizes before verifying file contents.")))
                    } else if !model.scanning {
                        ContentUnavailableView(model.result?.isComplete == true ? L("没有匹配的差异", "No Matching Differences") : L("比较尚未完成", "Comparison Incomplete"),
                                               systemImage: model.result?.isComplete == true ? "checkmark.circle" : "folder",
                                               description: Text(model.result?.isComplete == true ? L("调整筛选条件，或关闭差异筛选查看相同文件。", "Adjust the filter, or turn off Differences Only to see identical files.") : L("点击重新比较，完成内容核验。", "Click Compare Again to finish verifying file contents.")))
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                if model.busy && !model.scanning { ProgressView().controlSize(.small) }
                Text(model.status).lineLimit(1).help(model.status)
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
        HStack(spacing: 10) {
            Toggle(L("仅显示差异", "Differences Only"), isOn: $model.differencesOnly)
                .toggleStyle(.checkbox).fixedSize().accessibilityIdentifier("folders.differences-only")
            TextField(L("筛选路径", "Filter Paths"), text: $model.query)
                .textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 220)
                .accessibilityIdentifier("folders.filter")
            Spacer(minLength: 0)
            Button {
                ignoreDraft = model.ignoredNames.sorted().joined(separator: "\n")
                showingIgnoreRules = true
            } label: { Label(L("忽略规则", "Ignore Rules"), systemImage: "line.3.horizontal.decrease.circle") }
                .disabled(model.busy).accessibilityIdentifier("folders.ignore")
                .popover(isPresented: $showingIgnoreRules, arrowEdge: .bottom) { ignoreRules }
            Button { model.scan(left: left, right: right) } label: {
                Image(systemName: "arrow.clockwise")
            }.help(L("重新比较", "Compare Again")).accessibilityLabel(L("重新比较", "Compare Again"))
                .disabled(model.busy).accessibilityIdentifier("folders.reload")
            Divider().frame(height: 18)
            Button { model.prepare(paths: model.selection, toRight: false) } label: {
                Image(systemName: "arrow.left.to.line")
            }.help(L("复制到左", "Copy to Left")).accessibilityLabel(L("复制到左", "Copy to Left"))
                .disabled(!model.canCopy(toRight: false)).accessibilityIdentifier("folders.copy-left")
            Button { model.prepare(paths: model.selection, toRight: true) } label: {
                Image(systemName: "arrow.right.to.line")
            }.help(L("复制到右", "Copy to Right")).accessibilityLabel(L("复制到右", "Copy to Right"))
                .disabled(!model.canCopy(toRight: true)).accessibilityIdentifier("folders.copy-right")
        }.controlSize(.small).buttonStyle(.bordered)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Color(nsColor: theme.chrome))
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

    private func rootLabel(_ url: URL, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.accentColor.opacity(0.8))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(title) · \(url.lastPathComponent)").font(.headline)
                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(url.path)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sizeLabel(_ snapshot: FolderSnapshot?) -> some View {
        Text(snapshot.map { $0.kind == .file ? ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: settings.locale).format($0.size) : ($0.kind == .symbolicLink ? L("符号链接", "Symbolic Link") : "—") } ?? "—")
            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
    }

    private func open(_ entry: FolderEntry) {
        guard entry.canOpenPair, let result = model.result else { return }
        onOpenPair(result.leftRoot.appendingPathComponent(entry.path), result.rightRoot.appendingPathComponent(entry.path))
    }

    private func icon(_ entry: FolderEntry) -> String {
        if entry.left?.kind == .symbolicLink || entry.right?.kind == .symbolicLink { return "link" }
        return entry.isDirectory ? "folder" : "doc.text"
    }
    private func statusColor(_ status: FolderEntryStatus) -> Color {
        switch status {
        case .same, .pending: return .secondary
        case .changed: return .orange
        case .leftOnly: return .blue
        case .rightOnly: return .teal
        case .unreadable, .typeMismatch: return .red
        }
    }
    private func statusIcon(_ status: FolderEntryStatus) -> String {
        switch status {
        case .same: return "equal.circle"
        case .pending: return "clock"
        case .changed: return "pencil.circle"
        case .leftOnly: return "arrow.left.circle"
        case .rightOnly: return "arrow.right.circle"
        case .unreadable, .typeMismatch: return "exclamationmark.triangle"
        }
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
