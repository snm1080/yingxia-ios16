#if os(iOS)
import UIKit
import WebKit

/// WebKit owns the request, including cookies, POST bodies and Blob URLs. Only
/// its completed local file is handed to Files; exports never replace the page.
@MainActor final class ConfigCenterDownload: NSObject, WKDownloadDelegate {
    private struct Transfer {
        let download: WKDownload
        var file: URL?
    }
    private weak var web: WKWebView?
    private var reportError: ((String) -> Void)?
    private var transfers: [ObjectIdentifier: Transfer] = [:]
    private var pending: [URL] = []
    private var export: ConfigCenterExportSession?
    private var stopped = false

    func attach(_ web: WKWebView, reportError: @escaping (String) -> Void) {
        self.web = web; self.reportError = reportError; stopped = false
    }

    static func shouldDownload(_ response: URLResponse, mainFrame: Bool, canShow: Bool) -> Bool {
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if disposition.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment" { return true }
        let mime = response.mimeType?.lowercased() ?? ""
        return !canShow || (mainFrame && (mime == "application/json" || mime == "text/json" || mime.hasSuffix("+json")))
    }

    static func filename(_ suggested: String, mimeType: String?) -> String {
        let leaf = suggested.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
        let cleaned = String(leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "config" : cleaned
        if mimeType?.lowercased().contains("json") == true && (name as NSString).pathExtension.isEmpty { return name + ".json" }
        return name
    }

    func accept(_ download: WKDownload) {
        guard !stopped else { download.cancel { _ in }; return }
        transfers[ObjectIdentifier(download)] = Transfer(download: download)
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        guard !stopped, transfers[key] != nil else { completionHandler(nil); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Yingxia-Website-Export-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(Self.filename(suggestedFilename, mimeType: response.mimeType))
            transfers[key]?.file = file
            completionHandler(file)
        } catch {
            transfers.removeValue(forKey: key)
            reportError?("导出失败：" + error.localizedDescription)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let transfer = transfers.removeValue(forKey: ObjectIdentifier(download)), let file = transfer.file else { return }
        guard !stopped else { Self.remove(file); return }
        pending.append(file)
        presentNext()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let transfer = transfers.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if let file = transfer.file { Self.remove(file) }
        if !stopped { reportError?("导出失败：" + error.localizedDescription) }
    }

    private func presentNext() {
        guard !stopped, export == nil, !pending.isEmpty else { return }
        guard let web, var presenter = web.window?.rootViewController else {
            pending.forEach(Self.remove); pending.removeAll()
            reportError?("当前配置页面尚未就绪，请重新导出。")
            return
        }
        while let next = presenter.presentedViewController { presenter = next }
        if let transition = presenter.transitionCoordinator {
            if transition.animate(alongsideTransition: nil, completion: { [weak self] _ in self?.presentNext() }) { return }
        }
        guard !presenter.isBeingDismissed, presenter.viewIfLoaded?.window != nil else {
            pending.forEach(Self.remove); pending.removeAll()
            reportError?("当前面板正在关闭，请返回配置页面重新导出。")
            return
        }
        let file = pending.removeFirst()
        let session = ConfigCenterExportSession(file: file) { [weak self] in
            self?.export = nil
            self?.presentNext()
        }
        export = session
        session.present(from: presenter)
    }

    func close() {
        stopped = true; reportError = nil; web = nil
        let active = transfers.values; transfers.removeAll()
        for transfer in active {
            // WebKit can still be writing until cancellation completes.
            transfer.download.cancel { _ in if let file = transfer.file { Self.remove(file) } }
        }
        pending.forEach(Self.remove); pending.removeAll()
        // Files owns its dismissal and retains the completed file until then.
        export = nil
    }

    nonisolated fileprivate static func remove(_ file: URL) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
}

@MainActor private final class ConfigCenterExportSession: NSObject, UIDocumentPickerDelegate {
    private let file: URL
    private let controller: ExportPicker
    private var retained: ConfigCenterExportSession?
    private var finished: (() -> Void)?

    init(file: URL, finished: @escaping () -> Void) {
        self.file = file; self.finished = finished
        controller = ExportPicker(forExporting: [file], asCopy: true)
        super.init()
        controller.delegate = self
        controller.shouldShowFileExtensions = true
        controller.isModalInPresentation = true
        controller.didClose = { [weak self] in self?.finish() }
    }
    func present(from presenter: UIViewController) {
        retained = self
        presenter.present(controller, animated: true)
    }
    // The system has already copied the file when it reports success. Wait for
    // actual dismissal before releasing the delegate or presenting another export.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {}
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    private func finish() {
        guard retained != nil else { return }
        ConfigCenterDownload.remove(file)
        let callback = finished; finished = nil
        retained = nil
        DispatchQueue.main.async { callback?() }
    }
    private final class ExportPicker: UIDocumentPickerViewController {
        var didClose: (() -> Void)?
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || presentingViewController == nil { didClose?() }
        }
    }
}
#endif
