import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModelDocumentPicker: UIViewControllerRepresentable {
    var contentTypes: [UTType] = [.data]
    let onSelection: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    static func makePicker(delegate: UIDocumentPickerDelegate, types: [UTType] = [.data]) -> UIDocumentPickerViewController {
        // Import a sandbox copy instead of asking a provider for in-place access.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        // Keep selection and confirmation separate. All confirmed files are imported.
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = delegate
        return picker
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        Self.makePicker(delegate: context.coordinator, types: contentTypes)
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onSelection = onSelection
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onSelection: ([URL]) -> Void

        init(onSelection: @escaping ([URL]) -> Void) {
            self.onSelection = onSelection
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onSelection(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onSelection([])
        }
    }
}
