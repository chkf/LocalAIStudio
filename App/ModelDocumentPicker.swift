import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModelDocumentPicker: UIViewControllerRepresentable {
    var contentTypes: [UTType] = [.data]
    var asCopy = true
    var allowsMultipleSelection = true
    let onSelection: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    static func makePicker(delegate: UIDocumentPickerDelegate, types: [UTType] = [.data], asCopy: Bool = true, allowsMultipleSelection: Bool = true) -> UIDocumentPickerViewController {
        // File imports use copies; speech folders use scoped access while copying selected resources.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        // Keep selection and confirmation separate. All confirmed files are imported.
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = delegate
        return picker
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        Self.makePicker(delegate: context.coordinator, types: contentTypes, asCopy: asCopy, allowsMultipleSelection: allowsMultipleSelection)
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
