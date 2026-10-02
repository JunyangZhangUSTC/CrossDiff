import Foundation

public enum OfficeImportError: Error, LocalizedError {
    case unsupportedFormat, encrypted, invalidPackage, invalidXML, unsupportedMarkup, limit
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return L("请选择 DOCX、XLSX 或 PPTX 文件。旧版 DOC、XLS、PPT 请先另存为现代格式。", "Choose a DOCX, XLSX or PPTX file. Save legacy DOC, XLS or PPT files in a modern format first.")
        case .encrypted: return L("不支持加密的办公文件，请先保存一份未加密副本。", "Encrypted Office files are unsupported. Save an unencrypted copy first.")
        case .invalidPackage: return L("办公文件的包结构、关系或单元格坐标损坏，无法可靠比较。", "The Office package, relationships or cell coordinates are invalid; comparison would be unreliable.")
        case .invalidXML: return L("办公文件含有无效、不支持或不安全的 XML 内容。", "The Office file contains invalid, unsupported or unsafe XML.")
        case .unsupportedMarkup: return L("文档含有此版本无法读取的扩展内容，且没有可用的兼容回退。请在原应用中另存为标准办公格式后重试。", "The document contains unsupported extension content without a compatibility fallback. Save a standard Office copy in its original application and retry.")
        case .limit: return L("办公文件超出本版的读取或比较限额。请缩小文件或拆分工作表后重试。", "This Office file exceeds the current reading or comparison limits. Reduce the file or split the worksheet and retry.")
        }
    }
}

public enum OfficeImporter {
    public static let maximumSourceBytes: Int64 = 128 * 1024 * 1024
    public static let maximumExpandedBytes: Int64 = 256 * 1024 * 1024
    public static let maximumXMLBytes = 16 * 1024 * 1024
    public static let maximumStoredXMLBytes = 64 * 1024 * 1024
    public static let maximumRows = 10_000
    public static let maximumCells = 100_000

    /// Reads a bounded, read-only content snapshot. It never evaluates formulas,
    /// follows external relationships or writes an extracted file to disk.
    public static func load(_ url: URL) throws -> OfficeDocument {
        try Task.checkCancellation()
        let deadline = Date().addingTimeInterval(60)
        guard let kind = OfficeDocumentKind.from(fileExtension: url.pathExtension) else { throw OfficeImportError.unsupportedFormat }
        let input = try ArchiveInput(url: url.standardizedFileURL)
        guard input.size <= maximumSourceBytes else { throw OfficeImportError.limit }
        let signature = try input.read(offset: 0, count: 8)
        if signature.starts(with: [0xd0, 0xcf, 0x11, 0xe0]) { throw OfficeImportError.encrypted }
        guard signature.starts(with: [0x50, 0x4b]) else { throw OfficeImportError.invalidPackage }
        let parts: [String: Data]
        do {
            parts = try ArchiveZIPReader.packageParts(input, maximumEntries: 10_000,
                maximumExpandedBytes: maximumExpandedBytes, maximumPartBytes: maximumXMLBytes,
                maximumStoredBytes: maximumStoredXMLBytes, deadline: deadline,
                include: { $0.lowercased().hasSuffix(".xml") || $0.lowercased().hasSuffix(".rels") })
        } catch ArchiveError.limit { throw OfficeImportError.limit }
        let reader = OfficePackage(parts: parts, deadline: deadline)
        let main = try reader.mainPart(kind: kind)
        let sections: [OfficeSection]
        switch kind {
        case .word: sections = try reader.word(main)
        case .spreadsheet: sections = try reader.spreadsheet(main)
        case .presentation: sections = try reader.presentation(main)
        }
        try input.stamp.verify(descriptor: input.descriptor)
        try Task.checkCancellation()
        return OfficeDocument(kind: kind, sections: sections, diagnostics: reader.diagnostics)
    }
}

private enum OfficeNS {
    static let compatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    static let package = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let contentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"
    static let relation = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let strictRelation = "http://purl.oclc.org/ooxml/officeDocument/relationships/"
    static let word: Set<String> = ["http://schemas.openxmlformats.org/wordprocessingml/2006/main", "http://purl.oclc.org/ooxml/wordprocessingml/main"]
    static let sheet: Set<String> = ["http://schemas.openxmlformats.org/spreadsheetml/2006/main", "http://purl.oclc.org/ooxml/spreadsheetml/main"]
    static let presentation: Set<String> = ["http://schemas.openxmlformats.org/presentationml/2006/main", "http://purl.oclc.org/ooxml/presentationml/main"]
    static let drawing: Set<String> = ["http://schemas.openxmlformats.org/drawingml/2006/main", "http://purl.oclc.org/ooxml/drawingml/main"]
}

