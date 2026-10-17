import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
    @Entry var canImportFiles: (Int) -> Bool = { _ in false }
}

/// Provider URLs expire at the end of their callback; stage before switching actors.
struct FileDropTarget: ViewModifier {
    var isEnabled: Bool
    let onFiles: ([URL]) -> Void
    let onError: (String) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted && isEnabled {
                    RoundedRectangle(cornerRadius: DS.panelRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.item], isTargeted: $isTargeted) { providers in
                guard isEnabled, !providers.isEmpty else { return false }
                guard providers.count <= 20 else {
                    onError("Importez au maximum 20 fichiers à la fois.")
                    return false
                }
                for provider in providers {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, error in
                        let result: Result<URL, Error>
                        do {
                            guard let url else { throw error ?? DroppedFileStaging.ImportError.regularFileRequired }
                            result = .success(try DroppedFileStaging.copy(url))
                        } catch { result = .failure(error) }
                        Task { @MainActor in
                            switch result {
                            case .success(let url): onFiles([url])
                            case .failure(let error): onError("Import impossible : \(error.localizedDescription)")
                            }
                        }
                    }
                }
                return true
            }
    }
}
