import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum APIImportFormat: String, Codable, Sendable { case http, curl, har }
public struct APIHeader: Codable, Equatable, Sendable {
    public let name: String
    public let value: String
    public let hasEquals: Bool
    public init(name: String, value: String, hasEquals: Bool = true) { self.name = name; self.value = value; self.hasEquals = hasEquals }
}
public enum APIBodyState: String, Codable, Sendable { case missing, empty, text, unsupported }
public struct APIBody: Codable, Equatable, Sendable {
    public let state: APIBodyState
    public let text: String?
    public let mimeType: String?
    public init(state: APIBodyState, text: String? = nil, mimeType: String? = nil) {
        self.state = state; self.text = text; self.mimeType = mimeType
    }
}
public struct APIMessage: Codable, Equatable, Sendable {
    public let method: String?
    public let url: String?
    public let httpVersion: String?
    public let statusCode: String?
    public let statusText: String?
    public let headers: [APIHeader]
    public let body: APIBody
    public init(method: String? = nil, url: String? = nil, httpVersion: String? = nil,
                statusCode: String? = nil, statusText: String? = nil, headers: [APIHeader], body: APIBody) {
        self.method = method; self.url = url; self.httpVersion = httpVersion
        self.statusCode = statusCode; self.statusText = statusText; self.headers = headers; self.body = body
    }
}
public struct APIField: Codable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let type: String
    public let value: String
    public let sensitive: Bool
    public let name: String?
    public init(key: String, label: String, type: String, value: String, sensitive: Bool = false, name: String? = nil) {
        self.key = key; self.label = label; self.type = type; self.value = value; self.sensitive = sensitive; self.name = name
    }
    var pluginContent: PluginJSONValue {
        var content: [String: PluginJSONValue] = ["key": .string(key), "label": .string(label),
            "type": .string(type), "value": .string(value), "sensitive": .bool(sensitive)]
        if let name { content["name"] = .string(name) }; return .object(content)
    }
}
public struct APISection: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: PluginLocalizedText
    public let fields: [APIField]
    public init(id: String, label: PluginLocalizedText, fields: [APIField]) { self.id = id; self.label = label; self.fields = fields }
    var pluginContent: PluginJSONValue {
        .object(["id": .string(id), "label": .object(["zhHans": .string(label.zhHans), "en": .string(label.en)]),
                 "fields": .array(fields.map(\.pluginContent))])
    }
}
public struct APIExchange: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let request: APIMessage?
    public let response: APIMessage?
    public let diagnostics: [PluginLocalizedText]
    public let sections: [APISection]
    public var pluginContent: PluginJSONValue {
        .object(["sections": .array(sections.map(\.pluginContent)), "diagnostics": .array(diagnostics.map {
            .object(["zhHans": .string($0.zhHans), "en": .string($0.en)])
        })])
    }
}
public struct APIImportDocument: Codable, Equatable, Sendable {
    public let format: APIImportFormat
    public let source: String
    public let exchanges: [APIExchange]
    public let diagnostics: [PluginLocalizedText]
}

