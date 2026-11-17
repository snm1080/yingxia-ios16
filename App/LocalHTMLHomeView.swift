#if os(iOS)
import SwiftUI
import Perception
import UniformTypeIdentifiers
import WebKit
import TVCore

/// Wrap the native homepage after navigation has applied its startup destination.
struct LocalHTMLHomeContent<Content: View>: View {
    @Environment(Store.self) private var appStore
    @Environment(\.openRoute) private var openRoute
    @AppStorage(LocalHTMLHomeStore.key) private var saved = Data()
    @Environment(\.isLocalPageActive) private var isActive
    @Environment(\.localHTMLDockHidden) private var dockHidden
    @ViewBuilder var content: Content
    @State private var failure = ""
    @State private var atRoot = false
    private var store: LocalHTMLHomeStore { _ = saved; return .load() }
    var body: some View {
        let current = store
        Group {
            if let source = current.active {
                GeometryReader { _ in
                    ZStack(alignment: .bottomTrailing) {
                        if !failure.isEmpty {
                            VStack(spacing: 16) {
                                Text(failure).foregroundStyle(.secondary)
                                Button("重试") { failure = ""; atRoot = false }
                                Button("返回默认首页") { choose("builtin") }
                            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            LocalHTMLHomeWebView(source: source, active: isActive, failure: $failure, atRoot: $atRoot) { method, payload in
                                try await LocalHTMLHomeActions.invoke(method, payload: payload, store: appStore, openRoute: openRoute)
                            }
                                .id(source.id).accessibilityIdentifier("home.html.webview")
                        }
                    }
                    .localDockAccessory {
                        if isActive && atRoot && failure.isEmpty {
                            Button { withAnimation(.easeInOut(duration: 0.18)) { dockHidden.wrappedValue.toggle() } } label: {
                                Image(systemName: dockHidden.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary.opacity(0.5))
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial.opacity(0.7), in: Circle())
                                    .frame(width: 52, height: 52)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(dockHidden.wrappedValue ? "显示底栏" : "隐藏底栏")
                            .accessibilityIdentifier("home.html.toggleDock")
                        }
                    }
                }
                .ignoresSafeArea(.container)
                .toolbar(.hidden, for: .navigationBar)
            } else { content }
        }
        .appOnChange(of: current.activeID) { _, _ in failure = ""; atRoot = false; dockHidden.wrappedValue = false }
    }
    private func choose(_ id: String) {
        var next = store; next.select(id)
        do { try next.save(); failure = "" } catch { failure = error.localizedDescription }
    }
}

private struct LocalHTMLHomeWebView: UIViewRepresentable {
    let source: LocalHTMLHomeSource
    let active: Bool
    @Binding var failure: String
    @Binding var atRoot: Bool
    let nativeAction: @MainActor (String, [String: Any]) async throws -> Any
    func makeCoordinator() -> Coordinator { Coordinator(failure: $failure, atRoot: $atRoot) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let bridge = LocalHTMLHomeBridge(source: source, nativeAction: nativeAction)
        context.coordinator.bridge = bridge
        do { try bridge.configure(configuration) }
        catch { DispatchQueue.main.async { failure = error.localizedDescription } }
        configuration.userContentController.add(context.coordinator, name: "localHomeNavigation")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.navigationScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator; web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(web)
        bridge.attach(web)
        // Read a managed file once per web view, never while scrolling changes dock state.
        if source.isFile, let html = try? LocalHTMLHomeStore.load().html(for: source) { web.loadHTMLString(html, baseURL: nil) }
        else if let address = source.address, let url = URL(string: address) { web.load(URLRequest(url: url)) }
        else { DispatchQueue.main.async { failure = "首页文件不可用，请重新导入或返回默认首页。" } }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.failure = $failure
        context.coordinator.atRoot = $atRoot
        context.coordinator.bridge?.nativeAction = nativeAction
        context.coordinator.bridge?.setActive(active)
        if context.coordinator.active != active {
            context.coordinator.active = active
            web.setAllMediaPlaybackSuspended(!active, completionHandler: nil)
        }
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "localHomeNavigation")
        coordinator.bridge?.close(); coordinator.bridge = nil
        coordinator.observation = nil
        web.loadHTMLString("", baseURL: nil)
    }
    private static let navigationScript = #"""
    (() => {
      if (window.top !== window || window.__yingxiaHomeNavigation) return;
      window.__yingxiaHomeNavigation = true;
      let previousHref = location.href;
      const notify = (kind, before = previousHref) => {
        const href = location.href;
        previousHref = href;
        window.webkit.messageHandlers.localHomeNavigation.postMessage({ href, previousHref: before, kind });
      };
      for (const name of ['pushState', 'replaceState']) {
        const original = history[name];
        history[name] = function(...args) {
          const before = location.href;
          const result = original.apply(this, args);
          notify(name, before);
          return result;
        };
      }
      addEventListener('popstate', () => notify('popstate'));
      addEventListener('hashchange', event => notify('hashchange', event.oldURL || previousHref));
    })();
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var failure: Binding<String>
        var atRoot: Binding<Bool>
        var active = true
        var bridge: LocalHTMLHomeBridge?
        var observation: NSKeyValueObservation?
        private weak var web: WKWebView?
        private var rootAddress: String?
        private final class HistoryEntry {
            weak var item: WKBackForwardListItem?
            let isRoot: Bool
            init(_ item: WKBackForwardListItem, isRoot: Bool) { self.item = item; self.isRoot = isRoot }
        }
        private var entries: [ObjectIdentifier: HistoryEntry] = [:]
        private var rootWithoutItem: Bool?
        private var previousAddress: String?
        private weak var previousItem: WKBackForwardListItem?
        private var navigating = true
        private var activeNavigation: WKNavigation?
        init(failure: Binding<String>, atRoot: Binding<Bool>) { self.failure = failure; self.atRoot = atRoot }
        func observe(_ web: WKWebView) {
            self.web = web
            observation = web.observe(\.url, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateRoot() }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, !navigating, let web,
                  let payload = message.body as? [String: String], let address = payload["href"],
                  address == (web.url?.absoluteString ?? "about:blank"), let before = payload["previousHref"],
                  let kind = payload["kind"] else { return }
            // Messages can arrive after another synchronous history mutation. Ignore an
            // old URL, and process the matching event now, without a second queue hop.
            let item = web.backForwardList.currentItem
            if kind == "pushState" {
                // loadHTMLString can initially have no item. Preserve its original root
                // when WebKit first exposes it as a back entry after a same-URL push.
                if rootWithoutItem == true, let previous = web.backForwardList.backList.last,
                   previous.url.absoluteString == rootAddress, knownRoot(previous) == nil {
                    remember(previous, isRoot: true)
                }
                // If several queued pushes share this URL, WebKit exposes only the final
                // currentItem. Mark its final same-URL push internal; an unidentifiable
                // intermediate root stays hidden on Back rather than promoting inner pages.
                remember(item, isRoot: address == rootAddress && before != address)
            } else if kind == "replaceState", before != address {
                remember(item, isRoot: address == rootAddress)
            } else if (kind == "popstate" || kind == "hashchange"), knownRoot(item) == nil, before != address {
                remember(item, isRoot: address == rootAddress)
            }
            updateRoot()
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            bridge?.documentWillNavigate()
            activeNavigation = navigation
            navigating = true
            atRoot.wrappedValue = false
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard activeNavigation == nil || activeNavigation === navigation else { return }
            let finishedDocument = navigating
            activeNavigation = nil
            navigating = false
            let address = webView.url?.absoluteString ?? "about:blank"
            let item = webView.backForwardList.currentItem
            if rootAddress == nil {
                // The first successful document can follow a redirect; that final URL is home.
                rootAddress = address
                remember(item, isRoot: true)
            } else if finishedDocument {
                let remote = ["http", "https"].contains(webView.url?.scheme?.lowercased() ?? "")
                // A Home link/reload legitimately creates another root item. A fresh
                // about:blank document is not the imported HTML with the same URL.
                let returnsToImportedItem = item != nil && knownRoot(item) == true
                remember(item, isRoot: address == rootAddress && (remote || returnsToImportedItem))
            }
            updateRoot()
        }
        private func updateRoot() {
            guard let web else { return }
            let address = web.url?.absoluteString ?? "about:blank"
            let item = web.backForwardList.currentItem
            if !navigating {
                if address != rootAddress { remember(item, isRoot: false) }
                else if previousAddress != nil, previousAddress != address,
                        knownRoot(item) == nil || previousItem === item {
                    // A direct fragment/replace transition can return to root before its
                    // script message. Never relabel a known same-URL internal Back item.
                    remember(item, isRoot: true)
                }
            }
            previousAddress = address; previousItem = item
            let value = !navigating && rootAddress == address && knownRoot(item) == true
            if atRoot.wrappedValue != value { atRoot.wrappedValue = value }
        }
        private func knownRoot(_ item: WKBackForwardListItem?) -> Bool? {
            guard let item else { return rootWithoutItem }
            guard let entry = entries[ObjectIdentifier(item)], entry.item === item else { return nil }
            return entry.isRoot
        }
        private func remember(_ item: WKBackForwardListItem?, isRoot: Bool) {
            entries = entries.filter { $0.value.item != nil }
            if let item { entries[ObjectIdentifier(item)] = HistoryEntry(item, isRoot: isRoot) }
            else { rootWithoutItem = isRoot }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error, navigation: navigation) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error, navigation: navigation) }
        private func show(_ error: Error, navigation: WKNavigation?) {
            guard activeNavigation == nil || activeNavigation === navigation else { return }
            navigating = false; activeNavigation = nil
            if (error as NSError).code == NSURLErrorCancelled { updateRoot(); return }
            failure.wrappedValue = "首页加载失败：" + error.localizedDescription
            atRoot.wrappedValue = false
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased() ?? ""
            decisionHandler(["https", "http", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard active, action.sourceFrame.isMainFrame else { return nil }
            return bridge?.browser.makePopup(configuration: configuration, action: action)
        }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            guard active, frame.isMainFrame, let bridge else { return }
            await withCheckedContinuation { continuation in
                bridge.browser.alert(message, from: webView) { continuation.resume() }
            }
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            guard active, frame.isMainFrame, let bridge else { return false }
            return await withCheckedContinuation { continuation in
                bridge.browser.confirm(message, from: webView) { continuation.resume(returning: $0) }
            }
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
            guard active, frame.isMainFrame, let bridge else { completionHandler(nil); return }
            bridge.browser.prompt(prompt, defaultText: defaultText, from: webView, completion: completionHandler)
        }
    }
}

