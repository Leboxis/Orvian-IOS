import SwiftUI

/// Ordre protégé par décision utilisateur : Hasard, puis Sélectionner.
struct BrowserToolbar: ToolbarContent {
    @Environment(\.iPadLayout) private var iPadLayout
    let canOpenRandom: Bool
    let canSelect: Bool
    let onRandom: () -> Void
    let onSelect: () -> Void

    var body: some ToolbarContent {
        if iPadLayout.isPad {
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
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onRandom) {
                    Image(systemName: "dice")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(!canOpenRandom)
                .accessibilityLabel("Ouvrir un fichier au hasard")
                .accessibilityIdentifier("browser.random")

                Button(action: onSelect) {
                    Label("Sélectionner", systemImage: "checkmark.circle")
                }
                .disabled(!canSelect)
                .accessibilityIdentifier("browser.select")
            }
        }
    }
}
