#if os(iOS)
import UIKit
import WebKit

/// Ordinary site verification windows share only this homepage's WebKit store.
/// No SDK, script handlers, app RPC or custom resource scheme is installed here.
@MainActor final class LocalHTMLHomeBrowser: NSObject, WKUIDelegate, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    weak var anchor: WKWebView?
    var dataStore: WKWebsiteDataStore?
    private var navigation: UINavigationController?
    private var pages: [LocalHTMLBrowserPage] = []
    private var verification: CheckedContinuation<String, Error>?
    private var verificationID: UUID?
    private var closingResult: Result<String, Error>?
    private var completing = false
    private var presenting = false
    private var dismissAfterPresentation: (() -> Void)?
    private weak var dialog: UIAlertController?
    private weak var dialogWeb: WKWebView?
    private var finishDialog: ((String?) -> Void)?

    func verify(_ url: URL, userAgent: String? = nil) async throws -> String {
        guard verification == nil, navigation == nil, !completing, pages.isEmpty, let dataStore else { throw LocalHTMLHomeError("请先完成或关闭已打开的网页验证窗口。") }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                verification = continuation; verificationID = id
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = dataStore
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
                let web = makeWeb(configuration)
                if let userAgent, !userAgent.isEmpty { web.customUserAgent = userAgent }
                guard show(web, address: url, verifying: true) else {
                    verification = nil; verificationID = nil
                    continuation.resume(throwing: LocalHTMLHomeError("当前首页尚未就绪，请返回首页重试验证。"))
                    return
                }
                web.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, verificationID == id else { return }
                close()
            }
        }
    }
    func makePopup(configuration: WKWebViewConfiguration, action: WKNavigationAction) -> WKWebView? {
        guard !completing, action.targetFrame == nil, pages.count < 4,
              let url = action.request.url, ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        // WebKit must create the returned view with its supplied configuration
        // to preserve window.opener and an initial window.open('about:blank').
        // Replace the content controller so the child receives no parent SDK.
        configuration.userContentController = WKUserContentController()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let child = makeWeb(configuration)
        guard show(child, address: url, verifying: false) else { return nil }
        return child
    }
    private func makeWeb(_ configuration: WKWebViewConfiguration) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.uiDelegate = self; web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        return web
    }
    private func show(_ web: WKWebView, address: URL, verifying: Bool) -> Bool {
        let page = LocalHTMLBrowserPage(web: web, owner: self, verifying: verifying)
        page.title = address.host ?? "网页"
        if let navigation {
            pages.append(page); navigation.pushViewController(page, animated: true)
        } else {
            guard let anchor, let presenter = presenter(from: anchor), presenter.presentedViewController == nil,
                  !presenter.isBeingDismissed else { return false }
            pages = [page]
            let navigation = UINavigationController(rootViewController: page)
            navigation.modalPresentationStyle = .pageSheet
            navigation.isModalInPresentation = true
            navigation.setToolbarHidden(false, animated: false)
            self.navigation = navigation
            presenting = true
            presenter.present(navigation, animated: true) { [weak self] in
                guard let self else { return }
                presenting = false
                let pending = dismissAfterPresentation; dismissAfterPresentation = nil
                pending?()
            }
            navigation.presentationController?.delegate = self
        }
        return true
    }
    fileprivate func finish(_ page: LocalHTMLBrowserPage, success: Bool) {
        guard pages.contains(where: { $0 === page }), !completing else { return }
        if page.verifying && success {
            // A JS alert/confirm can suspend evaluation indefinitely. The agent
            // was set before loading; completing verification must not run JS.
            close(result: .success(page.web.customUserAgent ?? ""))
        } else if pages.first === page {
            close()
        } else {
            guard let index = pages.firstIndex(where: { $0 === page }) else { return }
            if let dialogWeb, pages[index...].contains(where: { $0.web === dialogWeb }) {
                let visibleDialog = dialog, pendingDialog = finishDialog
                finishDialog = nil; dialog = nil; self.dialogWeb = nil
                pendingDialog?(nil)
                visibleDialog?.dismiss(animated: false)
            }
            for item in pages[index...] { item.web.stopLoading(); item.web.uiDelegate = nil; item.web.navigationDelegate = nil }
            pages.removeSubrange(index...)
            navigation?.setViewControllers(pages, animated: true)
        }
    }
    func close(result: Result<String, Error> = .failure(CancellationError())) {
        if completing {
            // Page inactivity/navigation may cancel while success is dismissing.
            // Keep the same UIKit transition and cancel its eventual retry.
            if case .failure = result { closingResult = result }
            return
        }
        completing = true; closingResult = result
        let visibleDialog = dialog
        let pendingDialog = finishDialog
        finishDialog = nil; dialog = nil; dialogWeb = nil
        pendingDialog?(nil)
        for page in pages { page.web.stopLoading(); page.web.uiDelegate = nil; page.web.navigationDelegate = nil }
        pages.removeAll()
        let closingNavigation = navigation
        let finishClose: () -> Void = { [self] in
            let pending = verification
            let outcome = closingResult ?? .failure(CancellationError())
            verification = nil; verificationID = nil; closingResult = nil
            navigation = nil; completing = false; dismissAfterPresentation = nil
            pending?.resume(with: outcome)
        }
        let dismissBrowser: () -> Void = {
            if let closingNavigation, closingNavigation.presentingViewController != nil {
                closingNavigation.dismiss(animated: true, completion: finishClose)
            } else { finishClose() }
        }
        // Dismiss a nested dialog first. A second simultaneous dismissal can
        // leave UIKit's presentation overlay intercepting the entire app.
        if let visibleDialog, visibleDialog.presentingViewController != nil {
            visibleDialog.dismiss(animated: false, completion: dismissBrowser)
        } else if presenting {
            dismissAfterPresentation = dismissBrowser
        } else { dismissBrowser() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { close() }
    func webViewDidClose(_ webView: WKWebView) {
        if let page = pages.first(where: { $0.web === webView }) { finish(page, success: true) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard pages.contains(where: { $0.web === webView }) else { return nil }
        return makePopup(configuration: configuration, action: action)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        let allowed = ["http", "https", "about"].contains(scheme)
            || action.targetFrame?.isMainFrame == false && ["data", "blob"].contains(scheme)
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let page = pages.first(where: { $0.web === webView }) {
            page.title = webView.url?.host ?? "网页"; page.navigationItem.prompt = page.verifying ? "完成网站验证后，点右上角重试首页请求" : nil
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    private func failed(_ web: WKWebView, error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        pages.first(where: { $0.web === web })?.navigationItem.prompt = error.localizedDescription
    }
    func alert(_ message: String, from web: WKWebView, completion: @escaping () -> Void) {
        presentDialog(message, initial: nil, kind: .alert, from: web) { _ in completion() }
    }
    func confirm(_ message: String, from web: WKWebView, completion: @escaping (Bool) -> Void) {
        presentDialog(message, initial: nil, kind: .confirm, from: web) { completion($0 == "yes") }
    }
    func prompt(_ message: String, defaultText: String?, from web: WKWebView, completion: @escaping (String?) -> Void) {
        presentDialog(message, initial: defaultText, kind: .prompt, from: web, completion: completion)
    }
    func showMessage(_ message: String) { if let anchor { alert(message, from: anchor) {} } }
    private enum Dialog { case alert, confirm, prompt }
    private func presentDialog(_ message: String, initial: String?, kind: Dialog, from web: WKWebView, completion: @escaping (String?) -> Void) {
        guard !completing, finishDialog == nil, let presenter = presenter(from: web), !presenter.isBeingDismissed,
              presenter.presentedViewController == nil else { completion(nil); return }
        let panel = UIAlertController(title: web.url?.host ?? "HTML 首页", message: String(message.prefix(4000)), preferredStyle: .alert)
        if kind == .prompt { panel.addTextField { $0.text = initial } }
        var finished = false
        let finish: (String?) -> Void = { [weak self] answer in
            guard !finished else { return }; finished = true
            self?.finishDialog = nil; self?.dialog = nil; self?.dialogWeb = nil; completion(answer)
        }
        finishDialog = finish; dialog = panel; dialogWeb = web
        if kind != .alert { panel.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in finish(nil) }) }
        panel.addAction(UIAlertAction(title: "确定", style: .default) { [weak panel] _ in finish(kind == .prompt ? panel?.textFields?.first?.text : "yes") })
        presenter.present(panel, animated: true)
    }
    private func presenter(from web: WKWebView) -> UIViewController? {
        guard var presenter = web.window?.rootViewController else { return nil }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        return presenter
    }
    // Swift's async requirements export the same ObjC completion selectors
    // without depending on the SDK importer's callback actor annotation.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { continuation in
            alert(message, from: webView) { continuation.resume() }
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { continuation in
            confirm(message, from: webView) { continuation.resume(returning: $0) }
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        self.prompt(prompt, defaultText: defaultText, from: webView, completion: completionHandler)
    }
}

@MainActor private final class LocalHTMLBrowserPage: UIViewController {
    let web: WKWebView
    let verifying: Bool
    private weak var owner: LocalHTMLHomeBrowser?
    init(web: WKWebView, owner: LocalHTMLHomeBrowser, verifying: Bool) {
        self.web = web; self.owner = owner; self.verifying = verifying
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        web.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }; owner?.finish(self, success: false)
        })
        if verifying {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成并重试", primaryAction: UIAction { [weak self] _ in
                guard let self else { return }; owner?.finish(self, success: true)
            })
            navigationItem.prompt = "请在下方完成网站验证"
        }
        toolbarItems = [
            UIBarButtonItem(image: UIImage(systemName: "chevron.left"), primaryAction: UIAction { [weak web] _ in web?.goBack() }),
            UIBarButtonItem(image: UIImage(systemName: "chevron.right"), primaryAction: UIAction { [weak web] _ in web?.goForward() }),
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak web] _ in web?.reload() })
        ]
    }
}
#endif
