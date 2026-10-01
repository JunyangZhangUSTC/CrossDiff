import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CrossDiffCore

@main
struct CrossDiffApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppSettings.shared
        #if !CROSSDIFF_UI_CHECKS
        NSApp.setActivationPolicy(.regular)
        #endif
        let controller = MainWindowController()
        mainWindowController = controller
        NativeMenuController.shared.registerComparisonWindow(controller.window!)
        NativeMenuController.shared.install()
        controller.showWindow(nil)
        #if !CROSSDIFF_UI_CHECKS
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #endif
        #if CROSSDIFF_UI_CHECKS
        NativeUIRenderChecks.start()
        #endif
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = WorkspaceStore.shared
        if store.persistNow() { return .terminateNow }
        let alert = NSAlert(); alert.messageText = L("会话尚未保存，仍要退出吗？", "Session Not Saved. Quit Anyway?")
        alert.informativeText = store.message ?? L("请先将重要文本另存为文件。", "Save important text to a file before quitting.")
        alert.addButton(withTitle: L("取消退出", "Cancel")); alert.addButton(withTitle: L("仍然退出", "Quit Anyway"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func application(_ application: NSApplication, open urls: [URL]) { WorkspaceStore.shared.accept(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct WorkspaceView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var appearance = AppAppearance.shared
    private var theme: ComparisonTheme { appearance.colors }

    var body: some View {
        VStack(spacing: 0) {
            if store.sessions.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.sessions) { session in
                            SessionTab(session: session, selected: store.selectedID == session.id, select: { store.selectedID = session.id }, close: { store.close(session) })
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 7)
                }.background(Color(nsColor: theme.chrome))
                Divider()
            }
            if let session = store.selected {
                switch session.kind {
                case .text: TextComparisonView(session: session, store: store).id(session.id)
                case .folder:
                    if let l = session.left.path, let r = session.right.path {
                        FolderComparisonView(left: URL(fileURLWithPath: l), right: URL(fileURLWithPath: r), onOpenPair: store.openPair).id(session.id)
                    }
                case .image:
                    if let l = session.left.path, let r = session.right.path {
                        ImageComparisonView(left: URL(fileURLWithPath: l), right: URL(fileURLWithPath: r)).id(session.id)
                    }
                }
            }
        }
        .background(Color(nsColor: theme.canvas))
        .foregroundStyle(Color(nsColor: theme.text))
        .tint(Color(nsColor: theme.accent))
        .preferredColorScheme(appearance.isDark ? .dark : .light)
        .onAppear { appearance.apply() }
        .environment(\.locale, settings.locale)
        .sheet(isPresented: $store.pairing) { PairingView(store: store) }
        .alert("CrossDiff", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button(L("好", "OK")) { store.message = nil }
        } message: { Text(store.message ?? "") }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                            if let url = value as? URL { continuation.resume(returning: url) }
                            else if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                            else { continuation.resume(returning: nil) }
                        }
                    }
                    if let url { urls.append(url) }
                }
                store.accept(urls)
            }
            return true
        }
    }
}

struct SessionTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var session: ComparisonSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: session.kind.symbol)
                    Text(session.title).lineLimit(1).truncationMode(.middle)
                    if session.dirty { Circle().fill(.secondary).frame(width: 5, height: 5) }
                }
            }.buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }.buttonStyle(.plain).help(L("关闭比较", "Close Comparison"))
        }
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: 320).help(session.title)
    }
}