public enum APIImportError: Error, LocalizedError, Equatable {
    case sourceLimit, bodyLimit, fieldLimit, entryLimit, jsonLimit, invalidJSON, duplicateJSONKey
    case unsupportedFormat, invalidHTTP, invalidHAR, invalidCurl, unsupportedCurlOption(String)
    case externalCurlData, shellExpansion, curlURLGlobbing, curlTokenLimit, invalidUTF8, unreadableFile
    public var errorDescription: String? {
        switch self {
        case .sourceLimit: return L("输入超过 4 MiB 限制。", "Input exceeds the 4 MiB limit.")
        case .bodyLimit: return L("正文超过 1 MiB 限制。", "Body exceeds the 1 MiB limit.")
        case .fieldLimit: return L("调用包含超过 5,000 个字段。", "Exchange exceeds 5,000 fields.")
        case .entryLimit: return L("HAR 包含超过 500 次调用。", "HAR exceeds 500 exchanges.")
        case .jsonLimit: return L("JSON 超过 64 层或 20,000 个节点。", "JSON exceeds 64 levels or 20,000 nodes.")
        case .invalidJSON: return L("JSON 格式无效，无法可靠比较。", "Invalid JSON cannot be compared reliably.")
        case .duplicateJSONKey: return L("JSON 含重复键，无法可靠进行结构化比较。", "Duplicate JSON keys prevent reliable structural comparison.")
        case .unsupportedFormat: return L("请粘贴 HTTP 请求、响应、cURL 命令或 HAR 记录。", "Paste an HTTP request, response, cURL command, or HAR recording.")
        case .invalidHTTP: return L("HTTP 文本不完整或包含不支持的格式。", "HTTP text is incomplete or uses an unsupported format.")
        case .invalidHAR: return L("HAR 记录缺少有效的调用数据。", "HAR recording is missing valid exchange data.")
        case .invalidCurl: return L("cURL 命令格式无效或包含多个地址。", "Invalid cURL command or multiple target URLs.")
        case .unsupportedCurlOption(let option): return L("不支持此 cURL 选项：", "Unsupported cURL option: ") + option
        case .externalCurlData: return L("不读取 cURL 引用的外部文件，请粘贴实际内容。", "External cURL files are not read; paste their contents instead.")
        case .shellExpansion: return L("cURL 导入不支持 Shell 展开、变量或附加命令。", "cURL import does not support shell expansion, variables, or additional commands.")
        case .curlURLGlobbing: return L("不支持 cURL 多地址展开。若地址中的括号为字面字符，请显式使用 --globoff。", "cURL URL expansion is not supported. Use --globoff explicitly when brackets or braces are literal URL characters.")
        case .curlTokenLimit: return L("cURL 输入超过 20,000 个词法单元限制。", "cURL input exceeds the 20,000-token limit.")
        case .invalidUTF8: return L("输入必须为有效的 UTF-8 文本。", "Input must be valid UTF-8 text.")
        case .unreadableFile: return L("只能读取大小受限的普通文件。", "Only bounded regular files can be read.")
        }
    }
}

