import Foundation
import CrossDiffCore

private struct PluginDownloadError: LocalizedError {
    let zh: String
    let en: String
    var errorDescription: String? { L(zh, en) }
}

/// No cookies, credentials, caching or background requests. Redirects cannot
/// downgrade HTTPS. The byte cap is enforced while receiving, before decoding.
final class PluginDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes = 16 * 1024 * 1024
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var failure: Error?
    private var session: URLSession?
    private let lock = NSLock()
    private var cancelled = false

    static func fetch(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        guard permitted(url) else {
            throw PluginDownloadError(zh: "请输入不包含账号密码的 HTTPS 插件链接。", en: "Enter an HTTPS plugin URL without credentials.")
        }
        let download = PluginDownload()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.start(url, configuration: configuration, continuation: continuation)
            }
        } onCancel: { download.cancel() }
    }
    private static func permitted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }
    private func start(_ url: URL, configuration: URLSessionConfiguration, continuation: CheckedContinuation<Data, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        session.dataTask(with: url).resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let current = session; lock.unlock()
        current?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.permitted(url) else {
            failure = PluginDownloadError(zh: "插件下载被重定向到不允许的地址。", en: "The download redirected to a disallowed address.")
            completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), response.expectedContentLength <= maximumBytes else {
            failure = PluginDownloadError(zh: "下载失败或插件包超过 16 MiB。", en: "The download failed or exceeds 16 MiB.")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= maximumBytes - data.count else {
            failure = PluginDownloadError(zh: "插件包超过 16 MiB。", en: "The plugin exceeds 16 MiB.")
            dataTask.cancel(); return
        }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let wasCancelled = cancelled; self.session = nil; lock.unlock()
        let callback = continuation; continuation = nil
        if wasCancelled { callback?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { callback?.resume(throwing: error) }
        else { callback?.resume(returning: data) }
        session.finishTasksAndInvalidate()
    }
}
