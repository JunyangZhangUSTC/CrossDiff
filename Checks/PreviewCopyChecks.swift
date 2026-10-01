import Foundation
import CrossDiffCore

func runPreviewCopyChecks() throws {
    let fixtures = [("before old\nremoved 👩🏽‍💻\nlast\n", "before new\nlast\n"),
                    ("全被删除 e\u{301}\r\n", ""), ("", "全部新增 🐈\r\n"),
                    ("相同\r\n结尾", "相同\r\n结尾"), ("👩🏽‍💻 旧 e\u{301}", "👩🏽‍💻 新 e\u{301}")]
    for (left, right) in fixtures {
        let result = TextDiffEngine.compare(left, right)
        let preview = DeletionPreview.make(left: left, right: right, result: result, options: .init())
        let all = NSRange(location: 0, length: preview.text.utf16.count)
        precondition(PreviewCopy.sourceText(from: preview, selection: all).utf16.elementsEqual(right.utf16), "Copy original must reproduce exact right source")
        precondition(PreviewCopy.sourceText(from: preview, selection: NSRange(location: 0, length: 0)).isEmpty)
        for range in preview.removedRanges {
            precondition(PreviewCopy.sourceText(from: preview, selection: range).isEmpty, "Deleted-only selection has no original text")
            precondition(PreviewCopy.revisionText(from: preview, selection: range) == "[-" + (preview.text as NSString).substring(with: range) + "-]")
        }
        for range in preview.addedRanges {
            precondition(PreviewCopy.sourceText(from: preview, selection: range) == (preview.text as NSString).substring(with: range))
            precondition(PreviewCopy.revisionText(from: preview, selection: range) == "{+" + (preview.text as NSString).substring(with: range) + "+}")
        }
        let emoji = (preview.text as NSString).range(of: "👩🏽‍💻")
        if emoji.location != NSNotFound, !preview.removedRanges.contains(where: { NSIntersectionRange($0, emoji).length > 0 }) {
            precondition(PreviewCopy.sourceText(from: preview, selection: emoji) == "👩🏽‍💻")
        }
    }
    let p = DeletionPreview.make(left: "abcd", right: "axyzd", result: TextDiffEngine.compare("abcd", "axyzd"), options: .init())
    let middle = (p.text as NSString).range(of: "xy")
    precondition(PreviewCopy.sourceText(from: p, selection: middle) == "xy")
    precondition(PreviewCopy.revisionText(from: p, selection: middle) == "{+xy+}")
    print("✓ Preview copy: exact source, deletion-only selection, explicit revision marks, partial selection and Unicode; no system clipboard used")
}