public enum APIImporter {
    public static let sourceByteLimit = 4 * 1024 * 1024
    public static let bodyByteLimit = 1024 * 1024
    public static func parse(_ source: String) throws -> APIImportDocument {
        try Task.checkCancellation()
        guard source.utf8.count <= sourceByteLimit else { throw APIImportError.sourceLimit }
        let probe = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let format: APIImportFormat
        let exchanges: [APIExchange]
        if probe.hasPrefix("{") {
            format = .har; exchanges = try parseHAR(probe)
        } else if probe == "curl" || probe.hasPrefix("curl ") || probe.hasPrefix("curl\t") || probe.hasPrefix("curl\n") {
            format = .curl; exchanges = [try parseCurl(probe)]
        } else {
            format = .http; exchanges = [try parseHTTP(source)]
        }
        return APIImportDocument(format: format, source: source, exchanges: exchanges, diagnostics: [])
    }
    public static func load(_ url: URL) throws -> APIImportDocument {
        guard url.isFileURL else { throw APIImportError.unreadableFile }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw APIImportError.unreadableFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw APIImportError.unreadableFile
        }
        guard info.st_size <= sourceByteLimit else { throw APIImportError.sourceLimit }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw APIImportError.unreadableFile }
            guard data.count + count <= sourceByteLimit else { throw APIImportError.sourceLimit }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let source = String(data: data, encoding: .utf8) else { throw APIImportError.invalidUTF8 }
        return try parse(source)
    }
    private static func exchange(id: String = "0", name: String? = nil, request: APIMessage?, response: APIMessage?,
                                 query: [APIHeader]? = nil, diagnostics: [PluginLocalizedText] = []) throws -> APIExchange {
        guard (request?.headers.count ?? 0) + (response?.headers.count ?? 0) + (query?.count ?? 0) <= 5_000 else {
            throw APIImportError.fieldLimit
        }
        var sections: [APISection] = []
        if let request { sections += try normalize(request, role: "request", query: query) }
        if let response { sections += try normalize(response, role: "response") }
        guard sections.reduce(0, { $0 + $1.fields.count }) <= 5_000,
              sections.allSatisfy({ $0.fields.allSatisfy { $0.key.utf8.count <= 16_384 && $0.label.utf8.count <= 16_384 && $0.value.utf8.count <= bodyByteLimit } }) else { throw APIImportError.fieldLimit }
        return APIExchange(id: id, name: name ?? [request?.method, request?.url.map(displayURL), response?.statusCode].compactMap { $0 }.joined(separator: " "),
                           request: request, response: response, diagnostics: diagnostics, sections: sections)
    }
    private static func pointer(_ value: String) -> String { value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
    private static func displayURL(_ value: String) -> String {
        let base = value.firstIndex(of: "?").map { String(value[..<$0]) } ?? value
        if var parsed = URLComponents(string: base), parsed.user != nil || parsed.password != nil {
            parsed.user = nil; parsed.password = nil; return parsed.string ?? "…"
        }
        return base
    }
    private static func lower(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in (65...90).contains(scalar.value) ? Character(UnicodeScalar(scalar.value + 32)!) : Character(scalar) })
    }
    private static func sensitive(_ key: String) -> Bool {
        let compact = lower(key).filter { $0.isLetter || $0.isNumber }
        return ["authorization", "proxyauthorization", "cookie", "setcookie", "password", "passwd", "secret", "token", "apikey", "credential", "sessionid"].contains { compact.contains($0) }
    }
    private static func pairs(_ values: [APIHeader], header: Bool) -> [APIField] {
        var seen: [Data: Int] = [:]
        return values.map {
            let key = header ? lower($0.name) : $0.name
            let exactKey = Data(key.utf8)
            let occurrence = seen[exactKey, default: 0]; seen[exactKey] = occurrence + 1
            return APIField(key: "/\(pointer(key))/\(occurrence)", label: $0.name, type: header || $0.hasEquals ? "string" : "flag", value: $0.value,
                            sensitive: sensitive($0.name), name: $0.name)
        }
    }
    private static func urlParts(_ text: String) throws -> (String, [APIHeader]) {
        guard let mark = text.firstIndex(of: "?") else { return (text, []) }
        let base = String(text[..<mark]); let suffix = String(text[text.index(after: mark)...])
        var parameterCount = 1
        for (offset, byte) in suffix.utf8.enumerated() {
            if offset % 4096 == 0 { try Task.checkCancellation() }
            if byte == 38 { parameterCount += 1 }
            guard parameterCount <= 5_000 else { throw APIImportError.fieldLimit }
        }
        // Preserve encoding, '+', absent '=' and ordering: query semantics belong to the API.
        let parameters = suffix.split(separator: "&", omittingEmptySubsequences: false).map { component -> APIHeader in
            guard let equal = component.firstIndex(of: "=") else { return .init(name: String(component), value: "", hasEquals: false) }
            return .init(name: String(component[..<equal]), value: String(component[component.index(after: equal)...]))
        }
        return (base, parameters)
    }
    private static func normalize(_ message: APIMessage, role: String, query: [APIHeader]? = nil) throws -> [APISection] {
        let isRequest = role == "request"
        let parsedURL = try message.url.map(urlParts)
        var summary: [APIField] = []
        for (key, value) in [("method", message.method), ("url", parsedURL?.0),
                             ("httpVersion", message.httpVersion), ("status", message.statusCode), ("statusText", message.statusText)] {
            if let value { summary.append(.init(key: key, label: key, type: "string", value: value, sensitive: key == "url" && value.contains("@"))) }
        }
        var result = [APISection(id: role + ".summary", label: .init(zhHans: isRequest ? "请求概览" : "响应概览", en: isRequest ? "Request overview" : "Response overview"), fields: summary)]
        if isRequest { result.append(.init(id: "request.query", label: .init(zhHans: "查询参数", en: "Query parameters"), fields: pairs(query ?? parsedURL?.1 ?? [], header: false))) }
        result.append(.init(id: role + ".headers", label: .init(zhHans: isRequest ? "请求头" : "响应头", en: isRequest ? "Request headers" : "Response headers"), fields: pairs(message.headers, header: true)))
        var bodyFields: [APIField] = []
        var state = message.body.state.rawValue
        if let text = message.body.text {
            guard text.utf8.count <= bodyByteLimit else { throw APIImportError.bodyLimit }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let mime = lower(message.body.mimeType ?? "").split(separator: ";").first.map(String.init) ?? ""
            if !text.isEmpty && (mime == "application/json" || mime.hasSuffix("+json") || (mime.isEmpty && (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")))) {
                var parser = APIJSONReader(text); let value = try parser.parse(); state = "json"
                try flatten(value, path: "", inheritedSensitive: false, into: &bodyFields)
            } else if !text.isEmpty { bodyFields.append(.init(key: "$text", label: "Body", type: "text", value: text)) }
        }
        bodyFields.insert(.init(key: "$state", label: "Body availability", type: "bodyState", value: state), at: 0)
        result.append(.init(id: role + ".body", label: .init(zhHans: isRequest ? "请求正文" : "响应正文", en: isRequest ? "Request body" : "Response body"), fields: bodyFields))
        return result
    }
    private static func flatten(_ node: APIJSONNode, path: String, inheritedSensitive: Bool, into fields: inout [APIField]) throws {
        try Task.checkCancellation()
        guard fields.count < 5_000 else { throw APIImportError.fieldLimit }
        let type: String; let value: String
        switch node {
        case .object: type = "object"; value = ""
        case .array: type = "array"; value = ""
        case .string(let item): type = "string"; value = item
        case .number(let item): type = "number"; value = item
        case .bool(let item): type = "bool"; value = item ? "true" : "false"
        case .null: type = "null"; value = "null"
        }
        fields.append(.init(key: path, label: path.isEmpty ? "$" : path, type: type, value: value, sensitive: inheritedSensitive))
        switch node {
        case .object(let items): for (key, item) in items { try flatten(item, path: path + "/" + pointer(key), inheritedSensitive: inheritedSensitive || sensitive(key), into: &fields) }
        case .array(let items): for (index, item) in items.enumerated() { try flatten(item, path: path + "/\(index)", inheritedSensitive: inheritedSensitive, into: &fields) }
        default: break
        }
    }
}

private extension APIImporter {
    static func body(_ text: String?, mime: String?, unsupported: Bool = false) throws -> APIBody {
        if unsupported { return .init(state: .unsupported, mimeType: mime) }
        guard let text else { return .init(state: .missing, mimeType: mime) }
        guard text.utf8.count <= bodyByteLimit else { throw APIImportError.bodyLimit }
        let media = (mime ?? "").lowercased().split(separator: ";").first.map(String.init) ?? ""
        if !text.isEmpty && !media.isEmpty && !(media.hasPrefix("text/") || media.hasSuffix("+json") || media.hasSuffix("+xml") ||
            ["application/json", "application/xml", "application/x-www-form-urlencoded", "application/javascript", "application/graphql", "application/ndjson", "application/x-ndjson"].contains(media)) {
            return .init(state: .unsupported, mimeType: mime)
        }
        return .init(state: text.isEmpty ? .empty : .text, text: text, mimeType: mime)
    }
    static func parseHTTP(_ source: String) throws -> APIExchange {
        let first = try httpMessage(source)
        if first.message.method != nil, let rest = first.remaining {
            let second = try httpMessage(rest)
            guard second.message.statusCode != nil, second.remaining == nil else { throw APIImportError.invalidHTTP }
            return try exchange(request: first.message, response: second.message)
        }
        guard first.remaining == nil else { throw APIImportError.invalidHTTP }
        return try exchange(request: first.message.method != nil ? first.message : nil,
                            response: first.message.statusCode != nil ? first.message : nil)
    }
    static func httpMessage(_ text: String) throws -> (message: APIMessage, remaining: String?) {
        guard !text.isEmpty, !text.contains("\0") else { throw APIImportError.invalidHTTP }
        let divider = [text.range(of: "\r\n\r\n"), text.range(of: "\n\n")].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
        let head = divider.map { String(text[..<$0.lowerBound]) } ?? text
        var content = divider.map { String(text[$0.upperBound...]) }
        var headerCount = 0
        for (offset, byte) in head.utf8.enumerated() {
            if offset % 4096 == 0 { try Task.checkCancellation() }
            if byte == 10 { headerCount += 1 }
            guard headerCount <= 5_000 else { throw APIImportError.fieldLimit }
        }
        let lines = head.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let first = lines.first else { throw APIImportError.invalidHTTP }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { throw APIImportError.invalidHTTP }
        let response = parts[0].hasPrefix("HTTP/")
        let version: String; let method: String?; let url: String?; let status: String?; let statusText: String?
        if response {
            guard parts[1].count == 3, parts[1].utf8.allSatisfy({ (48...57).contains($0) }) else { throw APIImportError.invalidHTTP }
            version = parts[0]; method = nil; url = nil; status = parts[1]; statusText = parts.count == 3 ? parts[2] : ""
        } else {
            guard parts.count == 3, parts[2].hasPrefix("HTTP/"), token(parts[0]), !parts[1].isEmpty else { throw APIImportError.unsupportedFormat }
            method = parts[0]; url = parts[1]; version = parts[2]; status = nil; statusText = nil
        }
        guard ["HTTP/0.9", "HTTP/1.0", "HTTP/1.1", "HTTP/2", "HTTP/2.0", "HTTP/3", "HTTP/3.0"].contains(version) else { throw APIImportError.invalidHTTP }
        var headers: [APIHeader] = []
        for line in lines.dropFirst() {
            try Task.checkCancellation()
            guard headers.count < 5_000 else { throw APIImportError.fieldLimit }
            guard let colon = line.firstIndex(of: ":"), token(String(line[..<colon])) else { throw APIImportError.invalidHTTP }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !value.contains("\r") else { throw APIImportError.invalidHTTP }
            headers.append(.init(name: String(line[..<colon]), value: value))
        }
        let lengths = headers.filter { lower($0.name) == "content-length" }
        guard lengths.count <= 1 else { throw APIImportError.invalidHTTP }
        var remaining: String?
        if let length = lengths.first {
            guard let count = Int(length.value), count >= 0, count <= bodyByteLimit else { throw APIImportError.invalidHTTP }
            let bytes = Array((content ?? "").utf8)
            guard bytes.count >= count else { throw APIImportError.invalidHTTP }
            guard let bodyText = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw APIImportError.invalidUTF8 }
            content = bodyText
            var rest = String(decoding: bytes.dropFirst(count), as: UTF8.self)
            // Only separators before the next start line are removed. Its body may
            // legitimately end with whitespace, including bytes counted by Content-Length.
            while rest.hasPrefix("\r\n") || rest.hasPrefix("\n") { rest.removeFirst() }
            if !rest.isEmpty { guard !response, rest.hasPrefix("HTTP/") else { throw APIImportError.invalidHTTP }; remaining = rest }
        } else if !response, ["GET", "HEAD"].contains(method ?? ""), let text = content, text.hasPrefix("HTTP/") {
            remaining = text; content = ""
        }
        let mime = headers.first { lower($0.name) == "content-type" }?.value
        // Raw transfer/content coding cannot be interpreted as decoded body text.
        let unsupported = headers.contains { (lower($0.name) == "transfer-encoding" || lower($0.name) == "content-encoding") && lower($0.value) != "identity" }
        guard lengths.isEmpty || !headers.contains(where: { lower($0.name) == "transfer-encoding" }) else { throw APIImportError.invalidHTTP }
        return (.init(method: method, url: url, httpVersion: version, statusCode: status, statusText: statusText,
                      headers: headers, body: try body(content, mime: mime, unsupported: unsupported)), remaining)
    }
    static func token(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || Array("!#$%&'*+-.^_`|~".utf8).contains($0) }
    }
    static func parseHAR(_ source: String) throws -> [APIExchange] {
        var parser = APIJSONReader(source); let root = try parser.parse()
        guard let log = root["log"], log["version"]?.string == "1.2", let entries = log["entries"]?.array, !entries.isEmpty else { throw APIImportError.invalidHAR }
        guard entries.count <= 500 else { throw APIImportError.entryLimit }
        return try entries.enumerated().map { index, entry in
            try Task.checkCancellation()
            guard let request = entry["request"], let response = entry["response"],
                  let method = request["method"]?.string, token(method), let url = request["url"]?.string,
                  let code = response["status"]?.number, Int(code) != nil else { throw APIImportError.invalidHAR }
            guard let address = URLComponents(string: url), ["http", "https"].contains(address.scheme?.lowercased() ?? ""),
                  address.host != nil, !url.contains("\r"), !url.contains("\n") else { throw APIImportError.invalidHAR }
            let requestHeaders = try harPairs(request["headers"])
            let responseHeaders = try harPairs(response["headers"])
            let postData = request["postData"]
            let requestBody: APIBody
            if let postData {
                guard postData["text"] == nil || postData["text"]?.string != nil,
                      postData["mimeType"] == nil || postData["mimeType"]?.string != nil else { throw APIImportError.invalidHAR }
                requestBody = try body(postData["text"]?.string, mime: postData["mimeType"]?.string,
                                       unsupported: postData["text"] == nil && postData["params"] != nil)
            } else { requestBody = .init(state: .missing) }
            let content = response["content"]
            guard content?["text"] == nil || content?["text"]?.string != nil,
                  content?["encoding"] == nil || content?["encoding"]?.string != nil,
                  content?["mimeType"] == nil || content?["mimeType"]?.string != nil else { throw APIImportError.invalidHAR }
            let mime = content?["mimeType"]?.string
            let responseBody: APIBody
            if let encoded = content?["text"]?.string {
                if let encoding = content?["encoding"]?.string, !encoding.isEmpty {
                    if encoding == "base64", let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8) {
                        responseBody = try body(text, mime: mime)
                    } else { responseBody = .init(state: .unsupported, mimeType: mime) }
                } else { responseBody = try body(encoded, mime: mime) }
            } else { responseBody = .init(state: .missing, mimeType: mime) }
            let req = APIMessage(method: method, url: url, httpVersion: request["httpVersion"]?.string,
                                 headers: requestHeaders, body: requestBody)
            let res = APIMessage(httpVersion: response["httpVersion"]?.string, statusCode: code,
                                 statusText: response["statusText"]?.string, headers: responseHeaders, body: responseBody)
            // The URL is authoritative: HAR queryString can be decoded differently by exporters.
            let stamp = entry["startedDateTime"]?.string.map { " · " + $0 } ?? ""
            return try exchange(id: String(index), name: "\(index + 1). \(method) \(displayURL(url))\(stamp)", request: req, response: res)
        }
    }
    static func harPairs(_ node: APIJSONNode?) throws -> [APIHeader] {
        guard let items = node?.array else { throw APIImportError.invalidHAR }
        return try items.map {
            guard let name = $0["name"]?.string, token(name), let value = $0["value"]?.string,
                  !value.contains("\r"), !value.contains("\n") else { throw APIImportError.invalidHAR }
            return APIHeader(name: name, value: value)
        }
    }
    static func parseCurl(_ source: String) throws -> APIExchange {
        let words = try curlWords(source)
        guard words.first == "curl" else { throw APIImportError.invalidCurl }
        var index = 1; var url: String?; var method: String?; var headers: [APIHeader] = []
        var data: [String] = []; var useGet = false; var head = false; var json = false; var nonJSONData = false
        var globOff = false
        var diagnostics: [PluginLocalizedText] = []
        func setURL(_ value: String) throws {
            guard url == nil, let parsed = URLComponents(string: value), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host != nil, parsed.fragment == nil, !value.contains("\r"), !value.contains("\n") else { throw APIImportError.invalidCurl }
            url = value
        }
        while index < words.count {
            try Task.checkCancellation()
            let word = words[index]; index += 1
            var option = word; var attached: String?
            if word.hasPrefix("--"), let equal = word.firstIndex(of: "=") {
                option = String(word[..<equal]); attached = String(word[word.index(after: equal)...])
            } else if word.count > 2, word.hasPrefix("-"), !word.hasPrefix("--"), ["-X", "-H", "-d", "-u", "-b"].contains(String(word.prefix(2))) {
                option = String(word.prefix(2)); attached = String(word.dropFirst(2))
            }
            func argument() throws -> String {
                if let attached { return attached }
                guard index < words.count else { throw APIImportError.invalidCurl }
                let result = words[index]; index += 1; return result
            }
            switch option {
            case "-X", "--request":
                let value = try argument(); guard token(value), method == nil else { throw APIImportError.invalidCurl }; method = value
            case "--url": try setURL(argument())
            case "-H", "--header":
                let value = try argument()
                guard !value.hasPrefix("@") else { throw APIImportError.externalCurlData }
                guard let colon = value.firstIndex(of: ":"), token(String(value[..<colon])), !value.contains("\r"), !value.contains("\n") else { throw APIImportError.invalidCurl }
                let name = String(value[..<colon]); let headerValue = value[value.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                // curl's empty-header syntax suppresses a header; it does not send an empty value.
                guard !headerValue.isEmpty else { throw APIImportError.unsupportedCurlOption("--header (empty value)") }
                headers.append(.init(name: name, value: headerValue))
            case "-d", "--data", "--data-binary", "--data-raw", "--json":
                let value = try argument()
                guard option == "--data-raw" || !value.hasPrefix("@") else { throw APIImportError.externalCurlData }
                if option == "--json" { guard !nonJSONData else { throw APIImportError.unsupportedCurlOption("mixed --json and --data") }; json = true }
                else { guard !json else { throw APIImportError.unsupportedCurlOption("mixed --json and --data") }; nonJSONData = true }
                data.append(value)
            case "-G", "--get": guard attached == nil else { throw APIImportError.invalidCurl }; useGet = true
            case "-I", "--head": guard attached == nil else { throw APIImportError.invalidCurl }; head = true
            case "-g", "--globoff": guard attached == nil else { throw APIImportError.invalidCurl }; globOff = true
            case "-u", "--user":
                let value = try argument()
                guard value.contains(":"), !value.contains("\r"), !value.contains("\n") else { throw APIImportError.unsupportedCurlOption("--user (interactive password)") }
                headers.append(.init(name: "Authorization", value: "Basic " + Data(value.utf8).base64EncodedString()))
            case "--oauth2-bearer":
                let value = try argument(); guard !value.contains("\r"), !value.contains("\n") else { throw APIImportError.invalidCurl }
                headers.append(.init(name: "Authorization", value: "Bearer " + value))
            case "-b", "--cookie":
                let value = try argument(); guard value.contains("="), !value.hasPrefix("@") else { throw APIImportError.externalCurlData }
                guard !value.contains("\r"), !value.contains("\n") else { throw APIImportError.invalidCurl }
                headers.append(.init(name: "Cookie", value: value))
            case "--compressed", "-s", "--silent", "-S", "--show-error", "-i", "--include", "-k", "--insecure", "--http1.1", "--http2", "--http3":
                guard attached == nil else { throw APIImportError.invalidCurl }
                if diagnostics.isEmpty { diagnostics.append(.init(zhHans: "仅比较命令中明确提供的请求信息；未执行请求，传输设置与自动生成的请求头未纳入。", en: "Only explicitly supplied request data is compared. The command was not executed; transport settings and automatically generated headers are not included.")) }
            case "--":
                guard attached == nil, index == words.count - 1 else { throw APIImportError.invalidCurl }
                try setURL(words[index]); index += 1
            default:
                if word.hasPrefix("-") { throw APIImportError.unsupportedCurlOption(option) }
                try setURL(word)
            }
        }
        guard var target = url, !(head && !data.isEmpty), !(json && useGet) else { throw APIImportError.invalidCurl }
        target = try curlSingleURL(target, globOff: globOff)
        let combined = data.joined(separator: json ? "" : "&")
        if useGet, !data.isEmpty { target += target.contains("?") ? "&" + combined : "?" + combined }
        if !data.isEmpty && !useGet && !headers.contains(where: { lower($0.name) == "content-type" }) {
            headers.append(.init(name: "Content-Type", value: json ? "application/json" : "application/x-www-form-urlencoded"))
        }
        if json && !headers.contains(where: { lower($0.name) == "accept" }) { headers.append(.init(name: "Accept", value: "application/json")) }
        let verb = method ?? (head ? "HEAD" : (useGet || data.isEmpty ? "GET" : "POST"))
        let content = try body(data.isEmpty || useGet ? nil : combined, mime: headers.first { lower($0.name) == "content-type" }?.value)
        if diagnostics.isEmpty { diagnostics.append(.init(zhHans: "cURL 仅作文本导入，未发送请求。自动生成的请求头未纳入比较。", en: "cURL is imported as text; no request was sent. Automatically generated headers are not compared.")) }
        return try exchange(request: .init(method: verb, url: target, headers: headers, body: content), response: nil, diagnostics: diagnostics)
    }
    /// Shell quoting does not disable curl's own URL globbing. This importer only
    /// models one request, so a possible expansion must never become a literal URL.
    static func curlSingleURL(_ value: String, globOff: Bool) throws -> String {
        guard !globOff else { return value }
        guard let scheme = value.range(of: "://") else { throw APIImportError.invalidCurl }
        let authorityEnd = value[scheme.upperBound...].firstIndex { $0 == "/" || $0 == "?" } ?? value.endIndex
        let authority = value[scheme.upperBound..<authorityEnd]
        // Brackets around an IPv6 host are URI syntax. Other authority expansion
        // forms are unsupported; credentials containing them need --globoff too.
        let host = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? authority
        var ipv6 = false
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let address = String(host[host.index(after: host.startIndex)..<close]).components(separatedBy: "%")[0]
            var bytes = in6_addr()
            let port = host[host.index(after: close)...]
            ipv6 = address.withCString { inet_pton(AF_INET6, $0, &bytes) == 1 }
                && (port.isEmpty || port.hasPrefix(":") && !port.dropFirst().isEmpty && port.dropFirst().utf8.allSatisfy { (48...57).contains($0) })
        }
        guard !authority.contains("{") && !authority.contains("}"),
              (!authority.contains("[") && !authority.contains("]")) || ipv6 && !authority.dropLast(host.count).contains(where: { $0 == "[" || $0 == "]" }) else {
            throw APIImportError.curlURLGlobbing
        }
        let characters = Array(value[authorityEnd...]); var index = 0; var suffix = ""
        while index < characters.count {
            let character = characters[index]; index += 1
            if character == "\\", index < characters.count, ["[", "]", "{", "}"].contains(characters[index]) {
                suffix.append(characters[index]); index += 1; continue
            }
            guard !["[", "]", "{", "}"].contains(character) else {
                throw APIImportError.curlURLGlobbing
            }
            suffix.append(character)
        }
        return String(value[..<authorityEnd]) + suffix
    }
    /// Tokenizes a deliberately bounded shell subset. Never evaluates commands, variables, or files.
    static func curlWords(_ source: String) throws -> [String] {
        let chars = Array(source); var index = 0; var words: [String] = []; var current = ""; var active = false
        var quote: Character?
        while index < chars.count {
            if index % 4096 == 0 { try Task.checkCancellation() }
            let char = chars[index]; index += 1
            if quote == "'" {
                if char == "'" { quote = nil } else { current.append(char) }; continue
            }
            if char == "\\" {
                guard index < chars.count else { throw APIImportError.invalidCurl }
                let next = chars[index]; index += 1
                if next == "\n" { continue }
                if next == "\r", index < chars.count, chars[index] == "\n" { index += 1; continue }
                if quote == "\"", !["$", "`", "\"", "\\"].contains(next) { current.append("\\") }
                current.append(next); active = true; continue
            }
            if char == "$" || char == "`" { throw APIImportError.shellExpansion }
            if quote == "\"" {
                if char == "\"" { quote = nil } else { current.append(char) }; continue
            }
            if char == "'" || char == "\"" { quote = char; active = true; continue }
            if char.isWhitespace {
                if active {
                    guard words.count < 20_000 else { throw APIImportError.curlTokenLimit }
                    words.append(current); current = ""; active = false
                }
                continue
            }
            guard ![";", "|", "&", ">", "<", "(", ")", "{", "}", "*", "?", "[", "]", "~"].contains(char) else {
                throw APIImportError.shellExpansion
            }
            current.append(char); active = true
        }
        guard quote == nil else { throw APIImportError.invalidCurl }
        if active {
            guard words.count < 20_000 else { throw APIImportError.curlTokenLimit }
            words.append(current)
        }
        return words
    }
}
