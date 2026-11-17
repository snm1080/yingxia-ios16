import Foundation
import Darwin

struct LocalHTMLHomeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Network privileges belong to one selected homepage, never to app RPC or
/// Keychain/URLCredentialStorage. Redirects pass the same checks as first requests.
enum LocalHTMLHomePolicy {
    static func origin(_ url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return "null" }
        let port = url.port
        let suffix = port != nil && port != (scheme == "https" ? 443 : 80) ? ":\(port!)" : ""
        return "\(scheme)://\(host)\(suffix)"
    }
    static func ownsDocument(_ url: URL?, origin expected: String, localFile: Bool) -> Bool {
        guard let url else { return localFile }
        if localFile { return url.scheme == "about" && (url.absoluteString.removingPercentEncoding ?? url.absoluteString).components(separatedBy: "#")[0] == "about:blank" }
        return origin(url) == expected && expected != "null"
    }
    static func address(_ input: String) throws -> URL {
        guard input.utf8.count <= 32768, let url = URL(string: input),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, !isInternalHost(host) else {
            throw LocalHTMLHomeError("首页仅可请求 HTTP / HTTPS 内容地址，不能访问应用内部地址。")
        }
        return url
    }
    private static func isInternalHost(_ input: String) -> Bool {
        let host = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "::" { return true }
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            return value == 0 || value >> 24 == 127 || value >> 16 == 0xa9fe
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host.components(separatedBy: "%")[0], &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] <= 1 { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 { return bytes[12] == 127 || bytes[12...15].allSatisfy({ $0 == 0 }) }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
        }
        return false
    }
    static func headers(_ input: [String: String]) throws -> [String: String] {
        guard input.count <= 64 else { throw LocalHTMLHomeError("首页请求头过多。") }
        var result: [String: String] = [:]
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for (key, value) in input {
            guard !key.isEmpty, key.utf8.count <= 256, key.unicodeScalars.allSatisfy(token.contains), value.utf8.count <= 32768,
                  !value.unicodeScalars.contains(where: { [0, 10, 13].contains($0.value) }) else { throw LocalHTMLHomeError("首页请求头无效。") }
            if ["host", "connection", "content-length", "transfer-encoding", "proxy-authorization", "proxy-connection"].contains(key.lowercased()) { continue }
            result[key] = value
        }
        return result
    }
    static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return (host == domain || cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            && (!cookie.isSecure || url.scheme?.lowercased() == "https")
            && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
            && (path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"))
    }
    static func redirect(_ request: URLRequest, to url: URL, status: Int) throws -> URLRequest {
        var next = request
        next.url = try address(url.absoluteString)
        if request.url.map(origin) != origin(url) {
            for name in ["Authorization", "Cookie", "Origin", "Proxy-Authorization"] { next.setValue(nil, forHTTPHeaderField: name) }
        }
        if status == 303 && request.httpMethod != "HEAD" || [301, 302].contains(status) && request.httpMethod == "POST" {
            next.httpMethod = "GET"; next.httpBody = nil
            for name in ["Content-Type", "Content-Length", "Transfer-Encoding"] { next.setValue(nil, forHTTPHeaderField: name) }
        }
        return next
    }
    static func challenge(status: Int, body: String) -> Bool {
        [403, 429, 503].contains(status) && body.range(of: "cloudflare|cf-chl|challenge-platform|__cf_chl|captcha", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// One finite response per operation. Streaming is bounded before allocation;
/// redirects are returned to the caller so it can scope WebKit cookies per hop.
final class LocalHTMLHomeTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var failure: Error?
    private var cancelled = false
    init(limit: Int = 8 * 1024 * 1024) { self.limit = limit }
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForResource = min(60, max(1, request.timeoutInterval))
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                task.resume(); lock.unlock()
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        let tooLarge = response.expectedContentLength > Int64(limit)
        if tooLarge { failure = LocalHTMLHomeError("首页响应超过大小限制。") }
        lock.unlock()
        completionHandler(tooLarge ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if bytes.count + data.count > limit {
            failure = LocalHTMLHomeError("首页响应超过大小限制。")
            lock.unlock(); dataTask.cancel(); return
        }
        bytes.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let result: Result<(Data, HTTPURLResponse), Error>
        if let error = failure ?? error { result = .failure(error) }
        else if let response { result = .success((bytes, response)) }
        else { result = .failure(LocalHTMLHomeError("首页服务返回了无效响应。")) }
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate(); continuation?.resume(with: result)
    }
}
