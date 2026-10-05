import SwiftUI
import CrossDiffCore

/// Git source snapshots share the native text presentation without editing or saving actions.
@MainActor
struct GitReadOnlyDetailView: View {
    @ObservedObject var session: ComparisonSession
    let file: GitFileChange
    let comparison: GitSourceComparison
    let message: String?
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var scrollLink = EditorScrollLink()

    private var theme: ComparisonTheme { ComparisonTheme(isDark: colorScheme == .dark) }
    private var canNavigate: Bool { !session.calculating && session.result?.hunks.isEmpty == false }
    private var hasLocalSource: Bool { !comparison.leftSnapshot.source.isCommit || !comparison.rightSnapshot.source.isCommit }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let message {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                    Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: theme.secondaryText))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(nsColor: theme.chrome))
                Divider()
            }
            if session.isSearchVisible {
                ComparisonSearchBar(session: session, readOnly: true)
                Divider()
            }
            HSplitView {
                sourcePane(.left).frame(minWidth: 220)
                sourcePane(.right).frame(minWidth: 220)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: theme.canvas))
        .foregroundStyle(Color(nsColor: theme.text))
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlContents(compact: false)
            controlContents(compact: true)
        }
        .font(.system(size: 12)).controlSize(.small).buttonStyle(.borderless)
        .padding(.horizontal, 14).frame(height: 42)
    }

    private func controlContents(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Label(file.kind.title, systemImage: file.kind == .renamed ? "arrow.turn.down.right" : "doc.text")
                .fontWeight(.medium).lineLimit(1)
            if session.calculating { ProgressView().controlSize(.mini) }
            else if let result = session.result {
                Text(result.hunks.isEmpty ? L("内容相同", "Identical Contents") : L("\(result.hunks.count) 处差异", "\(result.hunks.count) changes"))
                    .foregroundStyle(Color(nsColor: theme.secondaryText)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !compact {
                Picker(L("差异精度", "Difference Detail"), selection: $session.characterHighlights) {
                    Text(L("字符", "Characters")).tag(true)
                    Text(L("整行", "Lines")).tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 128).id(settings.language)
                .accessibilityIdentifier("git.detail.precision")
            }
            Button { session.showSearch() } label: { Image(systemName: "magnifyingglass") }
                .help(L("查找文件内容（⌘F）", "Find in File (⌘F)"))
                .accessibilityLabel(L("查找文件内容", "Find in File"))
                .accessibilityIdentifier("git.detail.find")
            Menu {
                if compact {
                    Toggle(L("字符差异", "Character Differences"), isOn: $session.characterHighlights)
                    Divider()
                }
                Toggle(L("自动换行", "Wrap Lines"), isOn: $session.wrapLines)
                Toggle(L("同步滚动", "Sync Scrolling"), isOn: $session.synchronizedScrolling)
                Toggle(L("对齐差异行", "Align Changed Lines"), isOn: $session.alignDifferences)
                Divider()
                Toggle(L("忽略水平空白", "Ignore Horizontal Whitespace"), isOn: $session.ignoreWhitespace)
                Toggle(L("忽略大小写", "Ignore Case"), isOn: $session.ignoreCase)
                Text(L("忽略选项仅影响此文件的文本差异，目录状态仍依据完整内容与文件模式。", "Ignore options affect this file’s text diff; file status still uses complete content and file modes."))
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .accessibilityLabel(L("文件比较选项", "File Comparison Options"))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L("文件比较选项。忽略空白或大小写只影响文本差异，不改变目录中的 Git 文件状态。", "File comparison options. Ignoring whitespace or case affects text differences, not Git file status in the sidebar."))
            .accessibilityIdentifier("git.detail.options")
        }
    }

    private func sourcePane(_ side: Side) -> some View {
        let entry = side == .left ? file.left : file.right
        let snapshot = side == .left ? comparison.leftSnapshot : comparison.rightSnapshot
        let value = session.value(side)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(side == .left ? L("左侧", "Left") : L("右侧", "Right"))
                        .foregroundStyle(Color(nsColor: theme.secondaryText))
                    Text(sourceTitle(snapshot)).lineLimit(1).truncationMode(.middle)
                        .help(sourceDescription(snapshot))
                    if let commit = snapshot.commit {
                        Text(commit.shortID).font(.system(size: 11, design: .monospaced))
                            .fixedSize().help(commit.objectID)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "lock").foregroundStyle(Color(nsColor: theme.secondaryText))
                        .help(L("只读来源快照，可选择和复制", "Read-only source snapshot; select and copy text"))
                }
                .font(.system(size: 11))
                Text(entry?.path ?? file.path)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .help(entry?.path ?? file.path).textSelection(.enabled)
            }
            .padding(.horizontal, 14).frame(height: 55)
            .background(Color(nsColor: theme.chrome))
            Divider()
            ZStack(alignment: .topLeading) {
                NativeTextEditor(text: value.text, side: side, session: session, scrollLink: scrollLink,
                                 onChange: { _ in }, readOnly: true)
                    .id(side == .left ? session.leftSourceID : session.rightSourceID)
                    .accessibilityIdentifier(side == .left ? "git.detail.left" : "git.detail.right")
                if value.text.isEmpty {
                    Text(entry == nil ? L("此来源中不存在该文件", "File absent from this source") : L("空文件", "Empty file"))
                        .font(.system(size: 12)).foregroundStyle(Color(nsColor: theme.secondaryText))
                        .padding(.leading, 64).padding(.top, 14).allowsHitTesting(false)
                }
            }
            Divider()
            HStack(spacing: 8) {
                if let entry {
                    Text(entry.mode).font(.system(size: 10, design: .monospaced))
                        .help(L("Git 文件模式", "Git File Mode"))
                    if let size = entry.size {
                        Text(ByteCountFormatStyle(style: .file, locale: settings.locale).format(Int64(size)))
                    }
                    Spacer(minLength: 2)
                    Text(String(entry.objectID.prefix(8))).font(.system(size: 10, design: .monospaced))
                        .help(L("内容标识：", "Content ID: ") + entry.objectID)
                } else {
                    Text(L("不存在", "Absent"))
                    Spacer(minLength: 2)
                }
            }
            .font(.system(size: 10)).foregroundStyle(Color(nsColor: theme.secondaryText))
            .padding(.horizontal, 14).frame(height: 25)
            .background(Color(nsColor: theme.chrome))
        }
    }

    private func sourceTitle(_ snapshot: GitComparisonSnapshot) -> String {
        if let commit = snapshot.commit,
           snapshot.displayName == commit.objectID || snapshot.displayName == commit.shortID {
            return L("提交", "Commit")
        }
        return snapshot.displayName
    }

    private func sourceDescription(_ snapshot: GitComparisonSnapshot) -> String {
        if let commit = snapshot.commit {
            return snapshot.displayName + "\n" + commit.objectID + "\n" + commit.subject
        }
        switch snapshot.source {
        case .commit: return L("仓库尚无提交，以空内容作为 HEAD 基线。", "The repository has no commits yet; HEAD uses an empty baseline.")
        case .index: return L("读取比较时的已暂存内容；刷新可读取最新暂存区。", "Staged contents read for this comparison; refresh to read the latest staging area.")
        case .workingTree: return L("读取比较时磁盘上的文件；刷新可读取最新工作区。", "Files on disk read for this comparison; refresh to read the latest working tree.")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label(L("只读", "Read Only"), systemImage: "lock")
                .foregroundStyle(Color(nsColor: theme.secondaryText))
            if hasLocalSource {
                Text(L("刷新以读取最新状态", "Refresh to read the latest state"))
                    .foregroundStyle(Color(nsColor: theme.secondaryText)).lineLimit(1)
            }
            if session.result?.simplified == true {
                Image(systemName: "info.circle")
                    .help(L("部分内容采用较粗的差异显示。", "Some content uses a simplified diff."))
            }
            Spacer(minLength: 4)
            Text(canNavigate ? L("第 \(session.selectedHunk + 1) / \(session.result?.hunks.count ?? 0) 处", "\(session.selectedHunk + 1) of \(session.result?.hunks.count ?? 0)") : "—")
                .monospacedDigit().foregroundStyle(Color(nsColor: theme.secondaryText))
            Button { session.navigate(-1) } label: { Image(systemName: "chevron.up").frame(width: 14) }
                .help(L("上一处差异", "Previous Difference"))
                .accessibilityLabel(L("上一处差异", "Previous Difference"))
                .accessibilityIdentifier("git.detail.previous").disabled(!canNavigate)
            Button { session.navigate(1) } label: { Image(systemName: "chevron.down").frame(width: 14) }
                .help(L("下一处差异", "Next Difference"))
                .accessibilityLabel(L("下一处差异", "Next Difference"))
                .accessibilityIdentifier("git.detail.next").disabled(!canNavigate)
        }
        .font(.system(size: 11)).controlSize(.small).buttonStyle(.bordered)
        .padding(.horizontal, 14).frame(height: 35)
    }
}
