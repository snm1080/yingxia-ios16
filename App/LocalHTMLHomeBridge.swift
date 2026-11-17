#if os(iOS)
import Foundation
import CoreFoundation
import UIKit
import WebKit
import TVCore

/// A narrow WebHome bridge, attached only to the selected WKWebView. Its
/// browser/network cookies are isolated from every other homepage and app login.
@MainActor final class LocalHTMLHomeBridge: NSObject, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
    private final class WeakBridge {
        weak var value: LocalHTMLHomeBridge?
        init(_ value: LocalHTMLHomeBridge) { self.value = value }
    }
    private static var mounted: [String: WeakBridge] = [:]
    private static var coldHistoryDocument: LocalHTMLHomeHistoryDocument?
    let source: LocalHTMLHomeSource
    let dataStore: WKWebsiteDataStore
    let browser = LocalHTMLHomeBrowser()
    var active = true
    var nativeAction: @MainActor (String, [String: Any]) async throws -> Any
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let origin: String
    private weak var web: WKWebView?
    private var stopped = false
    private var documentGeneration = 0
    private var transfers: [UUID: LocalHTMLHomeTransfer] = [:]
    private var resources: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var resourceHandles: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private var nativeTasks: [UUID: Task<LocalHTMLActionResult, Error>] = [:]
    private var playbackTask: UUID?
    private var pendingRequests = 0
    private var cache: [String: String]
    private var browserAgent = ""
    private var requestAgents: [String: String] = [:]
    private let historyOnly: Bool
    private struct LocalHTMLHistoryResult: @unchecked Sendable { let value: [String: Any] }
    private var historyRequests: [String: CheckedContinuation<LocalHTMLHistoryResult, Error>] = [:]
    private var historyTimeouts: [String: Task<Void, Never>] = [:]
    private struct LocalHTMLActionResult: @unchecked Sendable { let value: Any }

    init(source: LocalHTMLHomeSource, historyOnly: Bool = false, dataStore: WKWebsiteDataStore? = nil, browserAgent: String = "",
         nativeAction: @escaping @MainActor (String, [String: Any]) async throws -> Any) {
        self.source = source; self.nativeAction = nativeAction
        self.historyOnly = historyOnly
        active = !historyOnly
        self.dataStore = dataStore ?? .nonPersistent(); self.browserAgent = browserAgent
        origin = source.address.flatMap(URL.init(string:)).map(LocalHTMLHomePolicy.origin) ?? "null"
        cache = LocalHTMLHomeStore.cache(for: source.id)
    }
    func configure(_ configuration: WKWebViewConfiguration) throws {
        guard let file = Bundle.main.url(forResource: "local-html-home-sdk", withExtension: "js"),
              let sdk = try? String(contentsOf: file, encoding: .utf8) else { throw LocalHTMLHomeError("HTML 首页组件缺失，请重新安装完整安装包。") }
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.setURLSchemeHandler(self, forURLScheme: "yingxia-home")
        let localSnapshot = Dictionary(uniqueKeysWithValues: cache.compactMap { key, value -> (String, String)? in
            guard let parts = try? JSONSerialization.jsonObject(with: Data(key.utf8)) as? [String], parts.count == 2, parts[0] == "__localStorage" else { return nil }
            return (parts[1], value)
        })
        let config: [String: Any] = ["sourceID": source.id, "origin": origin, "token": token,
            "localFile": source.isFile, "cache": localSnapshot, "resourceBase": "yingxia-home://resource/" + token]
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), as: UTF8.self)
        let script = "window.__yingxiaHTMLHome=" + literal + ";\n" + sdk
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "localHTMLHome")
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    func attach(_ web: WKWebView) {
        self.web = web
        browser.anchor = web
        browser.dataStore = dataStore
        if !historyOnly { Self.mounted[source.id] = WeakBridge(self) }
    }
    func close() {
        guard !stopped else { return }
        stopped = true
        cancelHistoryRequests()
        if Self.mounted[source.id]?.value === self { Self.mounted[source.id] = nil }
        transfers.values.forEach { $0.cancel() }; transfers.removeAll()
        cancelResources()
        nativeTasks.values.forEach { $0.cancel() }; nativeTasks.removeAll()
        browser.close()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "localHTMLHome", contentWorld: .page)
        web = nil
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value {
            transfers.values.forEach { $0.cancel() }; transfers.removeAll()
            cancelResources()
            nativeTasks.values.forEach { $0.cancel() }; nativeTasks.removeAll()
            browser.close()
        }
    }
    func documentWillNavigate() {
        documentGeneration += 1
        cancelHistoryRequests()
        transfers.values.forEach { $0.cancel() }; transfers.removeAll()
        cancelResources()
        nativeTasks.values.forEach { $0.cancel() }; nativeTasks.removeAll()
        browser.close()
    }
    private var ownsCurrentDocument: Bool {
        !stopped && LocalHTMLHomeStore.load().sources.contains(source)
            && (historyOnly || LocalHTMLHomeStore.load().activeID == source.id)
            && LocalHTMLHomePolicy.ownsDocument(web?.url, origin: origin, localFile: source.isFile)
    }
    private var requestAccess: Bool { active || historyOnly || !historyRequests.isEmpty }
    /// A retained inactive page may answer only the network/cache requests
    /// needed by this explicit native resume. It cannot navigate or start playback.
    private func permits(_ method: String) -> Bool {
        if !historyOnly && active { return true }
        return requestAccess && ["net.request", "cache.get", "cache.set", "cache.del", "site.info", "device.info", "config.info", "ext.log", "ext.toast"].contains(method)
    }
    static func resolveHistory(source: LocalHTMLHomeSource, workID: String, episode: HTMLHomePlayback.EpisodeReference) async throws -> [String: Any] {
        try Task.checkCancellation()
        let retained = mounted[source.id]?.value
        if !needsFreshHistoryDocument(source), let retained, retained.ownsCurrentDocument {
            let result = try await retained.resolveHistory(workID: workID, episode: episode, allowWait: false, onlyIfReady: true)
            if result["unavailable"] as? Bool != true { return result }
        }
        let document = LocalHTMLHomeHistoryDocument(source: source, dataStore: retained?.dataStore, browserAgent: retained?.browserAgent ?? "")
        coldHistoryDocument?.close()
        coldHistoryDocument = document
        defer {
            document.close()
            if coldHistoryDocument === document { coldHistoryDocument = nil }
        }
        try await document.load()
        return try await document.bridge.resolveHistory(workID: workID, episode: episode, allowWait: true)
    }
    fileprivate static func needsFreshHistoryDocument(_ source: LocalHTMLHomeSource) -> Bool {
        source.address.flatMap(URL.init(string:))?.host?.lowercased() == "av-9du.pages.dev"
    }
    fileprivate static func prepareHistoryDocument(_ html: String, source: LocalHTMLHomeSource) throws -> String {
        guard needsFreshHistoryDocument(source) else { return html }
        let marker = "  /* ---------- 启动 ---------- */"
        let boot = "  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);\n  else boot();"
        guard html.contains("async function resolveForPlay(item, d, lineIdx, quiet)"), html.contains("var ADAPTERS = {"),
              let position = html.range(of: marker), html.components(separatedBy: marker).count == 2,
              html.components(separatedBy: boot).count == 2 else {
            throw LocalHTMLHomeError("HTML 来源的解析脚本已改变，无法自动恢复观看记录")
        }
        var result = html
        result.insert(contentsOf: aggregationHistoryScript + "\n", at: position.lowerBound)
        result = result.replacingOccurrences(of: boot,
            with: "  if (!window.__yingxiaHTMLHistoryOnly) { if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot(); }")
        return result
    }
    /// This aggregation source exposes a resolver only after play(), where
    /// it captures a signed URL. Reuse its real detail/stream/HLS implementation
    /// in an isolated document so cold and inactive resume always refetch it.
    static let aggregationHistoryScript = #"""
    window.__fmWebHomeHistoryResolver = async function (request) {
      var episode = request.episode || {}, original = String(episode.pageUrl || episode.url || '');
      var page = new URL(original), workID = String(request.workID || ''), key = workID.split('_')[0];
      if (!/^https?:$/.test(page.protocol) || page.username || page.password) throw new Error('原影片页面标识无效');
      if (!ADAPTERS[key]) {
        var found = Object.keys(ADAPTERS).filter(function (id) {
          var adapter = ADAPTERS[id];
          return new URL(adapter.siteDefault || adapter.site).hostname === page.hostname && adapter.isVideoUrl(original);
        });
        if (found.length !== 1) throw new Error('旧观看记录无法确认HTML 来源中的原站点');
        key = found[0];
      }
      var adapter = Object.assign({}, ADAPTERS[key]);
      if (!adapter.isVideoUrl(original)) throw new Error('保存的影片页面已不属于原站点');
      var previous = { SRC:SRC, A:A, SITE:SITE, NS:NS, TABS:TABS, prefs:prefs, curDetail:curDetail, curLine:curLine };
      try {
        SRC = key; A = adapter; NS = adapter.ns; TABS = adapter.tabs;
        var domain = await fm.cache.get('domain', NS);
        applySite(adapter, domain || ''); SITE = adapter.site;
        var configuredHost = new URL(SITE).hostname;
        var defaultHost = new URL(adapter.siteDefault || adapter.site).hostname;
        if (page.hostname !== configuredHost && page.hostname !== defaultHost) throw new Error('原影片页面与该站点设置不匹配');
        var referer = await fm.cache.get('referer', NS);
        prefs = Object.assign({}, previous.prefs, { referer: referer === '' ? adapter.refererDefault : referer === '1' });
        var item = { url:original, title:episode.name || '', pic:'' };
        var raw = await req(original);
        if (!raw) throw new Error('原影片页面没有返回内容');
        var detail = parseDetail(raw), lines = detail.lines || [], selected = 0;
        var savedName = String(episode.name || ''), savedNamedLine = savedName.indexOf(' · ') > 0;
        if (lines.some(function (line) { return String(line.name || '').trim() !== ''; })) {
          var matched = lines.findIndex(function (line) { return line.name && (savedName === line.name || savedName.indexOf(line.name + ' · ') === 0); });
          if (matched >= 0) selected = matched;
          else if (lines.length > 1 || savedNamedLine || !/^(?:最高画质|原画|\d{3,4}P)?$/i.test(savedName)) {
            throw new Error('保存的播放线路已不在原影片中');
          }
        } else if (savedNamedLine) {
          throw new Error('保存的播放线路已不在原影片中');
        }
        curDetail = { item:item, data:detail, raw:raw }; curLine = selected;
        var result = await resolveForPlay(item, detail, selected, true);
        if (!result || !result.playUrl) throw new Error('原影片重新解析后未返回可播放地址');
        return { url:result.playUrl, headers:result.hdr || {}, format:result.streamFmt || '' };
      } finally {
        SRC = previous.SRC; A = previous.A; SITE = previous.SITE; NS = previous.NS; TABS = previous.TABS;
        prefs = previous.prefs; curDetail = previous.curDetail; curLine = previous.curLine;
      }
    };
    """#
    private func resolveHistory(workID: String, episode: HTMLHomePlayback.EpisodeReference, allowWait: Bool, onlyIfReady: Bool = false) async throws -> [String: Any] {
        guard ownsCurrentDocument, let web else { throw LocalHTMLHomeError("HTML 来源尚未就绪，无法解析观看记录") }
        try Task.checkCancellation()
        let id = UUID().uuidString, generation = documentGeneration
        let request: [String: Any] = ["requestID": id, "workID": workID, "episode": episode.payload, "allowWait": allowWait, "onlyIfReady": onlyIfReady]
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                historyRequests[id] = continuation
                historyTimeouts[id] = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                    self?.finishHistory(id, result: .failure(LocalHTMLHomeError("HTML 来源解析超时，请稍后重试")))
                }
                web.callAsyncJavaScript("if (request.onlyIfReady && (typeof window.__yingxiaCanResolveHTMLHomeEpisode !== 'function' || !window.__yingxiaCanResolveHTMLHomeEpisode(request))) return { unavailable:true }; if (typeof window.__yingxiaResolveHTMLHomeEpisode !== 'function') throw new Error('HTML 来源解析组件尚未就绪'); return await window.__yingxiaResolveHTMLHomeEpisode(request);",
                    arguments: ["request": request], in: nil, in: .page) { [weak self] result in
                        guard let self, historyRequests[id] != nil else { return }
                        guard ownsCurrentDocument, generation == documentGeneration else {
                            finishHistory(id, result: .failure(CancellationError())); return
                        }
                        do {
                            let value = try result.get()
                            guard let fields = value as? [String: Any] else { throw LocalHTMLHomeError("HTML 来源没有返回有效的播放结果") }
                            let normalized = try LocalHTMLHomeMedia.unwrap(fields, resourceBase: "yingxia-home://resource/" + token)
                            finishHistory(id, result: .success(normalized))
                        } catch {
                            let native = error as NSError
                            let detail = native.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                            finishHistory(id, result: .failure(LocalHTMLHomeError(detail)))
                        }
                    }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finishHistory(id, result: .failure(CancellationError())) } }
        return result.value
    }
    private func finishHistory(_ id: String, result: Result<[String: Any], Error>) {
        guard let continuation = historyRequests.removeValue(forKey: id) else { return }
        historyTimeouts.removeValue(forKey: id)?.cancel()
        if case .failure = result {
            let literal = (try? JSONSerialization.data(withJSONObject: [id])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            web?.evaluateJavaScript("window.__yingxiaCancelHTMLHomeResolution?.((" + literal + ")[0]);", completionHandler: nil)
            // Visible page content and posters share the transfer table with
            // the resolver. Cancel its promise without aborting unrelated page
            // I/O; those HTTP requests retain their existing finite deadlines.
            if historyRequests.isEmpty && (historyOnly || !active) {
                transfers.values.forEach { $0.cancel() }; transfers.removeAll()
                browser.close()
            }
        }
        switch result {
        case .success(let value): continuation.resume(returning: LocalHTMLHistoryResult(value: value))
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
    private func cancelHistoryRequests() {
        for id in Array(historyRequests.keys) { finishHistory(id, result: .failure(CancellationError())) }
    }
    private func cancelResources() {
        let pending = Array(resourceHandles.values)
        resourceHandles.removeAll()
        resources.values.forEach { $0.cancel() }; resources.removeAll()
        for request in pending { request.didFailWithError(URLError(.cancelled)) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard ownsCurrentDocument, message.webView === web, message.frameInfo.isMainFrame,
              LocalHTMLHomePolicy.ownsDocument(message.frameInfo.request.url, origin: origin, localFile: source.isFile),
              let body = message.body as? [String: Any], body["token"] as? String == token,
              let method = body["method"] as? String, let payload = body["payload"] as? [String: Any] else {
            return (nil, "当前页面没有此首页的调用权限。")
        }
        guard permits(method) else { return (nil, "首页在后台只可解析当前观看记录，不能执行此操作。") }
        guard pendingRequests < 32 else { return (nil, "首页请求过多，请稍后重试。") }
        pendingRequests += 1
        let generation = documentGeneration
        defer { pendingRequests -= 1 }
        do {
            let result = try await invoke(method, payload: payload)
            guard ownsCurrentDocument, generation == documentGeneration else { throw CancellationError() }
            return (result, nil)
        } catch { return (nil, error is CancellationError ? "首页操作已取消。" : error.localizedDescription) }
    }
    private func invoke(_ method: String, payload: [String: Any]) async throws -> Any {
        switch method {
        case "net.request": return try await request(payload)
        case "cache.get", "cache.set", "cache.del": return try cacheAction(method, payload: payload)
        case "browser.open":
            let url = try LocalHTMLHomePolicy.address(payload["url"] as? String ?? "")
            let generation = documentGeneration
            // Jasna's supplied handler awaits browser.open and leaves its button
            // disabled on success. Other HTML sources own their retry logic.
            let jasnaActive = (try? await web?.evaluateJavaScript("Boolean(window.__ltxMacCat?.active)")) as? Bool == true
            let reloadsVerifiedPage = jasnaActive && LocalHTMLHomePolicy.origin(url) == "https://ltx.libray.workers.dev"
            guard ownsCurrentDocument, generation == documentGeneration else { throw CancellationError() }
            try await verify(url, userAgent: requestAgents[LocalHTMLHomePolicy.origin(url)] ?? browserAgent)
            try Task.checkCancellation()
            guard ownsCurrentDocument, generation == documentGeneration else { throw CancellationError() }
            if reloadsVerifiedPage {
                // Done records the user's intent, not the server's acceptance.
                // Reuse this home's WebKit cookies and matched browser identity;
                // a remaining gate must reject browser.open so Jasna restores its
                // retry button rather than reloading into the same disabled loop.
                let headers = ["User-Agent": requestAgents[LocalHTMLHomePolicy.origin(url)] ?? browserAgent,
                    "Referer": "https://ltx.libray.workers.dev/", "Accept": "application/json"]
                let (data, response) = try await fetch(["url": "https://ltx.libray.workers.dev/api/items", "headers": headers], mayVerify: false)
                try Task.checkCancellation()
                guard ownsCurrentDocument, generation == documentGeneration else { throw CancellationError() }
                guard (200..<300).contains(response.statusCode),
                      let catalogue = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      catalogue["items"] is [Any] else {
                    throw LocalHTMLHomeError("网站验证尚未完成，请重新打开网站验证，等待资源列表出现后再点“完成并重试”。")
                }
                reloadCurrentDocument()
            }
            return [String: String]()
        case "site.info": return ["key": source.id, "name": source.name, "homePage": source.address ?? "", "type": 0]
        case "device.info": return ["platform": "ios", "name": "Yingxia", "type": 1]
        case "config.info": return ["desc": "首页定制", "driveCheck": true]
        case "navigation.back": web?.goBack(); return [String: String]()
        case "navigation.reload":
            reloadCurrentDocument()
            return [String: String]()
        case "ext.toast":
            if active && !historyOnly { browser.showMessage(String((payload["message"] as? String ?? "").prefix(1000))) }
            return [String: String]()
        case "ext.log": return [String: String]()
        default:
            // The host callback has an explicit method switch; there is no app RPC,
            // filesystem, arbitrary selector or script-runtime forwarding here.
            let replacesPlayback = ["player.playUrl", "player.playVod", "player.playVodInline", "pan.play"].contains(method)
                || method == "player.control" && ["stop", "next", "prev", "previous"].contains(payload["action"] as? String ?? "")
            if replacesPlayback, let playbackTask { nativeTasks.removeValue(forKey: playbackTask)?.cancel() }
            let id = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self, active, ownsCurrentDocument else { throw CancellationError() }
                try Task.checkCancellation()
                let normalized = try LocalHTMLHomeMedia.unwrap(payload, resourceBase: "yingxia-home://resource/" + token)
                return LocalHTMLActionResult(value: try await nativeAction(method, normalized))
            }
            nativeTasks[id] = task
            if replacesPlayback { playbackTask = id }
            defer { nativeTasks[id] = nil; if playbackTask == id { playbackTask = nil } }
            return try await task.value.value
        }
    }
    private func cacheAction(_ method: String, payload: [String: Any]) throws -> Any {
        guard let name = payload["key"] as? String, !name.isEmpty, name.utf8.count <= 1024 else { throw LocalHTMLHomeError("首页缓存名称无效。") }
        let rule = String((payload["rule"] as? String ?? "").prefix(256))
        let key = String(decoding: try JSONSerialization.data(withJSONObject: [rule, name]), as: UTF8.self)
        if method == "cache.get" { return cache[key] ?? "" }
        var next = cache
        if method == "cache.del" { next.removeValue(forKey: key) }
        else if let value = payload["value"] as? String { next[key] = value }
        else { next[key] = String(decoding: try JSONSerialization.data(withJSONObject: payload["value"] ?? "", options: [.fragmentsAllowed]), as: UTF8.self) }
        try LocalHTMLHomeStore.saveCache(next, for: source.id)
        cache = next
        return [String: String]()
    }
    private func reloadCurrentDocument() {
        if source.isFile, let html = try? LocalHTMLHomeStore.load().html(for: source) { web?.loadHTMLString(html, baseURL: nil) }
        else { web?.reload() }
    }
    private func verify(_ url: URL, userAgent: String? = nil) async throws {
        guard ownsCurrentDocument else { throw CancellationError() }
        guard active, !historyOnly else { throw LocalHTMLHomeError("此 HTML 来源需要网页验证，请打开对应首页完成验证后重试观看记录") }
        browserAgent = try await browser.verify(url, userAgent: userAgent)
    }
    private func request(_ payload: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await fetch(payload, mayVerify: true)
        let body: Any
        switch payload["responseType"] as? String {
        case "base64": body = data.base64EncodedString()
        case "json": body = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        default: body = Self.text(data, response: response)
        }
        return ["ok": (200..<300).contains(response.statusCode), "status": response.statusCode,
            "url": response.url?.absoluteString ?? "", "headers": Self.headers(response),
            "cookies": response.value(forHTTPHeaderField: "Set-Cookie").map { [$0] } ?? [], "body": body]
    }
    private func fetch(_ payload: [String: Any], mayVerify: Bool) async throws -> (Data, HTTPURLResponse) {
        guard ownsCurrentDocument else { throw CancellationError() }
        let generation = documentGeneration
        let url = try LocalHTMLHomePolicy.address(payload["url"] as? String ?? "")
        let method = (payload["method"] as? String ?? "GET").uppercased()
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else { throw LocalHTMLHomeError("不支持的首页请求方法。") }
        let timeout = min(60, max(1, (payload["timeout"] as? NSNumber)?.doubleValue ?? 30))
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let input = payload["headers"], !(input is [String: String]) { throw LocalHTMLHomeError("首页请求头无效。") }
        request.allHTTPHeaderFields = try LocalHTMLHomePolicy.headers(payload["headers"] as? [String: String] ?? [:])
        if !["GET", "HEAD"].contains(method) {
            let body = Data((payload["body"] as? String ?? "").utf8)
            guard body.count <= 2 * 1024 * 1024 else { throw LocalHTMLHomeError("首页请求内容超过 2 MB。") }
            request.httpBody = body
        }
        let acceptsCookies = payload["credentials"] as? String != "omit"
        let deadline = Date().addingTimeInterval(timeout)
        for hop in 0...10 {
            try Task.checkCancellation()
            guard requestAccess, ownsCurrentDocument, generation == documentGeneration, let current = request.url else { throw CancellationError() }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw URLError(.timedOut) }
            request.timeoutInterval = remaining
            var outgoing = request
            if outgoing.value(forHTTPHeaderField: "User-Agent") == nil {
                if browserAgent.isEmpty { browserAgent = (try? await web?.evaluateJavaScript("navigator.userAgent")) as? String ?? "" }
                if !browserAgent.isEmpty { outgoing.setValue(browserAgent, forHTTPHeaderField: "User-Agent") }
            }
            if acceptsCookies {
                let cookies = await dataStore.httpCookieStore.allCookies().filter { LocalHTMLHomePolicy.cookie($0, matches: current) }
                var values: [String: String] = [:]
                for part in (outgoing.value(forHTTPHeaderField: "Cookie") ?? "").components(separatedBy: ";") {
                    let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
                }
                for cookie in cookies { values[cookie.name] = cookie.value }
                if !values.isEmpty { outgoing.setValue(values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
            }
            try Task.checkCancellation()
            guard requestAccess, ownsCurrentDocument, generation == documentGeneration else { throw CancellationError() }
            if let agent = outgoing.value(forHTTPHeaderField: "User-Agent"), !agent.isEmpty {
                requestAgents[LocalHTMLHomePolicy.origin(current)] = agent
            }
            let id = UUID(), transfer = LocalHTMLHomeTransfer()
            transfers[id] = transfer
            let result: (Data, HTTPURLResponse)
            do { result = try await transfer.load(outgoing); transfers[id] = nil }
            catch { transfers[id] = nil; throw error }
            guard requestAccess, ownsCurrentDocument, generation == documentGeneration else { throw CancellationError() }
            let (data, response) = result
            if acceptsCookies {
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: Self.headers(response), for: current) {
                    await dataStore.httpCookieStore.setCookie(cookie)
                }
            }
            try Task.checkCancellation()
            guard requestAccess, ownsCurrentDocument, generation == documentGeneration else { throw CancellationError() }
            if [301, 302, 303, 307, 308].contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: current)?.absoluteURL {
                guard hop < 10 else { throw LocalHTMLHomeError("首页重定向次数过多。") }
                request = try LocalHTMLHomePolicy.redirect(request, to: next, status: response.statusCode)
                continue
            }
            if mayVerify, LocalHTMLHomePolicy.challenge(status: response.statusCode, body: Self.text(data.prefix(512 * 1024), response: response)) {
                try await verify(response.url ?? current, userAgent: outgoing.value(forHTTPHeaderField: "User-Agent"))
                return try await fetch(payload, mayVerify: false)
            }
            return result
        }
        throw LocalHTMLHomeError("首页重定向次数过多。")
    }
    private static func headers(_ response: HTTPURLResponse) -> [String: String] {
        Dictionary(response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }, uniquingKeysWith: { _, new in new })
    }
    private static func text(_ data: Data, response: HTTPURLResponse) -> String {
        if let name = response.textEncodingName {
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId, let value = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) { return value }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard ownsCurrentDocument, webView === web, resources.count < 48,
              let url = urlSchemeTask.request.url, url.host == "resource", url.path == "/" + token,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            urlSchemeTask.didFailWithError(LocalHTMLHomeError("首页资源凭证无效。")); return
        }
        let query = components.queryItems ?? []
        guard query.filter({ $0.name == "url" }).count == 1, query.filter({ $0.name == "headers" }).count <= 1,
              query.allSatisfy({ ["url", "headers"].contains($0.name) }), let target = query.first(where: { $0.name == "url" })?.value else {
            urlSchemeTask.didFailWithError(LocalHTMLHomeError("首页资源地址无效。")); return
        }
        resourceHandles[id] = urlSchemeTask
        resources[id] = Task { [weak self] in
            guard let self else { return }
            defer { resources[id] = nil; resourceHandles[id] = nil }
            do {
                let headerText = query.first(where: { $0.name == "headers" })?.value ?? "{}"
                guard headerText.utf8.count <= 64 * 1024, let headers = try JSONSerialization.jsonObject(with: Data(headerText.utf8)) as? [String: String] else { throw LocalHTMLHomeError("首页资源请求头无效。") }
                var outgoing = headers
                if let range = urlSchemeTask.request.value(forHTTPHeaderField: "Range") { outgoing["Range"] = range }
                let (data, response) = try await fetch(["url": target, "headers": outgoing, "method": "GET"], mayVerify: false)
                try Task.checkCancellation()
                guard resources[id] != nil else { return }
                // The resource capability is for finite images/data. Removing CSP
                // or X-Frame-Options is unnecessary; challenge pages use a real browser.
                var responseHeaders = Self.headers(response)
                for name in responseHeaders.keys where ["content-encoding", "content-length", "transfer-encoding", "set-cookie"].contains(name.lowercased()) { responseHeaders[name] = nil }
                responseHeaders["Content-Length"] = String(data.count)
                let rewritten = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: responseHeaders)!
                urlSchemeTask.didReceive(rewritten); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch {
                if resources[id] != nil, !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        resourceHandles[id] = nil
        resources.removeValue(forKey: id)?.cancel()
    }
}

/// One bounded document used only when the owning home is no longer mounted.
/// It never selects a tab or accepts native playback/navigation during loading.
@MainActor private final class LocalHTMLHomeHistoryDocument: NSObject, WKNavigationDelegate, WKUIDelegate {
    let source: LocalHTMLHomeSource
    let bridge: LocalHTMLHomeBridge
    private var web: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var activeNavigation: WKNavigation?
    private var closed = false
    private var entryTransfer: LocalHTMLHomeTransfer?
    init(source: LocalHTMLHomeSource, dataStore: WKWebsiteDataStore? = nil, browserAgent: String = "") {
        self.source = source
        bridge = LocalHTMLHomeBridge(source: source, historyOnly: true, dataStore: dataStore, browserAgent: browserAgent) { _, _ in
            throw LocalHTMLHomeError("观看记录解析期间不能自动打开其他页面或开始播放")
        }
        super.init()
    }
    func load() async throws {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        let configuration = WKWebViewConfiguration()
        try bridge.configure(configuration)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        var preparedHTML: String?
        var preparedBaseURL: URL?
        if LocalHTMLHomeBridge.needsFreshHistoryDocument(source), let address = source.address {
            let entry = try LocalHTMLHomePolicy.address(address)
            var request = URLRequest(url: entry, timeoutInterval: 12)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15 Version/16.2 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            let transfer = LocalHTMLHomeTransfer(limit: 1024 * 1024)
            entryTransfer = transfer
            let loaded: (Data, HTTPURLResponse)
            do { loaded = try await transfer.load(request); entryTransfer = nil }
            catch { entryTransfer = nil; throw error }
            guard !closed else { throw CancellationError() }
            let (data, response) = loaded
            guard (200..<300).contains(response.statusCode), let html = String(data: data, encoding: .utf8) else {
                throw LocalHTMLHomeError("HTML 来源加载失败（HTTP \(response.statusCode)）")
            }
            preparedHTML = try LocalHTMLHomeBridge.prepareHistoryDocument(html, source: source)
            preparedBaseURL = entry
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__yingxiaHTMLHistoryOnly=true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            try Task.checkCancellation()
        }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        self.web = web
        web.navigationDelegate = self; web.uiDelegate = self
        bridge.attach(web)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    self?.finish(.failure(LocalHTMLHomeError("HTML 来源加载超时，请稍后重试")))
                }
                do {
                    if let preparedHTML { web.loadHTMLString(preparedHTML, baseURL: preparedBaseURL) }
                    else if source.isFile { web.loadHTMLString(try LocalHTMLHomeStore.load().html(for: source), baseURL: nil) }
                    else if let address = source.address { web.load(URLRequest(url: try LocalHTMLHomePolicy.address(address))) }
                    else { throw LocalHTMLHomeError("HTML 首页文件不可用，请重新导入对应来源") }
                } catch { finish(.failure(error)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    func close() {
        closed = true
        entryTransfer?.cancel(); entryTransfer = nil
        finish(.failure(CancellationError()))
        timeout?.cancel(); timeout = nil
        web?.stopLoading(); web?.navigationDelegate = nil; web?.uiDelegate = nil
        bridge.close()
        web?.loadHTMLString("", baseURL: nil); web = nil
    }
    private func finish(_ result: Result<Void, Error>) {
        guard let pending = continuation else { return }
        continuation = nil; timeout?.cancel(); timeout = nil
        pending.resume(with: result)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activeNavigation = navigation; bridge.documentWillNavigate()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard activeNavigation == nil || activeNavigation === navigation else { return }
        activeNavigation = nil; finish(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(.failure(LocalHTMLHomeError("HTML 来源加载失败：" + error.localizedDescription))) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { false }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
}
#endif
