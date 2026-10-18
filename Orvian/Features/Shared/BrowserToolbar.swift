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
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRandom) {
                    Label("Ouvrir un fichier au hasard", systemImage: "dice")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .labelStyle(.iconOnly)
                .disabled(!canOpenRandom)
                .accessibilityIdentifier("browser.random")
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
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
}
