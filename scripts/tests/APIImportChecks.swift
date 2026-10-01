import Foundation
import CrossDiffCore

@main enum APIImportChecks {
    struct Failure: Error { let message: String }
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }; count += 1
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { count += 1; return }; throw Failure(message: message)
    }
    static func main() async {
        do {
            try run()
            let task = Task { try await Task.sleep(nanoseconds: 10_000_000_000); return try APIImporter.parse("GET / HTTP/1.1\n\n") }
            task.cancel()
            do { _ = try await task.value; throw Failure(message: "Cancelled task must fail") }
            catch is CancellationError { count += 1 }
            // Cancellation is checked by the synchronous entry point itself, not just an async caller.
            let cancelledImport = Task { () throws -> APIImportDocument in
                withUnsafeCurrentTask { $0?.cancel() }
                return try APIImporter.parse("GET / HTTP/1.1\n\n")
            }
            do { _ = try await cancelledImport.value; throw Failure(message: "Importer must observe cancellation") }
            catch is CancellationError { count += 1 }
            print("PASS: \(count) API import checks")
        } catch { print("FAIL after \(count) checks: \(error)"); exit(1) }
    }
    static func run() throws {
        let raw = "POST /users?tag=a&tag=b HTTP/1.1\r\nHost: example.test\r\nX-ID: one\r\nx-id: two\r\nContent-Type: application/json\r\n\r\n{\"n\":9007199254740993,\"a\":null,\"b\":[]}"
        let document = try APIImporter.parse(raw)
        let exchange = document.exchanges[0]
        try check(document.source == raw && document.format == .http, "Source remains byte-equivalent UTF-8")
        try check(exchange.request?.headers.count == 4, "Duplicate headers are preserved")
        try check(exchange.sections.first { $0.id == "request.query" }?.fields.count == 2, "Duplicate query values are preserved")
        let fields = exchange.sections.first { $0.id == "request.body" }!.fields
        try check(fields.first { $0.key == "/n" }?.value == "9007199254740993", "Large JSON integers retain exact lexical value")
        try check(fields.first { $0.key == "/a" }?.type == "null", "Null retains type")
        try check(fields.first { $0.key == "/b" }?.type == "array", "Empty arrays retain structure")
        func http(_ text: String, mime: String = "application/json") throws -> APIExchange {
            try APIImporter.parse("HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\n\r\n" + text).exchanges[0]
        }
        func bodyFields(_ exchange: APIExchange, role: String = "response") -> [APIField] {
            exchange.sections.first { $0.id == role + ".body" }!.fields
        }
        let precise = try bodyFields(http("{\"n\":0.123456789012345678901,\"escaped/key~\":\"中👩🏽‍💻\\n\",\"bool\":false}"))
        try check(precise.first { $0.key == "/n" }?.value == "0.123456789012345678901", "Decimal digits are not rounded")
        try check(precise.first { $0.key == "/escaped~1key~0" }?.value == "中👩🏽‍💻\n", "JSON pointers and Unicode decoding preserve identity")
        try check(precise.first { $0.key == "/bool" }?.type == "bool", "Boolean remains separate from number")
        let array = try bodyFields(http("[1,2]"))
        try check(array.first { $0.key == "/0" }?.value == "1" && array.first { $0.key == "/1" }?.value == "2", "Array order remains positional")
        try check(array.first { $0.key == "" }?.value == "", "Container markers do not duplicate child counts")
        for invalid in ["{\"x\":1,\"x\":2}", "{\"x\":1,\"\\u0078\":2}", "[01]", "[1.]", "[1e]", "[NaN]", "[true,]", "{\"x\":\"\\ud800\"}"] {
            try rejects("Invalid or ambiguous JSON must not compare as known data") { _ = try http(invalid) }
        }
        try rejects("JSON nesting is bounded") { _ = try http(String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)) }
        try rejects("Flattened output is bounded") { _ = try http("[" + Array(repeating: "0", count: 5000).joined(separator: ",") + "]") }
        try rejects("Body byte budget is enforced") { _ = try http(String(repeating: "a", count: APIImporter.bodyByteLimit + 1), mime: "text/plain") }
        try rejects("Source byte budget is enforced") { _ = try APIImporter.parse(String(repeating: "a", count: APIImporter.sourceByteLimit + 1)) }
        let unicodeBudget = String(repeating: "中", count: APIImporter.bodyByteLimit / 3 + 1)
        try rejects("Budgets count UTF-8 bytes, not characters") { _ = try http(unicodeBudget, mime: "text/plain") }
        let plain = try http("{not JSON", mime: "text/plain")
        try check(bodyFields(plain).last?.value == "{not JSON", "Explicit plain text is not misclassified as malformed JSON")
        try check(bodyFields(try http("{ user { name } }", mime: "application/graphql")).last?.type == "text", "GraphQL braces do not imply JSON")
        let exactKeys = bodyFields(try http("{\"é\":1,\"e\\u0301\":2}"))
        try check(exactKeys.filter { $0.type == "number" }.count == 2, "Canonically equivalent but byte-distinct JSON keys are legal and distinct")
        let unicodeQuery = try APIImporter.parse("GET /?é=1&e\u{0301}=2&é=3 HTTP/1.1\n\n").exchanges[0].sections.first { $0.id == "request.query" }!.fields
        try check(unicodeQuery.map(\.key).map { Data($0.utf8) } == ["/é/0", "/e\u{0301}/0", "/é/1"].map { Data($0.utf8) }, "Query occurrence numbering uses exact Unicode names")
        try check(bodyFields(try http("abc", mime: "image/png")).first?.value == "unsupported", "Binary MIME remains unknown even when its bytes are UTF-8")
        let empty = try APIImporter.parse("HTTP/1.1 204 No Content\r\n\r\n").exchanges[0]
        let absent = try APIImporter.parse("HTTP/1.1 200 OK").exchanges[0]
        try check(bodyFields(empty).first?.value == "empty" && bodyFields(absent).first?.value == "missing", "Missing and explicit empty bodies differ")
        let pairText = "POST /example HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]"
        let paired = try APIImporter.parse(pairText).exchanges[0]
        try check(paired.request?.body.text == "{}" && paired.response?.body.text == "[]", "Byte-framed request and response pair correctly")
        let newlinePair = try APIImporter.parse("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabc\n").exchanges[0]
        try check(newlinePair.response?.body.text == "abc\n", "Paired response preserves Content-Length-counted terminal newline")
        let unframedPair = try APIImporter.parse("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\n\r\nabc \n").exchanges[0]
        try check(unframedPair.response?.body.text == "abc \n", "Unframed paired response preserves terminal spaces and newline")
        let getPair = try APIImporter.parse("GET / HTTP/1.1\n\nHTTP/2 201\n\nhello").exchanges[0]
        try check(getPair.request != nil && getPair.response?.statusCode == "201", "Simple GET/response pairs import")
        try rejects("Truncated Content-Length is not accepted") { _ = try APIImporter.parse("HTTP/1.1 200 OK\nContent-Length: 10\n\na") }
        try rejects("Ambiguous duplicate lengths fail") { _ = try APIImporter.parse("HTTP/1.1 200 OK\nContent-Length: 0\nContent-Length: 0\n\n") }
        try rejects("Transfer-Encoding plus Content-Length fails") { _ = try APIImporter.parse("HTTP/1.1 200 OK\nContent-Length: 0\nTransfer-Encoding: chunked\n\n") }
        let chunked = try APIImporter.parse("HTTP/1.1 200 OK\nTransfer-Encoding: chunked\n\n3\r\nabc\r\n0\r\n\r\n").exchanges[0]
        try check(chunked.response?.body.state == .unsupported, "Undecoded HTTP transfer coding is explicit unknown")
        let curl = try APIImporter.parse("curl 'https://example.test/a?q=a&q=b&flag&empty=' \\\n -H 'Authorization: Bearer fixture-only' -H 'X-ID: one' -H 'x-id: two' --json '{\"n\":9007199254740993}'")
        let curlEntry = curl.exchanges[0]
        try check(curl.format == .curl && curlEntry.request?.method == "POST", "cURL JSON infers POST without running anything")
        try check(bodyFields(curlEntry, role: "request").first { $0.key == "/n" }?.value == "9007199254740993", "cURL JSON keeps large numbers")
        let curlHeaders = curlEntry.sections.first { $0.id == "request.headers" }!.fields
        try check(curlHeaders.filter { $0.key.hasPrefix("/x-id/") }.count == 2, "Header case folding preserves repeat occurrences")
        try check(curlHeaders.first { $0.name == "Authorization" }?.sensitive == true, "Credentials carry display masking metadata")
        let curlQuery = curlEntry.sections.first { $0.id == "request.query" }!.fields
        try check(curlQuery.first { $0.name == "flag" }?.type == "flag" && curlQuery.first { $0.name == "empty" }?.type == "string", "Query flags differ from explicit empty values")
        let getCurl = try APIImporter.parse("curl --get --data 'a=1' --data 'a=2' 'https://example.test/'").exchanges[0]
        try check(getCurl.request?.url == "https://example.test/?a=1&a=2" && getCurl.request?.method == "GET", "cURL GET moves literal data into query")
        let rawAt = try APIImporter.parse("curl 'https://example.test/' --data-raw '@literal'").exchanges[0]
        try check(rawAt.request?.body.text == "@literal", "data-raw @ is literal rather than a file read")
        let literalShell = try APIImporter.parse("curl 'https://example.test/' --data-raw '$(not-executed)' ").exchanges[0]
        try check(literalShell.request?.body.text == "$(not-executed)", "Single-quoted shell syntax remains inert text")
        for target in ["https://example.test/items/[1-3]", "https://example.test/items/{one,two}", "https://example.test/?page=[1-3]"] {
            try rejects("cURL URL globbing must not silently become one literal request") { _ = try APIImporter.parse("curl '\(target)'") }
            let prefix = try APIImporter.parse("curl --globoff '\(target)'").exchanges[0]
            let suffix = try APIImporter.parse("curl '\(target)' -g").exchanges[0]
            try check(prefix.request?.url == target && suffix.request?.url == target, "Explicit globoff works before or after URL")
        }
        let ipv6 = try APIImporter.parse("curl 'https://[::1]:8443/items'").exchanges[0]
        try check(ipv6.request?.url == "https://[::1]:8443/items", "IPv6 authority brackets are not glob syntax")
        try rejects("IPv6 authority does not disable path globbing") { _ = try APIImporter.parse("curl 'https://[::1]:8443/items/[1-3]'") }
        let escapedGlob = try APIImporter.parse("curl 'https://example.test/items/\\[one\\]'").exchanges[0]
        try check(escapedGlob.request?.url == "https://example.test/items/[one]", "Quoted curl glob escapes become literal URL characters")
        for command in ["curl 'https://example.test/' --data '@secret'", "curl 'https://example.test/' --data-binary '@secret'", "curl 'https://example.test/' -H '@headers'", "curl 'https://example.test/' -b cookies.txt", "curl 'https://example.test/' -F 'upload=@file'", "curl 'https://example.test/' --output result", "curl 'https://example.test/' --unknown", "curl \"https://example.test/$TOKEN\"", "curl 'https://example.test/' ; touch never", "curl 'https://example.test/' | cat", "curl 'https://example.test/' --data-raw $'escaped'", "curl 'https://one.test/' 'https://two.test/'"] {
            try rejects("Unsafe or unsupported cURL form must be refused") { _ = try APIImporter.parse(command) }
        }
        func har(_ body: [String: Any], count: Int = 1) throws -> String {
            let entries: [[String: Any]] = (0..<count).map { index in
                ["startedDateTime": "2026-01-01T00:00:00.000Z", "request": ["method": "GET", "url": "https://example.test/\(index)", "httpVersion": "HTTP/2", "headers": [["name": "X-ID", "value": "a"], ["name": "x-id", "value": "b"]]],
                 "response": ["status": 200, "statusText": "OK", "httpVersion": "HTTP/2", "headers": [], "content": body]]
            }
            return String(data: try JSONSerialization.data(withJSONObject: ["log": ["version": "1.2", "entries": entries]]), encoding: .utf8)!
        }
        let harDocument = try APIImporter.parse(har(["mimeType": "application/json", "text": "{\"n\":9007199254740993}"], count: 2))
        try check(harDocument.format == .har && harDocument.exchanges.map(\.id) == ["0", "1"], "HAR order and stable selection IDs are preserved")
        try check(harDocument.exchanges[1].request?.url == "https://example.test/1", "HAR entries remain independently selectable")
        try check(bodyFields(harDocument.exchanges[0]).first { $0.key == "/n" }?.value == "9007199254740993", "HAR body text remains lossless")
        let base64 = try APIImporter.parse(har(["mimeType": "text/plain", "encoding": "base64", "text": Data("你好".utf8).base64EncodedString()])).exchanges[0]
        try check(base64.response?.body.text == "你好", "HAR base64 UTF-8 text decodes locally")
        let binary = try APIImporter.parse(har(["mimeType": "application/octet-stream", "encoding": "base64", "text": Data([0xFF, 0xD8]).base64EncodedString()])).exchanges[0]
        try check(binary.response?.body.state == .unsupported, "Binary HAR body cannot silently become empty")
        let missingHAR = try APIImporter.parse(har(["mimeType": "text/plain", "size": 17])).exchanges[0]
        let emptyHAR = try APIImporter.parse(har(["mimeType": "text/plain", "text": ""])).exchanges[0]
        try check(missingHAR.response?.body.state == .missing && emptyHAR.response?.body.state == .empty, "HAR omitted body and empty body are distinct")
        try rejects("HAR entry count is bounded") { _ = try APIImporter.parse(har(["text": ""], count: 501)) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = root.appendingPathComponent(".build-api-import-checks/fixtures")
        let file = fixtures.appendingPathComponent("sample.http")
        try Data(raw.utf8).write(to: file)
        try check(try APIImporter.load(file).source == raw, "Bounded FD reader preserves file contents")
        let invalidFile = fixtures.appendingPathComponent("invalid.http")
        try Data([0xFF]).write(to: invalidFile)
        try rejects("Non-UTF8 file is rejected") { _ = try APIImporter.load(invalidFile) }
        let symlink = fixtures.appendingPathComponent("symlink.http")
        try? FileManager.default.removeItem(at: symlink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        try rejects("Symlink is not followed") { _ = try APIImporter.load(symlink) }
        try rejects("Directory is not treated as a regular file") { _ = try APIImporter.load(fixtures) }
        try check(try Data(contentsOf: file) == Data(raw.utf8), "Read-only import never modifies source")
        let titled = try APIImporter.parse("curl 'https://example:x@localhost.test/a?token=fixture-only'").exchanges[0]
        try check(!titled.name.contains("fixture-only") && !titled.name.contains("example:"), "Exchange picker labels exclude URL user info and query values")
        try rejects("Large JSON key cannot flood the structured view") { _ = try http("{\"" + String(repeating: "k", count: 16_385) + "\":1}") }
        try rejects("Mixed cURL data modes are not guessed") { _ = try APIImporter.parse("curl 'https://example.test/' --json '{}' --data x") }
        try rejects("Malformed HAR content text is not treated as absent") { _ = try APIImporter.parse(har(["mimeType": "text/plain", "text": 12])) }
        try rejects("Malformed HAR encoding is not treated as identity") { _ = try APIImporter.parse(har(["mimeType": "text/plain", "text": "example", "encoding": 2])) }
        let largeFile = fixtures.appendingPathComponent("oversized.http")
        try Data(repeating: 65, count: APIImporter.sourceByteLimit + 1).write(to: largeFile)
        try rejects("Oversized file is rejected before allocation") { _ = try APIImporter.load(largeFile) }
        try rejects("Non-file URL never triggers a network load") { _ = try APIImporter.load(URL(string: "https://example.test/record.har")!) }
        let allowedHeaders = "GET / HTTP/1.1\n" + String(repeating: "X: v\n", count: 4_996) + "\n"
        try check(try APIImporter.parse(allowedHeaders).exchanges[0].sections.reduce(0, { $0 + $1.fields.count }) == 5_000,
                  "The total 5,000-field boundary remains accepted")
        try rejects("Total field budget also includes summaries and body state") {
            _ = try APIImporter.parse("GET / HTTP/1.1\n" + String(repeating: "X: v\n", count: 4_997) + "\n")
        }
        let largeQueryPrefix = "GET /?", largeQuerySuffix = " HTTP/1.1\n\n"
        let largeQuery = largeQueryPrefix + String(repeating: "x&", count: (APIImporter.sourceByteLimit - largeQueryPrefix.utf8.count - largeQuerySuffix.utf8.count) / 2) + largeQuerySuffix
        let largeHeadersPrefix = "GET / HTTP/1.1\n", largeHeadersSuffix = "\n"
        let largeHeaders = largeHeadersPrefix + String(repeating: "X:v\n", count: (APIImporter.sourceByteLimit - largeHeadersPrefix.utf8.count - largeHeadersSuffix.utf8.count) / 4) + largeHeadersSuffix
        let largeCurlPrefix = "curl 'https://example.test/'"
        let largeCurl = largeCurlPrefix + String(repeating: " -s", count: (APIImporter.sourceByteLimit - largeCurlPrefix.utf8.count) / 3)
        let boundStart = Date()
        for (record, expected) in [(largeQuery, APIImportError.fieldLimit), (largeHeaders, .fieldLimit), (largeCurl, .curlTokenLimit)] {
            do { _ = try APIImporter.parse(record); throw Failure(message: "Dense inputs must be rejected before constructing unbounded collections") }
            catch let error as APIImportError {
                try check(error == expected, "Dense input must report its explicit field or token limit")
            }
        }
        let boundedElapsed = Date().timeIntervalSince(boundStart)
        try check(boundedElapsed < 10, "Dense 4 MiB inputs must fail promptly")
        print(String(format: "Bounded dense-input rejection: %.3f s", boundedElapsed))
    }
}
