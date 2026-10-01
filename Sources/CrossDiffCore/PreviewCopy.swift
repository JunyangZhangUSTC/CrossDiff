import Foundation

/// Clipboard representations are derived from a selection without modifying
/// the projection or either source. Plain revision text keeps explicit marks.
public enum PreviewCopy {
    public static func sourceText(from preview: DeletionPreview, selection: NSRange) -> String {
        let value = preview.text as NSString
        let selected = NSIntersectionRange(selection, NSRange(location: 0, length: value.length))
        guard selected.length > 0 else { return "" }
        return preview.runs.filter { $0.rightRange.length > 0 }.map { run in
            let range = NSIntersectionRange(run.range, selected)
            return range.length > 0 ? value.substring(with: range) : ""
        }.joined()
    }

    public static func revisionText(from preview: DeletionPreview, selection: NSRange) -> String {
        let value = preview.text as NSString
        let selected = NSIntersectionRange(selection, NSRange(location: 0, length: value.length))
        guard selected.length > 0 else { return "" }
        var spans = preview.removedRanges.map { ($0, true) } + preview.addedRanges.map { ($0, false) }
        spans.sort { $0.0.location < $1.0.location }
        var result = "", cursor = selected.location
        for (span, removed) in spans {
            let range = NSIntersectionRange(span, selected)
            guard range.length > 0 else { continue }
            if cursor < range.location { result += value.substring(with: NSRange(location: cursor, length: range.location - cursor)) }
            result += (removed ? "[-" : "{+") + value.substring(with: range) + (removed ? "-]" : "+}")
            cursor = NSMaxRange(range)
        }
        if cursor < NSMaxRange(selected) {
            result += value.substring(with: NSRange(location: cursor, length: NSMaxRange(selected) - cursor))
        }
        return result
    }
}
