import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Sélecteur de fichiers UIKit.
///
/// SwiftUI `.fileImporter` empêche la sélection de fichiers sur certains
/// iPhone/iOS (éléments grisés, feuille qui ne se ferme pas) ; ce wrapper
/// `UIDocumentPickerViewController` est fiable. `asCopy: true` copie le
/// fichier dans la sandbox de l'app : pas de resource scoped à gérer.
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}