import AppKit
import SwiftUI

private final class ScrollGeometryTextView: NSTextView {
    override var inputContext: NSTextInputContext? { nil }
}

@main
@MainActor
struct ScrollGeometryCheckApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 750),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "CrossDiff scroll geometry checks"
        window.toolbar = NSToolbar(identifier: "ScrollGeometryChecks")
        window.toolbarStyle = .unifiedCompact
        window.contentView = NSHostingView(rootView: ScrollGeometryCheckContent())
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
        ScrollGeometryChecks.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ScrollGeometryChecks.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            fputs("Scroll geometry checks timed out.\n", stderr)
            exit(3)
        }
        app.run()
    }
}

private struct ScrollGeometryCheckContent: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Comparison controls").frame(maxWidth: .infinity).frame(height: 44)
            HSplitView {
                pane(0)
                pane(1)
            }
            Text("Merge controls").frame(maxWidth: .infinity).frame(height: 42)
        }
        .toolbar { ToolbarItem(placement: .navigation) { Button("Open…") {} } }
    }
    private func pane(_ side: Int) -> some View {
        VStack(spacing: 0) {
            Text(side == 0 ? "Left source" : "Right source").frame(height: 56)
            Rectangle().frame(height: 2)
            ScrollGeometryEditor(side: side)
            Text("UTF-8").frame(height: 26)
        }.frame(minWidth: 300)
    }
}

@MainActor
private struct ScrollGeometryEditor: NSViewRepresentable {
    let side: Int
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager(); storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container); container.lineFragmentPadding = 0
        let editor = ScrollGeometryTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), textContainer: container)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.isRichText = false; editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        editor.textContainerInset = NSSize(width: 15, height: 12)
        editor.string = ScrollGeometryChecks.shortText
        let scroll: NSScrollView = ScrollGeometryChecks.baseline ? NSScrollView() : ComparisonScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.documentView = editor
        container.widthTracksTextView = true
        let ruler = NSRulerView(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = editor; ruler.ruleThickness = 52
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        ScrollGeometryChecks.editors[side] = editor
        ScrollGeometryChecks.scrolls[side] = scroll
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: editor.frame.height))
        editor.textContainer?.containerSize = NSSize(width: max(0, scroll.contentSize.width - 30),
                                                    height: CGFloat.greatestFiniteMagnitude)
    }
}

@MainActor
private enum ScrollGeometryChecks {
    static let baseline = CommandLine.arguments.dropFirst().contains("baseline")
    static let shortText = "Alpha old\nSecond line\n文本对比：原始版本"
    static var editors: [Int: NSTextView] = [:]
    static var scrolls: [Int: NSScrollView] = [:]
    static var failures: [String] = []
    static var window: NSWindow?

    static func start() {
        guard editors.count == 2, let window = NSApp.windows.first(where: { $0.contentView != nil }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { start() }; return
        }
        Self.window = window
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
        resize(width: 1220, height: 790) {
            checkShort("initial 1220")
            resize(width: 860, height: 580) {
                checkShort("resized 860")
                for scroll in scrolls.values { scroll.rulersVisible = false; scroll.rulersVisible = true }
                settle {
                    checkShort("ruler reinstalled")
                    resize(width: 1220, height: 790) {
                        checkShort("restored 1220")
                        checkLongText()
                    }
                }
            }
        }
    }

    static func checkShort(_ context: String) {
        for side in [0, 1] {
            guard let editor = editors[side], let scroll = scrolls[side],
                  let layout = editor.layoutManager, let container = editor.textContainer else { continue }
            // This is the valid top position used by linked difference
            // navigation. A negative document origin must not hide line one.
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            layout.ensureLayout(for: container)
            let visible = editor.visibleRect
            let first = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
                .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            check(abs(editor.frame.minY) < 0.5, "\(context), side \(side): negative document origin \(editor.frame.minY)")
            check(first.minY >= visible.minY - 0.5 && first.maxY <= visible.maxY + 0.5,
                  "\(context), side \(side): first line clipped; visible=\(visible), first=\(first)")
            if let ruler = scroll.verticalRulerView, scroll.rulersVisible {
                let firstInScroll = editor.convert(first, to: scroll)
                check(firstInScroll.minX >= ruler.frame.maxX - 0.5,
                      "\(context), side \(side): ruler overlaps first text column")
            }
            check(editor.frame.height + 0.5 >= scroll.contentView.bounds.height,
                  "\(context), side \(side): document shorter than viewport")
            check(editor.string == shortText, "\(context): layout changed source text: \(editor.string.debugDescription)")
            print("\(context) side \(side): document=\(editor.frame), clip=\(scroll.contentView.bounds), visible=\(visible)")
        }
    }

    static func checkLongText() {
        for side in [0, 1] {
            let editor = editors[side]!, scroll = scrolls[side]!
            editor.string = (0..<300).map { "Line \($0): " + String(repeating: "word 文本 ", count: 20) }.joined(separator: "\n")
            editor.layoutManager!.ensureLayout(for: editor.textContainer!)
            editor.sizeToFit()
            scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 650)); scroll.reflectScrolledClipView(scroll.contentView)
            editor.setSelectedRange(NSRange(location: 500, length: 4))
        }
        settle {
            let positions = scrolls.mapValues { $0.contentView.bounds.minY }
            resize(width: 860, height: 580) {
                for side in [0, 1] {
                    let editor = editors[side]!, scroll = scrolls[side]!
                    check(abs(scroll.contentView.bounds.minY - positions[side]!) < 1,
                          "long text side \(side): resize reset scroll \(positions[side]!) → \(scroll.contentView.bounds.minY)")
                    check(editor.selectedRange() == NSRange(location: 500, length: 4), "resize changed selection")
                    editor.isHorizontallyResizable = true; editor.autoresizingMask = []
                    editor.textContainer!.widthTracksTextView = false
                    editor.textContainer!.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                                 height: CGFloat.greatestFiniteMagnitude)
                    editor.sizeToFit(); scroll.hasHorizontalScroller = true; scroll.needsLayout = true
                    scroll.layoutSubtreeIfNeeded()
                    scroll.contentView.scroll(to: NSPoint(x: 120, y: 650)); scroll.reflectScrolledClipView(scroll.contentView)
                }
                settle {
                    for side in [0, 1] {
                        let editor = editors[side]!, scroll = scrolls[side]!
                        let previous = scroll.contentView.bounds.origin
                        scroll.tile(); scroll.layoutSubtreeIfNeeded()
                        check(abs(scroll.contentView.bounds.minX - previous.x) < 1 && abs(scroll.contentView.bounds.minY - previous.y) < 1,
                              "unwrapped long text side \(side): layout reset scroll position")
                        check(editor.selectedRange() == NSRange(location: 500, length: 4), "layout changed selection")
                    }
                    finish()
                }
            }
        }
    }

    static func resize(width: CGFloat, height: CGFloat, then action: @escaping @MainActor @Sendable () -> Void) {
        window?.setFrame(NSRect(x: -10000, y: -10000, width: width, height: height), display: true)
        window?.contentView?.needsLayout = true; window?.contentView?.layoutSubtreeIfNeeded()
        settle(action)
    }
    static func settle(_ action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: action)
    }
    static func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message); print("FAIL: \(message)") } }
    static func finish() {
        if failures.isEmpty { print("PASS: short-text first lines, ruler/resize layout, long wrapped/unwrapped scrolling, and selection preservation.") }
        else { print("FAIL: \(failures.count) scroll geometry checks failed.") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