struct PairingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var store: WorkspaceStore
    @State private var leftID = ""
    @State private var rightID = ""
    @State private var pairs: [PendingPair] = []
    private var left: OpenCandidate? { store.candidates.first { $0.id == leftID } }
    private var right: OpenCandidate? { store.candidates.first { $0.id == rightID } }
    private var valid: Bool { left != nil && right != nil && leftID != rightID && left?.kind == right?.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(L("配对比较", "Pair Comparisons")).font(.title2.bold()); Spacer(); Button(L("添加项目…", "Add Items…")) { store.addCandidates() } }
            Text(L("为每组比较指定左侧和右侧。每一组将在独立标签页中打开。", "Choose the left and right items for each pair. Each pair opens in its own tab."))
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                picker(L("左侧", "Left"), selection: $leftID, candidates: store.candidates)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                picker(L("右侧", "Right"), selection: $rightID, candidates: store.candidates.filter { $0.id != leftID && (left == nil || $0.kind == left?.kind) })
            }
            Button(L("加入比较", "Add Pair")) {
                if let left, let right, valid {
                    if !pairs.contains(where: { $0.left.id == leftID && $0.right.id == rightID }) { pairs.append(.init(left: left, right: right)) }
                    leftID = ""; rightID = ""
                }
            }.disabled(!valid)
            if pairs.isEmpty {
                Text(store.candidates.count == 1 ? L("已选择一个项目，添加另一个项目后即可配对。", "One item selected. Add another item to create a pair.") : L("文件只能与兼容文件配对；文件夹与文件夹配对。", "Pair compatible files with each other, or a folder with another folder."))
                    .foregroundStyle(.secondary).font(.callout).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List {
                    ForEach(pairs) { pair in
                        HStack { Label(pair.left.name, systemImage: pair.left.kind.symbol); Text("↔").foregroundStyle(.secondary); Text(pair.right.name); Spacer(); Button { pairs.removeAll { $0.id == pair.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help(L("移除配对", "Remove Pair")).accessibilityLabel(L("移除配对", "Remove Pair")) }
                    }
                }.frame(height: 170)
            }
            HStack {
                Text(L("已选 \(store.candidates.count) 个项目", "\(store.candidates.count) \(store.candidates.count == 1 ? "item" : "items") selected")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("取消", "Cancel")) { store.pairing = false }.keyboardShortcut(.cancelAction)
                Button(L("打开 \(pairs.count) 个比较", "Open \(pairs.count) \(pairs.count == 1 ? "Comparison" : "Comparisons")")) { store.openPairs(pairs) }.keyboardShortcut(.defaultAction).disabled(pairs.isEmpty)
            }
        }
        .padding(24).frame(width: 650)
        .onChange(of: leftID) { _, _ in if right?.kind != left?.kind || rightID == leftID { rightID = "" } }
    }
    private func picker(_ title: String, selection: Binding<String>, candidates: [OpenCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Picker(title, selection: selection) {
                Text(L("选择项目…", "Choose an Item…")).tag("")
                ForEach(candidates) { candidate in Text(candidate.name).tag(candidate.id) }
            }.labelsHidden().frame(maxWidth: .infinity)
            if let candidate = store.candidates.first(where: { $0.id == selection.wrappedValue }) {
                Text(candidate.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(candidate.url.path)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct TextComparisonView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var session: ComparisonSession
    @ObservedObject var store: WorkspaceStore
    @StateObject private var scrollLink = EditorScrollLink()
    @Environment(\.colorScheme) private var colorScheme

    private var theme: ComparisonTheme { ComparisonTheme(isDark: colorScheme == .dark) }
    private var ink: Color { Color(nsColor: theme.text) }
    private var secondaryInk: Color { Color(nsColor: theme.secondaryText) }
    private var separator: some View { Rectangle().fill(Color(nsColor: theme.separator)).frame(height: 0.5) }
    private var canMerge: Bool { !session.calculating && session.result?.hunks.isEmpty == false }
    private var differenceCount: Int { session.result?.hunks.count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            comparisonBar
            separator
            if session.isSearchVisible {
                ComparisonSearchBar(session: session)
                separator
            }
            HSplitView {
                sourcePane(.left).frame(minWidth: 300)
                sourcePane(.right).frame(minWidth: 300)
            }
            separator
            comparisonFooter
        }
        .foregroundStyle(ink)
        .background(Color(nsColor: theme.canvas))
    }

    private var comparisonBar: some View {
        ViewThatFits(in: .horizontal) {
            comparisonControls(compact: false)
            comparisonControls(compact: true)
        }
        .font(.system(size: 12)).lineLimit(1).controlSize(.small)
        .padding(.horizontal, 18).frame(height: 44)
        .background(Color(nsColor: theme.canvas))
    }

    private func comparisonControls(compact: Bool) -> some View {
        HStack(spacing: compact ? 9 : 14) {
            Group {
                if compact { Image(systemName: "arrow.left.arrow.right").help(L("文本比较", "Text Comparison")) }
                else { Label(L("文本比较", "Text Comparison"), systemImage: "arrow.left.arrow.right") }
            }.font(.system(size: 13, weight: .medium)).fixedSize()
            if session.calculating {
                ProgressView().controlSize(.mini).accessibilityLabel(L("正在比较", "Comparing"))
            } else if let result = session.result {
                Text(result.hunks.isEmpty ? (session.left.text.isEmpty && session.right.text.isEmpty ? L("等待输入", "Ready for Input") : L("内容相同", "Identical")) : L("\(result.hunks.count) 处差异", "\(result.hunks.count) \(result.hunks.count == 1 ? "change" : "changes")"))
                    .font(.system(size: 12)).foregroundStyle(secondaryInk).fixedSize()
            }
            Spacer(minLength: 12)
            Toggle(L("显示删除", "Show Deletions"), isOn: $session.showDeletions)
                .toggleStyle(.button).buttonStyle(.bordered).fixedSize()
                .help(L("在右侧预览已删除的文字，以红色删除线显示；关闭后可继续编辑。保存仍使用右侧原文。", "Preview deleted text on the right with a red strikethrough. Turn off to resume editing. Saving always uses the original right-side text."))
                .accessibilityLabel(L("显示删除内容", "Show Deleted Text"))
            Picker(L("差异精度", "Difference Detail"), selection: $session.characterHighlights) {
                Text(L("字符", "Characters")).tag(true)
                Text(L("整行", "Lines")).tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 128)
            .accessibilityLabel(L("差异精度", "Difference Detail")).help(L("突出字符差异或仅标记整行", "Highlight character changes or whole lines"))
            Divider().frame(height: 16)
            Toggle(L("同步滚动", compact ? "Sync" : "Sync Scrolling"), isOn: $session.synchronizedScrolling)
                .toggleStyle(.checkbox).fixedSize()
            Menu {
                Toggle(L("对齐差异行", "Align Changed Lines"), isOn: $session.alignDifferences)
                Divider()
                Toggle(L("忽略水平空白", "Ignore Horizontal Whitespace"), isOn: $session.ignoreWhitespace)
                Toggle(L("忽略大小写", "Ignore Case"), isOn: $session.ignoreCase)
                Divider()
                Toggle(L("自动换行", "Wrap Lines"), isOn: $session.wrapLines)
                Divider()
                Button(L("查找…", "Find…")) { session.showSearch() }
            } label: {
                if compact { Image(systemName: "slider.horizontal.3").accessibilityLabel(L("选项", "Options")) }
                else { Label(L("选项", "Options"), systemImage: "slider.horizontal.3") }
            }
            .menuStyle(.borderlessButton).fixedSize().help(L("比较选项", "Comparison Options"))
            Divider().frame(height: 16)
            Button {
                if session.canRestoreClearedText { session.restoreClearedText() }
                else { session.clearText() }
            } label: {
                Label(session.canRestoreClearedText ? L("撤销清空", "Undo Clear") : L("清空两侧", "Clear Both"),
                      systemImage: session.canRestoreClearedText ? "arrow.uturn.backward" : "eraser")
                    .padding(.horizontal, 5).frame(height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.borderless).fixedSize()
            .foregroundStyle(session.canRestoreClearedText ? Color(nsColor: theme.accent) : secondaryInk)
            .disabled(!session.canClearText && !session.canRestoreClearedText)
            .help(session.canRestoreClearedText ? L("恢复刚才清空的两侧文本", "Restore both texts from before clearing") : L("清空当前比较的两侧文本，可撤销；手动保存后才修改原文件", "Clear both texts in this comparison. You can undo this; files change only when you save."))
            .accessibilityIdentifier("clear-comparison-text")
        }
    }

    private var comparisonFooter: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: theme.differenceForeground(isRemoval: true))).frame(width: 7, height: 7)
                Text(L("删除", "Deleted"))
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: theme.differenceForeground(isRemoval: false))).frame(width: 7, height: 7).padding(.leading, 5)
                Text(L("新增", "Added"))
            }.foregroundStyle(secondaryInk).fixedSize()
            if session.result?.simplified == true {
                Image(systemName: "info.circle").foregroundStyle(.orange)
                    .help(L("此比较部分采用较粗的差异显示，合并仍保留完整原文。", "Some changes use a simplified diff. Merging still preserves the full source text."))
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text(canMerge ? L("第 \(session.selectedHunk + 1) / \(differenceCount) 处", "\(session.selectedHunk + 1) of \(differenceCount)") : "—")
                    .monospacedDigit().foregroundStyle(secondaryInk).padding(.trailing, 4)
                Button { session.navigate(-1) } label: { Image(systemName: "chevron.up").frame(width: 14) }
                    .help(L("上一处差异（⌥⌘↑）", "Previous Difference (⌥⌘↑)")).accessibilityLabel(L("上一处差异", "Previous Difference"))
                Button { session.navigate(1) } label: { Image(systemName: "chevron.down").frame(width: 14) }
                    .help(L("下一处差异（⌥⌘↓）", "Next Difference (⌥⌘↓)")).accessibilityLabel(L("下一处差异", "Next Difference"))
            }.disabled(!canMerge).fixedSize()
            Divider().frame(height: 18)
            HStack(spacing: 8) {
                Button { session.merge(fromLeft: false) } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.left"); Text(L("合并到左侧", "Merge Left")) }
                }.help(L("将当前差异块从右侧复制到左侧；手动保存后才写入文件", "Copy this change from right to left. Files change only when you save."))
                Button { session.merge(fromLeft: true) } label: {
                    HStack(spacing: 6) { Text(L("合并到右侧", "Merge Right")); Image(systemName: "arrow.right") }
                }.help(L("将当前差异块从左侧复制到右侧；手动保存后才写入文件", "Copy this change from left to right. Files change only when you save."))
            }.disabled(!canMerge).fixedSize()
        }
        .font(.system(size: 12)).lineLimit(1).controlSize(.small).buttonStyle(.bordered)
        .padding(.horizontal, 16).frame(height: 40).background(Color(nsColor: theme.canvas))
    }

    private func sourcePane(_ side: Side) -> some View {
        let value = session.value(side)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(side == .left ? L("左侧", "Left") : L("右侧", "Right"))
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryInk)
                    .frame(width: 29, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? (side == .left ? L("原始文本", "Original Text") : L("修改后文本", "Modified Text")))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                    Text(value.path ?? L("临时文本", "Scratch Text"))
                        .font(.system(size: 11)).foregroundStyle(secondaryInk)
                }
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                .help(value.path ?? L("临时文本仅保存在本机", "Scratch text is stored only on this Mac"))
                if !value.text.utf16.elementsEqual(value.savedText.utf16) {
                    Circle().fill(Color(nsColor: theme.accent)).frame(width: 5, height: 5).help(L("尚未保存到文件", "Unsaved Changes"))
                }
                HStack(spacing: 8) {
                    Button { store.chooseTextFile(for: session, side: side) } label: { Image(systemName: "folder").frame(width: 16, height: 20) }
                        .help(L("打开此侧文件", "Open a File on This Side")).accessibilityLabel(side == .left ? L("打开左侧文件", "Open Left File") : L("打开右侧文件", "Open Right File"))
                    Button { store.save(session, side: side) } label: { Image(systemName: "square.and.arrow.down").frame(width: 16, height: 20) }
                        .help(L("保存此侧", "Save This Side")).accessibilityLabel(side == .left ? L("保存左侧", "Save Left") : L("保存右侧", "Save Right"))
                }.buttonStyle(.borderless).foregroundStyle(ink).fixedSize()
            }
            .padding(.horizontal, 18).frame(height: 52).background(Color(nsColor: theme.canvas))
            separator
            ZStack(alignment: .topLeading) {
                NativeTextEditor(text: value.text, side: side, session: session, scrollLink: scrollLink, onChange: { session.setText($0, side: side) })
                    .id(side == .left ? session.leftSourceID : session.rightSourceID)
                    .opacity(side == .right && session.showDeletions ? 0 : 1)
                    .allowsHitTesting(!(side == .right && session.showDeletions))
                    .accessibilityHidden(side == .right && session.showDeletions)
                if side == .right && session.showDeletions {
                    NativeDeletionPreview(session: session, scrollLink: scrollLink)
                    if session.deletionPreview == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("正在更新预览…", "Updating preview…")).font(.system(size: 12)).foregroundStyle(secondaryInk)
                        }.padding(.leading, 67).padding(.top, 14)
                    }
                } else if value.text.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(side == .left ? L("在左侧粘贴原始文本", "Paste original text on the left") : L("在右侧粘贴修改后的文本", "Paste modified text on the right")).font(.system(size: 13))
                        Text(L("也可以打开文件进行比较", "You can also open files to compare")).font(.system(size: 11))
                    }
                    .foregroundStyle(secondaryInk).padding(.leading, 67).padding(.top, 14)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            HStack {
                Text(value.encoding.displayName)
                if side == .right && session.showDeletions {
                    Text(L("含删除预览 · 关闭后可编辑", "Deletion preview · Turn off to edit")).lineLimit(1)
                }
                Spacer()
                if side == .right && session.showDeletions {
                    Menu(L("复制", "Copy")) {
                        Button(L("复制右侧全部原文", "Copy All Right-Side Source Text")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.right.text, forType: .string)
                        }
                        Button(L("复制全部含修订内容", "Copy All with Revisions")) {
                            guard let projection = session.deletionPreview else { return }
                            let text = PreviewCopy.revisionText(from: projection, selection: NSRange(location: 0, length: projection.text.utf16.count))
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }.disabled(session.deletionPreview == nil)
                    }.menuStyle(.borderlessButton).fixedSize()
                        .help(L("选区复制请使用右键；⌘C 仅复制原文，排除删除标记", "Right-click to copy a selection. ⌘C copies source text without deleted text."))
                }
                Text(L("\(value.text.count.formatted()) 字符", "\(value.text.count.formatted()) \(value.text.count == 1 ? "character" : "characters")")).monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(secondaryInk)
            .padding(.horizontal, 18).frame(height: 24).background(Color(nsColor: theme.canvas))
        }
    }
}