struct LocalHTMLHomeSettingsSection: View {
    @State private var store = LocalHTMLHomeStore.load()
    @State private var name = ""
    @State private var address = ""
    @State private var message = ""
    @State private var importFile = false
    @State private var readingFile = false
    @State private var importProgress = ""
    @State private var reorderSession = LocalSettingsReorderSession()
    @Environment(\.dynamicTypeSize) private var dynamicType
    var body: some View {
        SettingsGroup(title: "html", footer: "添加 HTML 首页，在底栏首页的 html 栏切换。本地可多选 HTML / HTM，选完后点“打开”。逐个保存副本并显示结果，失败文件不影响其它文件。每个首页支持单文件 HTML 及其中的在线资源。") {
            TextField("首页名称（可选）", text: $name).accessibilityIdentifier("settings.html.name").disabled(readingFile)
            addressRow
            if readingFile { ProgressView(importProgress.isEmpty ? "正在读取首页文件…" : importProgress) }
            LocalSettingsReorderList(validIDs: store.sources.map(\.id), enabled: !readingFile,
                                     session: $reorderSession, move: { source, target in
                guard !readingFile, store.sources.contains(where: { $0.id == source }),
                      store.sources.contains(where: { $0.id == target }) else { return }
                mutate { $0.move(source, onto: target) }
            }) {
                ForEach(store.sources) { source in sourceRow(source) }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .localDocumentImporter(isPresented: $importFile, kind: .htmlFile) { result in
            switch result {
            case .failure(let error): message = error.localizedDescription
            case .success(let selection): importSelectedDocuments(selection)
            }
        } cancelled: { message = "已取消文件选择" }
        .onReceive(NotificationCenter.default.publisher(for: LocalHTMLHomeStore.changed)) { _ in store = .load() }
        .onDisappear { reorderSession.cancel() }
    }
    @ViewBuilder private var addressRow: some View {
        if dynamicType.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                addressField
                HStack(spacing: 10) { importButtons }
            }.buttonStyle(.borderless)
        } else {
            HStack(spacing: 10) { addressField; importButtons }.buttonStyle(.borderless)
        }
    }
    private var addressField: some View {
            TextField("在线首页地址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("settings.html.address").disabled(readingFile)
                .onSubmit(importAddress)
    }
    @ViewBuilder private var importButtons: some View {
            Button(action: importAddress) {
                Text("导入").lineLimit(dynamicType.isAccessibilitySize ? 2 : 1)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .disabled(readingFile || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("settings.html.import.address")
            Button { message = ""; importFile = true } label: {
                Text("本地文件").lineLimit(dynamicType.isAccessibilitySize ? 2 : 1)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .disabled(readingFile).accessibilityIdentifier("settings.html.import")
    }
    private func sourceRow(_ source: LocalHTMLHomeSource) -> some View {
        HStack(spacing: 8) {
            Text(source.name).font(.subheadline.weight(.medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(source.name)
            Button(role: .destructive) { mutate { try $0.remove(source.id) } } label: {
                Text("删除").lineLimit(1).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel("删除 " + source.name)
            LocalSettingsReorderHandle(title: source.name, id: source.id, enabled: !readingFile, session: $reorderSession)
                .accessibilityAction(named: "上移") { mutate { $0.move(source.id, by: -1) } }
                .accessibilityAction(named: "下移") { mutate { $0.move(source.id, by: 1) } }
        }.buttonStyle(.borderless).disabled(readingFile)
            .localSettingsReorderRow(id: source.id)
    }
    private func importAddress() {
        guard !readingFile, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mutate { try $0.addRemote(name: name, address: address) }
        if message == "已保存" { name = ""; address = "" }
    }
    private func mutate(_ mutation: (inout LocalHTMLHomeStore) throws -> Void) {
        do { var next = store; try mutation(&next); try next.save(); store = next; message = "已保存" }
        catch { message = error.localizedDescription }
    }
    private func importSelectedDocuments(_ selection: LocalDocumentSelection) {
        guard !readingFile else { selection.release(); return }
        readingFile = true
        let proposedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { readingFile = false; importProgress = "" }
            let report = await selection.importDocuments(progress: { index, total, filename in
                importProgress = "正在导入 \(index) / \(total)：\(filename)"
            }) { index, url in
                let data = try await selection.readData(at: index, maxBytes: 1024 * 1024)
                let title = selection.urls.count > 1 && !proposedName.isEmpty
                    ? proposedName + " · " + url.deletingPathExtension().lastPathComponent : proposedName
                var next = store
                try next.importHTML(name: title, originalFilename: url.lastPathComponent, data: data)
                try next.save()
                store = next
                return "已保存首页"
            }
            message = report.message
            if report.successCount > 0 { name = "" }
        }
    }
}
#endif
