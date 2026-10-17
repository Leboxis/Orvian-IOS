import SwiftUI

/// Ordre protégé par décision utilisateur : Hasard, puis Sélectionner.
struct BrowserToolbar: ToolbarContent {
    let canOpenRandom: Bool
    let canSelect: Bool
    let onRandom: () -> Void
    let onSelect: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: onRandom) {
                Label("Ouvrir un fichier au hasard", systemImage: "dice")
            }
            .disabled(!canOpenRandom)
            .accessibilityIdentifier("browser.random")
            Button(action: onSelect) {
                Label("Sélectionner", systemImage: "checkmark.circle")
            }
            .disabled(!canSelect)
            .accessibilityIdentifier("browser.select")
        }
    }
}