private final class OfficeNode {
    let name: String, namespace: String, attributes: [String: String]
    var text = "", children: [OfficeNode] = []
    init(_ name: String, _ namespace: String, _ attributes: [String: String]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes
    }
    func isName(_ name: String, _ namespace: Set<String>) -> Bool { self.name == name && namespace.contains(self.namespace) }
    func child(_ name: String, _ namespace: Set<String>) -> OfficeNode? { children.first { $0.isName(name, namespace) } }
    func uniqueChild(_ name: String, _ namespace: Set<String>) throws -> OfficeNode? {
        let matches = children.filter { $0.isName(name, namespace) }
        guard matches.count <= 1 else { throw OfficeImportError.invalidPackage }
        return matches.first
    }
    func descendants(_ name: String, _ namespace: Set<String>) -> [OfficeNode] {
        var result: [OfficeNode] = []
        for child in children { if child.isName(name, namespace) { result.append(child) }; result += child.descendants(name, namespace) }
        return result
    }
}

private final class OfficeXML: NSObject, XMLParserDelegate {
    var stack: [OfficeNode] = [], root: OfficeNode?, failure: Error?, nodes = 0, textBytes = 0
    var namespaces = ["xml": "http://www.w3.org/XML/1998/namespace"], namespaceHistory: [String: [String?]] = [:]
    let deadline: Date
    init(deadline: Date) { self.deadline = deadline }
    static func parse(_ data: Data, deadline: Date) throws -> OfficeNode {
        guard data.count <= OfficeImporter.maximumXMLBytes else { throw OfficeImportError.limit }
        // Decode before the DTD check so UTF-16/32 cannot hide entity syntax.
        // Restrict encodings instead of guessing legacy single-byte encodings.
        let encoding: String.Encoding
        if data.starts(with: [0xff, 0xfe, 0, 0]) { encoding = .utf32LittleEndian }
        else if data.starts(with: [0, 0, 0xfe, 0xff]) { encoding = .utf32BigEndian }
        else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0x3c, 0, 0x3f, 0]) { encoding = .utf16LittleEndian }
        else if data.starts(with: [0xfe, 0xff]) || data.starts(with: [0, 0x3c, 0, 0x3f]) { encoding = .utf16BigEndian }
        else if data.starts(with: [0, 0, 0, 0x3c]) { encoding = .utf32BigEndian }
        else if data.starts(with: [0x3c, 0, 0, 0]) { encoding = .utf32LittleEndian }
        else { encoding = .utf8 }
        guard var text = String(data: data, encoding: encoding), !text.contains("\0") else { throw OfficeImportError.invalidXML }
        if text.first == "\u{feff}" { text.removeFirst() }
        let upper = text.uppercased()
        guard !upper.contains("<!DOCTYPE"), !upper.contains("<!ENTITY") else { throw OfficeImportError.invalidXML }
        // XMLParser receives one normalized encoding, regardless of the source BOM.
        if text.hasPrefix("<?xml"), let end = text.range(of: "?>"), text.distance(from: text.startIndex, to: end.upperBound) < 1024 {
            text.removeSubrange(text.startIndex..<end.upperBound)
        }
        let delegate = OfficeXML(deadline: deadline), parser = XMLParser(data: Data(text.utf8))
        parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true; parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never; parser.delegate = delegate
        let success = parser.parse()
        if let failure = delegate.failure { throw failure }
        try Task.checkCancellation()
        guard success, let root = delegate.root, delegate.stack.isEmpty else { throw OfficeImportError.invalidXML }
        return root
    }
    func stop(_ parser: XMLParser, _ error: Error) { failure = error; parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaceHistory[prefix, default: []].append(namespaces[prefix]); namespaces[prefix] = namespaceURI
    }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        if let old = namespaceHistory[prefix]?.popLast() { namespaces[prefix] = old }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if Task.isCancelled { stop(parser, CancellationError()); return }
        nodes += 1
        guard stack.count < 64, nodes <= 250_000, attributes.count <= 128,
              Date() <= deadline, (namespaceURI?.utf8.count ?? 0) <= 4096,
              attributes.allSatisfy({ $0.key.utf8.count <= 4096 && $0.value.utf8.count <= 131_072 }) else { stop(parser, OfficeImportError.limit); return }
        var expanded: [String: String] = [:]
        for (key, value) in attributes {
            if let colon = key.firstIndex(of: ":") {
                let prefix = String(key[..<colon]), local = String(key[key.index(after: colon)...])
                guard let uri = namespaces[prefix] else { stop(parser, OfficeImportError.invalidXML); return }
                expanded["{\(uri)}\(local)"] = value
            } else { expanded[key] = value }
        }
        let node = OfficeNode(name, namespaceURI ?? "", expanded)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { stop(parser, OfficeImportError.invalidXML); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { if !stack.isEmpty { stack.removeLast() } }
    func parser(_ parser: XMLParser, foundCharacters value: String) {
        textBytes += value.utf8.count
        guard textBytes <= OfficeImporter.maximumXMLBytes else { stop(parser, OfficeImportError.limit); return }
        stack.last?.text += value
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let value = String(data: data, encoding: .utf8) else { stop(parser, OfficeImportError.invalidXML); return }
        self.parser(parser, foundCharacters: value)
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? { stop(parser, OfficeImportError.invalidXML); return nil }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { stop(parser, OfficeImportError.invalidXML) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { stop(parser, OfficeImportError.invalidXML) }
}

private struct OfficeRelationship { let id: String, type: String, target: String? }

private final class OfficePackage {
    let parts: [String: Data]
    let deadline: Date
    var diagnostics: [PluginLocalizedText] = [], diagnosticIDs = Set<String>(), cells = 0, outputBytes = 0
    init(parts: [String: Data], deadline: Date) { self.parts = parts; self.deadline = deadline }
    func note(_ id: String, _ zh: String, _ en: String) {
        if diagnosticIDs.insert(id).inserted { diagnostics.append(.init(zhHans: zh, en: en)) }
    }
    func xml(_ path: String) throws -> OfficeNode {
        try Task.checkCancellation()
        guard Date() <= deadline else { throw OfficeImportError.limit }
        guard let data = parts[path] else { throw OfficeImportError.invalidPackage }
        let root = try OfficeXML.parse(data, deadline: deadline)
        try useCompatibilityFallbacks(root)
        return root
    }
    /// AlternateContent branches are alternatives, never adjacent document
    /// content. This reader deliberately uses only the standard fallback; it
    /// does not claim support for a Choice merely because its prefix is known.
    func useCompatibilityFallbacks(_ node: OfficeNode) throws {
        try Task.checkCancellation()
        var children: [OfficeNode] = []
        for child in node.children {
            guard child.namespace == OfficeNS.compatibility else {
                try useCompatibilityFallbacks(child); children.append(child); continue
            }
            guard child.name == "AlternateContent",
                  child.children.allSatisfy({ $0.namespace == OfficeNS.compatibility && ["Choice", "Fallback"].contains($0.name) }),
                  child.children.contains(where: { $0.name == "Choice" }) else { throw OfficeImportError.invalidPackage }
            let fallbacks = child.children.filter { $0.name == "Fallback" }
            guard !fallbacks.isEmpty else { throw OfficeImportError.unsupportedMarkup }
            guard fallbacks.count == 1, child.children.last === fallbacks[0] else { throw OfficeImportError.invalidPackage }
            let fallback = fallbacks[0]
            try useCompatibilityFallbacks(fallback)
            children += fallback.children
            note("compatibility", "扩展内容使用文件内保存的兼容回退，仅比较该回退内容，不重复读取其他分支。", "Extension content uses its saved compatibility fallback. Only that fallback is compared, without duplicating alternative branches.")
        }
        node.children = children
    }
    func unsupportedExtension() {
        note("extensions", "未支持的扩展标记不作为正文读取；比较范围不包含这些扩展内容。", "Unsupported extension markup is not read as body text; its contents are outside the comparison scope.")
    }
    func relationships(_ part: String) throws -> [OfficeRelationship] {
        let path: String
        if part.isEmpty { path = "_rels/.rels" }
        else { let bits = part.split(separator: "/"); path = (bits.dropLast().joined(separator: "/") + "/_rels/" + bits.last! + ".rels").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        guard parts[path] != nil else { return [] }
        let root = try xml(path)
        guard root.name == "Relationships", root.namespace == OfficeNS.package else { throw OfficeImportError.invalidPackage }
        var ids = Set<String>(), result: [OfficeRelationship] = []
        for item in root.children {
            guard item.name == "Relationship", item.namespace == OfficeNS.package,
                  let id = item.attributes["Id"], !id.isEmpty, ids.insert(id).inserted,
                  let type = item.attributes["Type"], let raw = item.attributes["Target"], !raw.isEmpty else { throw OfficeImportError.invalidPackage }
            let mode = item.attributes["TargetMode"] ?? "Internal"
            guard mode == "Internal" || mode == "External" else { throw OfficeImportError.invalidPackage }
            if mode == "External" {
                note("external", "外部链接仅保留文件中的文字；不会联网或读取链接目标。", "External links retain only stored text; linked resources are never fetched.")
                result.append(.init(id: id, type: type, target: nil))
            } else { result.append(.init(id: id, type: type, target: try resolve(raw, relativeTo: part))) }
        }
        return result
    }
    func resolve(_ raw: String, relativeTo part: String) throws -> String {
        guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty,
              !decoded.contains("\\"), !decoded.contains(":"), !decoded.contains("#"), !decoded.contains("?"),
              !decoded.unicodeScalars.contains(where: { $0.value < 32 }), decoded.utf8.count <= 4096 else { throw OfficeImportError.invalidPackage }
        var components = decoded.hasPrefix("/") ? [] : part.split(separator: "/").dropLast().map(String.init)
        for component in decoded.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { guard !components.isEmpty else { throw OfficeImportError.invalidPackage }; components.removeLast() }
            else { components.append(String(component)) }
        }
        guard !components.isEmpty, components.count <= 128 else { throw OfficeImportError.invalidPackage }
        return components.joined(separator: "/")
    }
    func relationType(_ value: String, _ type: String) -> Bool { value == OfficeNS.relation + type || value == OfficeNS.strictRelation + type }
    func related(_ relationships: [OfficeRelationship], id: String, type: String) throws -> String {
        guard let item = relationships.first(where: { $0.id == id }), relationType(item.type, type), let target = item.target, parts[target] != nil else { throw OfficeImportError.invalidPackage }
        return target
    }
    func relationshipID(_ node: OfficeNode) throws -> String {
        let prefixes = [String(OfficeNS.relation.dropLast()), String(OfficeNS.strictRelation.dropLast())]
        let matches = prefixes.compactMap { node.attributes["{\($0)}id"] }
        guard matches.count == 1 else { throw OfficeImportError.invalidPackage }
        return matches[0]
    }
    func mainPart(kind: OfficeDocumentKind) throws -> String {
        let main = try relationships("").filter { relationType($0.type, "officeDocument") }
        guard main.count == 1, let path = main[0].target, parts[path] != nil else { throw OfficeImportError.invalidPackage }
        let types = try xml("[Content_Types].xml")
        guard types.name == "Types", types.namespace == OfficeNS.contentTypes else { throw OfficeImportError.invalidPackage }
        var overrides: [String: String] = [:]
        for item in types.children where item.name == "Override" {
            guard item.namespace == OfficeNS.contentTypes, let name = item.attributes["PartName"], let type = item.attributes["ContentType"] else { throw OfficeImportError.invalidPackage }
            let key = try resolve(name, relativeTo: "")
            guard overrides.updateValue(type, forKey: key) == nil else { throw OfficeImportError.invalidPackage }
        }
        let suffix: String
        switch kind { case .word: suffix = "wordprocessingml.document"; case .spreadsheet: suffix = "spreadsheetml.sheet"; case .presentation: suffix = "presentationml.presentation" }
        guard overrides[path] == "application/vnd.openxmlformats-officedocument." + suffix + ".main+xml" else { throw OfficeImportError.invalidPackage }
        return path
    }
    func checkedCell(column: Int, type: String = "text", value: String?, formula: String? = nil, format: String? = nil) throws -> OfficeCell {
        cells += 1
        let size = (value?.utf8.count ?? 0) + (formula?.utf8.count ?? 0)
        outputBytes += size
        guard cells <= OfficeImporter.maximumCells, (value?.utf8.count ?? 0) <= 131_072,
              (formula?.utf8.count ?? 0) <= 131_072, outputBytes <= 16 * 1024 * 1024,
              (1...16_384).contains(column), (format?.utf8.count ?? 0) <= 4096 else { throw OfficeImportError.limit }
        return OfficeCell(column: column, type: type, value: value, formula: formula, format: format)
    }
    func appendRow(_ values: [OfficeCell], _ rows: inout [OfficeRow], label: String? = nil) throws {
        guard rows.count < OfficeImporter.maximumRows else { throw OfficeImportError.limit }
        let position = rows.count + 1
        rows.append(OfficeRow(id: "row-\(position)", position: position, label: label ?? "\(position)", cells: values))
    }
    func word(_ path: String) throws -> [OfficeSection] {
        let root = try xml(path)
        guard root.isName("document", OfficeNS.word), let body = try root.uniqueChild("body", OfficeNS.word) else { throw OfficeImportError.invalidPackage }
        note("word-scope", "比较正文、表格及已读取的页眉页脚和注释文字；不比较字体、分页、图片或版式。", "Compares body text, tables and available header, footer and annotation text; fonts, pagination, images and layout are not compared.")
        var rows: [OfficeRow] = []
        try wordBlocks(body, rows: &rows)
        var result = [OfficeSection(id: "body", name: "Document", rows: rows)]
        let relations = try relationships(path)
        for type in ["header", "footer", "footnotes", "endnotes", "comments"] {
            for relation in relations where relationType(relation.type, type) {
                guard let target = relation.target else { throw OfficeImportError.invalidPackage }
                let node = try xml(target)
                let expected = ["header":"hdr", "footer":"ftr", "footnotes":"footnotes", "endnotes":"endnotes", "comments":"comments"][type]!
                guard node.isName(expected, OfficeNS.word) else { throw OfficeImportError.invalidPackage }
                var extra: [OfficeRow] = []
                try wordBlocks(node, rows: &extra)
                result.append(.init(id: "\(type)-\(result.count)", name: type.capitalized + " \(result.count)", rows: extra))
                guard result.count <= 512 else { throw OfficeImportError.limit }
            }
        }
        return result
    }
    func wordBlocks(_ node: OfficeNode, rows: inout [OfficeRow]) throws {
        try Task.checkCancellation()
        guard OfficeNS.word.contains(node.namespace) else { unsupportedExtension(); return }
        if OfficeNS.word.contains(node.namespace), ["del", "moveFrom"].contains(node.name) {
            note("revisions", "文档包含修订：仅比较当前可见文字，删除和移出记录不纳入正文。", "Tracked changes are present: comparison uses current text and excludes deleted or moved-from text."); return
        }
        if node.isName("ins", OfficeNS.word) || node.isName("moveTo", OfficeNS.word) {
            note("revisions", "文档包含修订：仅比较当前可见文字，删除和移出记录不纳入正文。", "Tracked changes are present: comparison uses current text and excludes deleted or moved-from text.")
        }
        if node.isName("p", OfficeNS.word) {
            try appendRow([checkedCell(column: 1, value: wordText(node))], &rows); return
        }
        if node.isName("tr", OfficeNS.word) {
            var values: [OfficeCell] = []
            for cell in node.children where cell.isName("tc", OfficeNS.word) {
                let paragraphs = wordParagraphs(cell)
                values.append(try checkedCell(column: values.count + 1, value: paragraphs.joined(separator: "\n")))
            }
            if !values.isEmpty { try appendRow(values, &rows) }; return
        }
        if node.isName("footnote", OfficeNS.word) || node.isName("endnote", OfficeNS.word) {
            if node.attributes.contains(where: { $0.key.hasSuffix("}type") && ["separator", "continuationSeparator"].contains($0.value) }) { return }
        }
        for child in node.children { try wordBlocks(child, rows: &rows) }
    }
    func wordText(_ node: OfficeNode) -> String {
        guard OfficeNS.word.contains(node.namespace) else { unsupportedExtension(); return "" }
        if OfficeNS.word.contains(node.namespace) {
            if ["ins", "moveTo"].contains(node.name) {
                note("revisions", "文档包含修订：仅比较当前可见文字，删除和移出记录不纳入正文。", "Tracked changes are present: comparison uses current text and excludes deleted or moved-from text.")
            }
            if ["del", "moveFrom"].contains(node.name) {
                note("revisions", "文档包含修订：仅比较当前可见文字，删除和移出记录不纳入正文。", "Tracked changes are present: comparison uses current text and excludes deleted or moved-from text."); return ""
            }
            if node.name == "t" { return node.text }
            if node.name == "tab" { return "\t" }
            if ["br", "cr"].contains(node.name) { return "\n" }
            if ["instrText", "delText"].contains(node.name) { return "" }
        }
        return node.children.map { wordText($0) }.joined()
    }
    func wordParagraphs(_ node: OfficeNode) -> [String] {
        guard OfficeNS.word.contains(node.namespace) else { unsupportedExtension(); return [] }
        if OfficeNS.word.contains(node.namespace), ["del", "moveFrom"].contains(node.name) {
            _ = wordText(node); return []
        }
        if node.isName("p", OfficeNS.word) { return [wordText(node)] }
        return node.children.flatMap(wordParagraphs)
    }
    func spreadsheet(_ path: String) throws -> [OfficeSection] {
        let root = try xml(path)
        guard root.isName("workbook", OfficeNS.sheet), let sheetList = try root.uniqueChild("sheets", OfficeNS.sheet) else { throw OfficeImportError.invalidPackage }
        let relations = try relationships(path)
        let sharedParts = relations.filter { relationType($0.type, "sharedStrings") }
        guard sharedParts.count <= 1 else { throw OfficeImportError.invalidPackage }
        var strings: [String] = []
        if let item = sharedParts.first {
            guard let target = item.target else { throw OfficeImportError.invalidPackage }
            let shared = try xml(target)
            guard shared.isName("sst", OfficeNS.sheet) else { throw OfficeImportError.invalidPackage }
            for item in shared.children where item.isName("si", OfficeNS.sheet) {
                strings.append(sheetText(item))
                guard strings.count <= OfficeImporter.maximumCells, strings.last!.utf8.count <= 131_072 else { throw OfficeImportError.limit }
            }
        }
        let styleParts = relations.filter { relationType($0.type, "styles") }
        guard styleParts.count <= 1 else { throw OfficeImportError.invalidPackage }
        var formats: [String] = []
        if let item = styleParts.first {
            guard let target = item.target else { throw OfficeImportError.invalidPackage }
            let styles = try xml(target)
            guard styles.isName("styleSheet", OfficeNS.sheet) else { throw OfficeImportError.invalidPackage }
            var custom: [Int: String] = [:]
            if let numbers = try styles.uniqueChild("numFmts", OfficeNS.sheet) {
                for number in numbers.children where number.isName("numFmt", OfficeNS.sheet) {
                    guard let id = number.attributes["numFmtId"].flatMap(Int.init), id >= 0,
                          let code = number.attributes["formatCode"], code.utf8.count <= 4096,
                          custom.updateValue(code, forKey: id) == nil else { throw OfficeImportError.invalidPackage }
                }
            }
            let builtin = [0:"General", 1:"0", 2:"0.00", 9:"0%", 10:"0.00%", 14:"mm-dd-yy", 15:"d-mmm-yy", 16:"d-mmm", 17:"mmm-yy", 18:"h:mm AM/PM", 19:"h:mm:ss AM/PM", 20:"h:mm", 21:"h:mm:ss", 22:"m/d/yy h:mm", 49:"@"]
            if let xfs = try styles.uniqueChild("cellXfs", OfficeNS.sheet) {
                for xf in xfs.children where xf.isName("xf", OfficeNS.sheet) {
                    guard let id = Int(xf.attributes["numFmtId"] ?? "0"), id >= 0 else { throw OfficeImportError.invalidPackage }
                    formats.append(custom[id] ?? builtin[id] ?? "Built-in format \(id)")
                    guard formats.count <= 65_536 else { throw OfficeImportError.limit }
                }
            }
        }
        let epoch = try root.uniqueChild("workbookPr", OfficeNS.sheet)?.attributes["date1904"] ?? "0"
        guard ["0", "1", "false", "true"].contains(epoch) else { throw OfficeImportError.invalidPackage }
        let is1904 = epoch == "1" || epoch == "true"
        note("sheet-scope", "比较单元格的类型、原始值、公式及保存的结果；不重算公式，不比较样式、图表、图片或版式。", "Compares cell types, raw values, formulas and saved results. Formulas are not recalculated; styles, charts, images and layout are not compared.")
        note("dates", is1904 ? "此工作簿使用 1904 日期制；日期和时间保留原始序列值，格式另行显示。" : "此工作簿使用 1900 日期制；日期和时间保留原始序列值，格式另行显示。", is1904 ? "This workbook uses the 1904 date system; date/time serials remain raw, with number formats shown separately." : "This workbook uses the 1900 date system; date/time serials remain raw, with number formats shown separately.")
        var result: [OfficeSection] = [], ids = Set<String>(), names = Set<String>(), targets = Set<String>()
        for sheet in sheetList.children where sheet.isName("sheet", OfficeNS.sheet) {
            guard let name = sheet.attributes["name"], !name.isEmpty, name.utf8.count <= 256,
                  names.insert(name).inserted, let id = sheet.attributes["sheetId"], UInt32(id) != nil,
                  ids.insert(id).inserted else { throw OfficeImportError.invalidPackage }
            let target = try related(relations, id: relationshipID(sheet), type: "worksheet")
            guard targets.insert(target).inserted else { throw OfficeImportError.invalidPackage }
            let body = try xml(target)
            guard body.isName("worksheet", OfficeNS.sheet), let data = try body.uniqueChild("sheetData", OfficeNS.sheet) else { throw OfficeImportError.invalidPackage }
            if let state = sheet.attributes["state"], state != "visible" {
                note("hidden", "包含隐藏工作表、行或列；其中已保存的单元格也参与比较。", "Hidden worksheets, rows or columns are present; their stored cells are included.")
            }
            if body.child("mergeCells", OfficeNS.sheet) != nil {
                note("merged", "合并单元格按文件中实际存储的源坐标比较；合并范围和视觉布局不参与差异判断。", "Merged cells are compared at their stored coordinates; merge ranges and visual layout are not compared.")
            }
            if body.descendants("col", OfficeNS.sheet).contains(where: { ["1", "true"].contains($0.attributes["hidden"] ?? "0") }) {
                note("hidden", "包含隐藏工作表、行或列；其中已保存的单元格也参与比较。", "Hidden worksheets, rows or columns are present; their stored cells are included.")
            }
            var masters: [String: (text: String, range: String)] = [:]
            for formula in data.descendants("f", OfficeNS.sheet) where formula.attributes["t"] == "shared" && !formula.text.isEmpty {
                guard let sharedID = formula.attributes["si"], UInt32(sharedID) != nil,
                      masters.updateValue((formula.text, formula.attributes["ref"] ?? ""), forKey: sharedID) == nil else { throw OfficeImportError.invalidPackage }
            }
            var rows: [OfficeRow] = [], rowIDs = Set<Int>(), inferredRow = 0
            for row in data.children where row.isName("row", OfficeNS.sheet) {
                let position: Int
                if let value = row.attributes["r"] { guard let r = Int(value) else { throw OfficeImportError.invalidPackage }; position = r }
                else { position = inferredRow + 1 }
                guard (1...1_048_576).contains(position), rowIDs.insert(position).inserted else { throw OfficeImportError.invalidPackage }
                inferredRow = position
                if ["1", "true"].contains(row.attributes["hidden"] ?? "0") {
                    note("hidden", "包含隐藏工作表、行或列；其中已保存的单元格也参与比较。", "Hidden worksheets, rows or columns are present; their stored cells are included.")
                }
                var values: [OfficeCell] = [], columns = Set<Int>(), inferredColumn = 0
                for cell in row.children where cell.isName("c", OfficeNS.sheet) {
                    let column: Int
                    if let reference = cell.attributes["r"] { let address = try cellAddress(reference); guard address.row == position else { throw OfficeImportError.invalidPackage }; column = address.column }
                    else { column = inferredColumn + 1 }
                    guard (1...16_384).contains(column), columns.insert(column).inserted else { throw OfficeImportError.invalidPackage }
                    inferredColumn = column
                    let valueNodes = cell.children.filter { $0.isName("v", OfficeNS.sheet) }
                    let formulaNodes = cell.children.filter { $0.isName("f", OfficeNS.sheet) }
                    guard valueNodes.count <= 1, formulaNodes.count <= 1 else { throw OfficeImportError.invalidPackage }
                    let formulaNode = formulaNodes.first
                    let stored = valueNodes.first?.text, cellType = cell.attributes["t"] ?? "n"
                    let raw = stored == "" && cellType != "str" ? nil : stored
                    guard (raw?.utf8.count ?? 0) <= 131_072 else { throw OfficeImportError.limit }
                    var formula = formulaNode?.text
                    if let f = formulaNode {
                        let kind = f.attributes["t"] ?? "normal"
                        guard ["normal", "shared", "array", "dataTable"].contains(kind) else { throw OfficeImportError.invalidPackage }
                        if kind == "shared" {
                            guard let key = f.attributes["si"], let master = masters[key] else { throw OfficeImportError.invalidPackage }
                            if f.text.isEmpty { formula = "shared[\(key)]@\(master.range):\(master.text)" }
                            note("shared-formulas", "共享公式的从属单元格显示已保存的主公式与范围，不推算相对引用。", "Shared-formula followers show the saved master formula and range; relative references are not recalculated.")
                        } else if f.text.isEmpty {
                            guard kind != "normal" else { throw OfficeImportError.invalidPackage }
                            formula = kind + "@" + (f.attributes["ref"] ?? "")
                        }
                    }
                    var format: String?
                    if let style = cell.attributes["s"] {
                        guard let index = Int(style), formats.indices.contains(index) else { throw OfficeImportError.invalidPackage }
                        format = formats[index]
                    }
                    let type = cell.attributes["t"] ?? "n", value: String?, resolvedType: String
                    switch type {
                    case "s":
                        guard let raw, let index = Int(raw), strings.indices.contains(index), formula == nil else { throw OfficeImportError.invalidPackage }
                        resolvedType = "string"; value = strings[index]
                    case "inlineStr":
                        guard raw == nil, formula == nil, let inline = try cell.uniqueChild("is", OfficeNS.sheet) else { throw OfficeImportError.invalidPackage }
                        resolvedType = "string"; value = sheetText(inline)
                    case "str": resolvedType = "string"; value = raw
                    case "b":
                        guard raw == nil && formula != nil || ["0", "1", "false", "true"].contains(raw ?? "") else { throw OfficeImportError.invalidPackage }
                        resolvedType = "boolean"; value = raw.map { $0 == "1" || $0 == "true" ? "true" : "false" }
                    case "e": resolvedType = "error"; value = raw
                    case "d": resolvedType = "date"; value = raw
                    case "n":
                        if let raw, !raw.isEmpty {
                            guard raw.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw OfficeImportError.invalidPackage }
                        }
                        resolvedType = "number"; value = raw
                    default: throw OfficeImportError.invalidPackage
                    }
                    if value == nil && formula == nil { continue }
                    if formula != nil {
                        note("formula-cache", "公式旁的值是上次保存的计算结果，可能缺失或过期；不会执行公式、宏或外部链接。", "Values beside formulas are saved results and may be absent or stale. Formulas, macros and external links are never executed.")
                    }
                    values.append(try checkedCell(column: column, type: resolvedType, value: value, formula: formula, format: format))
                }
                if !values.isEmpty { rows.append(.init(id: "row-\(position)", position: position, label: "\(position)", cells: values.sorted { $0.column < $1.column })) }
                guard rows.count <= OfficeImporter.maximumRows else { throw OfficeImportError.limit }
            }
            result.append(.init(id: "sheet-" + id, name: name, rows: rows.sorted { $0.position < $1.position }))
            guard result.count <= 512 else { throw OfficeImportError.limit }
            _ = try relationships(target)
        }
        return result
    }
    func sheetText(_ node: OfficeNode) -> String {
        if node.isName("rPh", OfficeNS.sheet) { return "" }
        if node.isName("t", OfficeNS.sheet) { return node.text }
        return node.children.map { sheetText($0) }.joined()
    }
    func cellAddress(_ value: String) throws -> (column: Int, row: Int) {
        guard value.utf8.count <= 16 else { throw OfficeImportError.invalidPackage }
        var column = 0, digits = "", readingDigits = false
        for byte in value.utf8 {
            if (65...90).contains(byte), !readingDigits { column = column * 26 + Int(byte - 64) }
            else if (48...57).contains(byte) { readingDigits = true; digits.append(Character(UnicodeScalar(byte))) }
            else { throw OfficeImportError.invalidPackage }
        }
        guard (1...16_384).contains(column), let row = Int(digits), (1...1_048_576).contains(row) else { throw OfficeImportError.invalidPackage }
        return (column, row)
    }
    func presentation(_ path: String) throws -> [OfficeSection] {
        let root = try xml(path)
        guard root.isName("presentation", OfficeNS.presentation) else { throw OfficeImportError.invalidPackage }
        let relations = try relationships(path)
        note("presentation-scope", "比较幻灯片文字、表格和演讲者备注；不比较母版、布局、图片、图表、动画或音视频。", "Compares slide text, tables and speaker notes; masters, layout, images, charts, animation, audio and video are not compared.")
        guard let list = try root.uniqueChild("sldIdLst", OfficeNS.presentation) else { return [] }
        var result: [OfficeSection] = [], ids = Set<String>(), targets = Set<String>()
        for slide in list.children where slide.isName("sldId", OfficeNS.presentation) {
            guard let id = slide.attributes["id"], UInt32(id) != nil, ids.insert(id).inserted else { throw OfficeImportError.invalidPackage }
            let target = try related(relations, id: relationshipID(slide), type: "slide")
            guard targets.insert(target).inserted else { throw OfficeImportError.invalidPackage }
            let body = try xml(target)
            guard body.isName("sld", OfficeNS.presentation), let content = try body.uniqueChild("cSld", OfficeNS.presentation), let tree = try content.uniqueChild("spTree", OfficeNS.presentation) else { throw OfficeImportError.invalidPackage }
            var rows: [OfficeRow] = []
            try slideBlocks(tree, rows: &rows)
            let title = rows.first?.cells.first?.value?.split(separator: "\n").first.map(String.init) ?? "Slide \(result.count + 1)"
            let extra = try relationships(target)
            let notes = extra.filter { relationType($0.type, "notesSlide") }
            guard notes.count <= 1 else { throw OfficeImportError.invalidPackage }
            if let relation = notes.first {
                guard let path = relation.target else { throw OfficeImportError.invalidPackage }
                let notesRoot = try xml(path)
                guard notesRoot.isName("notes", OfficeNS.presentation), let notesBody = try notesRoot.uniqueChild("cSld", OfficeNS.presentation), let tree = try notesBody.uniqueChild("spTree", OfficeNS.presentation) else { throw OfficeImportError.invalidPackage }
                try slideBlocks(tree, rows: &rows, notes: true)
            }
            result.append(.init(id: "slide-" + id, name: String(title.prefix(120)), rows: rows))
            guard result.count <= 512 else { throw OfficeImportError.limit }
        }
        return result
    }
    func slideBlocks(_ node: OfficeNode, rows: inout [OfficeRow], notes: Bool = false) throws {
        try Task.checkCancellation()
        guard OfficeNS.presentation.contains(node.namespace) || OfficeNS.drawing.contains(node.namespace) else { unsupportedExtension(); return }
        if node.isName("sp", OfficeNS.presentation) {
            if notes, node.descendants("ph", OfficeNS.presentation).contains(where: { ["sldImg", "sldNum", "dt", "hdr", "ftr"].contains($0.attributes["type"] ?? "") }) { return }
            if let body = try node.uniqueChild("txBody", OfficeNS.presentation) {
                for p in body.children where p.isName("p", OfficeNS.drawing) {
                    let text = drawingText(p)
                    try appendRow([checkedCell(column: 1, value: text)], &rows, label: notes ? "Note \(rows.count + 1)" : nil)
                }
            }
            return
        }
        if node.isName("tbl", OfficeNS.drawing) {
            for row in node.children where row.isName("tr", OfficeNS.drawing) {
                var values: [OfficeCell] = []
                for cell in row.children where cell.isName("tc", OfficeNS.drawing) {
                    let text = try cell.uniqueChild("txBody", OfficeNS.drawing)?.children.filter { $0.isName("p", OfficeNS.drawing) }.map(drawingText).joined(separator: "\n") ?? ""
                    values.append(try checkedCell(column: values.count + 1, value: text))
                }
                if !values.isEmpty { try appendRow(values, &rows) }
            }
            return
        }
        for child in node.children { try slideBlocks(child, rows: &rows, notes: notes) }
    }
    func drawingText(_ node: OfficeNode) -> String {
        guard OfficeNS.drawing.contains(node.namespace) else { unsupportedExtension(); return "" }
        if node.isName("t", OfficeNS.drawing) { return node.text }
        if node.isName("br", OfficeNS.drawing) { return "\n" }
        if node.isName("tab", OfficeNS.drawing) { return "\t" }
        return node.children.map(drawingText).joined()
    }
}
