import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private static let lock = NSLock()
    private static var paths: Set<String> = []
    static func started(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return paths.contains(path)
    }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); Self.paths.insert(path); Self.lock.unlock()
        if path == "/waiting" || path == "/cancel-before-start" { return }
        if path == "/redirect" {
            let target = URL(string: "http://plugin.invalid/downgraded")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let headers = path == "/declared-too-large" ? ["Content-Length": "16777217"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "/not-found" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/stream-too-large" || path == "/exact-limit" {
            let chunk = Data(repeating: 65, count: 1024 * 1024)
            for _ in 0..<16 { client?.urlProtocol(self, didLoad: chunk) }
            if path == "/stream-too-large" { client?.urlProtocol(self, didLoad: Data([66])) }
        } else {
            client?.urlProtocol(self, didLoad: Data("plugin-".utf8))
            client?.urlProtocol(self, didLoad: Data("payload".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main
private enum PluginDownloadChecks {
    static func main() async {
        do {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FixtureProtocol.self]
            let data = try await PluginDownload.fetch(URL(string: "https://plugin.invalid/success")!, configuration: config)
            try expect(data == Data("plugin-payload".utf8), "Successful download must preserve all response chunks")
            print("PASS: offline HTTPS download preserves streamed response bytes")
            do {
                _ = try await PluginDownload.fetch(URL(string: "http://plugin.invalid/success")!, configuration: config)
                throw CheckFailure(description: "Downloader must reject HTTP before starting transport")
            } catch let failure as CheckFailure { throw failure }
            catch { print("PASS: direct HTTP URLs are rejected before transport") }
            for path in ["not-found", "declared-too-large", "stream-too-large", "redirect"] {
                do {
                    _ = try await PluginDownload.fetch(URL(string: "https://plugin.invalid/" + path)!, configuration: config)
                    throw CheckFailure(description: "Download should reject " + path)
                } catch let failure as CheckFailure { throw failure }
                catch { print("PASS: download rejects " + path) }
            }
            try expect(!FixtureProtocol.started("/downgraded"), "Redirected HTTP address must never receive a request")
            let exact = try await PluginDownload.fetch(URL(string: "https://plugin.invalid/exact-limit")!, configuration: config)
            try expect(exact.count == 16 * 1024 * 1024 && exact.last == 65, "16 MiB response at boundary should complete")
            print("PASS: download accepts exactly 16 MiB")
            let waiting = Task { try await PluginDownload.fetch(URL(string: "https://plugin.invalid/waiting")!, configuration: config) }
            let deadline = Date().addingTimeInterval(2)
            while !FixtureProtocol.started("/waiting"), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            try expect(FixtureProtocol.started("/waiting"), "Cancellation fixture must start")
            let cancelledAt = Date()
            waiting.cancel()
            do { _ = try await waiting.value; throw CheckFailure(description: "Cancelled download must not complete") }
            catch is CancellationError { }
            try expect(Date().timeIntervalSince(cancelledAt) < 1, "Cancellation should release the await promptly")
            print("PASS: active download cancellation completes promptly")
            let early = Task { try await PluginDownload.fetch(URL(string: "https://plugin.invalid/cancel-before-start")!, configuration: config) }
            early.cancel()
            do { _ = try await early.value; throw CheckFailure(description: "Early cancellation must not complete") }
            catch is CancellationError { print("PASS: cancellation before transport is not lost") }
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
