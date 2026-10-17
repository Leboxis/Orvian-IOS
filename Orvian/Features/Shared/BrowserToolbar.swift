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
                    .frame(minWidth: 44, minHeight: 44)
            }
            .labelStyle(.iconOnly)
            .disabled(!canOpenRandom)
            .accessibilityIdentifier("browser.random")
            Button(action: onSelect) {
                Label("Sélectionner", systemImage: "checkmark.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .labelStyle(.iconOnly)
            .disabled(!canSelect)
            .accessibilityIdentifier("browser.select")
        }
    }
}
