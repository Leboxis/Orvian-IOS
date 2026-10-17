import SwiftUI

extension EnvironmentValues {
    @Entry var isActiveTab = true
}

/// Only the visible browser owns shortcuts; text fields retain their native Command-A.
struct BrowserKeyboardCommands: View {
    @Environment(\.isActiveTab) private var isActiveTab
    var isEditingText: Bool
    var canSelect: Bool
    var search: () -> Void
    var cancel: () -> Void
    var selectAll: () -> Void

    var body: some View {
        Group {
            Button("Rechercher", action: search).keyboardShortcut("f")
            Button("Annuler", action: cancel).keyboardShortcut(.escape, modifiers: [])
            Button("Sélectionner les fichiers affichés", action: selectAll)
                .keyboardShortcut("a")
                .disabled(isEditingText || !canSelect)
        }
        .disabled(!isActiveTab)
        .hidden()
        .accessibilityHidden(true)
    }
}
