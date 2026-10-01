import AppKit
import CrossDiffCore

final class PreviewTextView: NSTextView {
    #if CROSSDIFF_UI_CHECKS
    // Isolated checks exercise text clients directly, without attaching the user's IME.
    override var inputContext: NSTextInputContext? { nil }
    #endif
    var projection: DeletionPreview?
    var comparisonTheme: ComparisonTheme = .light
    lazy var navigationIndicator = TextNavigationIndicator(editor: self)
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        navigationIndicator.draw(in: dirtyRect, theme: comparisonTheme)
    }
    var becameFocused: (() -> Void)?
    override var undoManager: UndoManager? { nil }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { becameFocused?() }
        return result
    }

    override func copy(_ sender: Any?) { copySource(sender) }

    @objc func copySource(_ sender: Any?) {
        guard let projection else { return }
        let value = PreviewCopy.sourceText(from: projection, selection: selectedRange())
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc func copyRevisions(_ sender: Any?) {
        guard let representation = revisionRepresentation() else { return }
        let item = NSPasteboardItem()
        item.setString(representation.plain, forType: .string)
        if let rtf = representation.rtf { item.setData(rtf, forType: .rtf) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    func revisionRepresentation() -> (plain: String, rtf: Data?)? {
        guard let projection, selectedRange().length > 0 else { return nil }
        let range = selectedRange()
        let value = PreviewCopy.revisionText(from: projection, selection: range)
        guard !value.isEmpty else { return nil }
        let rich = attributedSubstring(forProposedRange: range, actualRange: nil)
        let rtf = rich.flatMap { try? $0.data(from: NSRange(location: 0, length: $0.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) }
        return (value, rtf)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [(L("复制选区原文", "Copy Selected Source Text"), #selector(copySource(_:))), (L("复制选区含修订内容", "Copy Selection with Revisions"), #selector(copyRevisions(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: L("全选", "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        all.target = self; menu.addItem(all)
        return menu
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(copySource(_:)) {
            return projection.map { !PreviewCopy.sourceText(from: $0, selection: selectedRange()).isEmpty } ?? false
        }
        if item.action == #selector(copyRevisions(_:)) { return selectedRange().length > 0 && projection != nil }
        return super.validateUserInterfaceItem(item)
    }
}
