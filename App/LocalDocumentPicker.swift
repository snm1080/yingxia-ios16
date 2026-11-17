#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import TVCore

/// Legacy harness wrapper. App entry points present through `localDocumentImporter` so UIKit
/// owns the self-dismissing picker and its delegate rather than a SwiftUI sheet.
struct LocalDocumentPicker: UIViewControllerRepresentable {
    let kind: LocalDocumentSelectionKind
    let completion: (Result<LocalDocumentSelection, Error>) -> Void
    let cancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Providers often label .py/.js as generic data. Validate the imported bytes after selection.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: kind.importsCopy)
        picker.allowsMultipleSelection = kind.allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        Diagnostics.shared.record(.info, "imports", "picker created kind=\(kind.rawValue) multiple=\(kind.allowsMultipleSelection)")
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        if controller.delegate !== context.coordinator {
            Diagnostics.shared.record(.warning, "imports", "picker delegate changed kind=\(kind.rawValue)")
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: LocalDocumentPicker
        private var gate = LocalDocumentCompletionGate()
        init(_ parent: LocalDocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Diagnostics.shared.record(.info, "imports", "picker callback kind=\(parent.kind.rawValue) count=\(urls.count)")
            guard gate.accept() else { return }
            parent.completion(Result { try LocalDocumentSelection(urls: urls, kind: parent.kind, ownsImportedCopy: parent.kind.importsCopy) })
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Diagnostics.shared.record(.info, "imports", "picker cancelled kind=\(parent.kind.rawValue)")
            guard gate.accept() else { return }
            parent.cancelled()
        }
    }
}
#endif
