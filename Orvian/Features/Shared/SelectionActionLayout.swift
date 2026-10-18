import SwiftUI

/// iPad exposes each action; the compact phone toolbar keeps its existing menu.
struct SelectionActionLayout<Actions: View>: View {
    @Environment(\.iPadLayout) private var layout
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        if layout.isPad {
            HStack(spacing: 4, content: actions)
                .labelStyle(.iconOnly)
                .buttonStyle(SelectionToolbarButtonStyle())
        } else {
            Menu(content: actions) {
                Label("Actions de sélection", systemImage: "ellipsis.circle")
            }
        }
    }
}

private struct SelectionToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.accentColor)
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.6 : 1)
    }
}
