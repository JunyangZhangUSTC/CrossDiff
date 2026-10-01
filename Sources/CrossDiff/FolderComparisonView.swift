import SwiftUI
import CrossDiffCore

public struct FolderComparisonView: View {
    let left: URL
    let right: URL
    let onOpenPair: (URL, URL) -> Void
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var model = FolderComparisonModel()
    @State private var selection = Set<String>()
    @State private var differencesOnly = true
    @State private var query = ""

    public init(left: URL, right: URL, onOpenPair: @escaping (URL, URL) -> Void) {
        self.left = left
        self.right = right
        self.onOpenPair = onOpenPair
    }

    private var entries: [FolderEntry] {
        (model.result?.entries ?? []).filter {
            (!differencesOnly || $0.status != .same) && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query))
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                rootLabel(left, title: L("左侧", "Left"))
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                rootLabel(right, title: L("右侧", "Right"))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            HStack(spacing: 12) {
                Toggle(L("仅显示差异", "Differences Only"), isOn: $differencesOnly).toggleStyle(.checkbox)
                TextField(L("筛选路径", "Filter Paths"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Button { selection.removeAll(); model.scan(left: left, right: right) } label: {
                    Label(L("重新比较", "Compare Again"), systemImage: "arrow.clockwise")
                }.disabled(model.busy)
                Button { preview(toRight: false) } label: {
                    Label(L("复制到左", "Copy to Left"), systemImage: "arrow.left")
                }.disabled(!canCopy(toRight: false))
                Button { preview(toRight: true) } label: {
                    Label(L("复制到右", "Copy to Right"), systemImage: "arrow.right")
                }.disabled(!canCopy(toRight: true))
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            Table(entries, selection: $selection) {
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
                if model.scanning {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(L("正在比较文件内容…", "Comparing file contents…")).font(.callout)
                        Button(L("取消", "Cancel")) { model.cancel() }
                    }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                } else if entries.isEmpty {
                    ContentUnavailableView(model.result == nil ? L("尚未完成比较", "Comparison Not Completed") : L("没有匹配的差异", "No Matching Differences"),
                                           systemImage: model.result == nil ? "folder" : "checkmark.circle",
                                           description: Text(model.result == nil ? L("点击重新比较开始扫描。", "Click Compare Again to start scanning.") : L("关闭差异筛选可查看相同文件。", "Turn off Differences Only to see identical files.")))
                }
            }
            Divider()
            HStack(spacing: 14) {
                if model.busy && !model.scanning { ProgressView().controlSize(.small) }
                Text(model.status).lineLimit(1).help(model.status)
                Spacer()
                if let result = model.result {
                    Text(L("已忽略 \(result.ignoredCount) 项", "Items ignored: \(result.ignoredCount)"))
                        .help(L("默认忽略 .git、.DS_Store、.build、node_modules。每个被忽略的目录计为一项，不读取其内容。", "Ignores .git, .DS_Store, .build, and node_modules by default. Each ignored folder counts as one item; its contents are not read."))
                }
                Text(L("双击文件查看差异", "Double-click a file to compare")).foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9)
        }
        .task(id: left.path + "\n" + right.path) { selection.removeAll(); model.scan(left: left, right: right) }
        .onDisappear { model.cancelScan() }
        .sheet(item: $model.preview) { plan in copyPreview(plan) }
        .alert(L("文件夹比较", "Folder Comparison"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("好", "OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error.map(localizedErrorDescription) ?? "") }
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

    private func canCopy(toRight: Bool) -> Bool {
        guard !model.busy, !selection.isEmpty, let result = model.result else { return false }
        let chosen = result.entries.filter { selection.contains($0.path) }
        return chosen.count == selection.count && chosen.allSatisfy { $0.canCopy(toRight: toRight) }
    }

    private func preview(toRight: Bool) { model.prepare(paths: selection, toRight: toRight) }
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
        case .same: return .secondary
        case .changed: return .orange
        case .leftOnly: return .blue
        case .rightOnly: return .teal
        case .unreadable, .typeMismatch: return .red
        }
    }
    private func statusIcon(_ status: FolderEntryStatus) -> String {
        switch status {
        case .same: return "equal.circle"
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

@MainActor private final class FolderComparisonModel: ObservableObject {
    @Published var result: FolderComparisonResult?
    @Published var preview: FolderCopyPlan?
    @Published var busy = false
    @Published var scanning = false
    @Published var error: Error?
    @Published private var statusText: () -> String = { L("内容比较使用逐块读取，不根据修改时间推测", "Files are compared by content, not modification date") }
    var status: String { statusText() }
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func scan(left: URL, right: URL) {
        task?.cancel()
        let current = UUID()
        generation = current
        result = nil
        busy = true; scanning = true; statusText = { L("正在读取文件内容…", "Reading file contents…") }
        task = Task {
            let worker = Task.detached(priority: .userInitiated) { try FolderComparison.scan(left: left, right: right) }
            do {
                let scanned = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard generation == current else { return }
                try Task.checkCancellation()
                result = scanned
                let changed = scanned.entries.filter { !$0.isDirectory && $0.status != .same }.count
                statusText = { L("\(scanned.entries.count) 项 · \(changed) 个文件有差异或需要处理", "Items: \(scanned.entries.count) · Files with differences or issues: \(changed)") }
            } catch is CancellationError {
                guard generation == current else { return }
                statusText = { L("已取消扫描", "Scan cancelled") }
            } catch {
                guard generation == current else { return }
                self.error = error; statusText = { L("比较未完成", "Comparison not completed") }
            }
            guard generation == current else { return }
            busy = false; scanning = false
        }
    }

    func cancel() { task?.cancel() }
    func cancelScan() { if scanning { cancel() } }

    func prepare(paths: Set<String>, toRight: Bool) {
        guard let result, !busy else { return }
        busy = true; statusText = { L("正在核验复制预览…", "Verifying files for copy preview…") }
        task = Task {
            do {
                preview = try await Task.detached(priority: .userInitiated) {
                    try FolderComparison.prepareCopy(result, paths: paths, toRight: toRight)
                }.value
                statusText = { L("请核对待复制的文件", "Review the files to be copied") }
            } catch { self.error = error; statusText = { L("无法准备复制", "Unable to prepare copy") } }
            busy = false
        }
    }

    func execute(_ plan: FolderCopyPlan, left: URL, right: URL) {
        preview = nil; busy = true; statusText = { L("正在复制文件…", "Copying files…") }
        task = Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try FolderComparison.execute(plan) }.value
                busy = false
                scan(left: left, right: right)
            } catch {
                self.error = FolderCopyFailure(underlying: error)
                statusText = { L("复制已停止，请重新比较", "Copying stopped. Compare again to check the result.") }; busy = false
            }
        }
    }
}

private struct FolderCopyFailure: LocalizedError {
    let underlying: Error
    var errorDescription: String? {
        localizedErrorDescription(underlying) + "\n" + L("已完成的复制可能已保留，请重新比较确认。", "Some files may already have been copied. Compare again to check the result.")
    }
}
