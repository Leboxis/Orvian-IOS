import SwiftUI

/// En-tête d'une barre latérale iPad : titre de colonne, actions et bouton de
/// masquage, placés **dans** la colonne plutôt que dans sa barre de navigation.
struct PadSidebarHeader<Trailing: View>: View {
    let title: Text
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let trailing: () -> Trailing

    init(
        title: Text,
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self._columnVisibility = columnVisibility
        self.trailing = trailing
    }

    private var isCollapsed: Bool { columnVisibility == .detailOnly }

    var body: some View {
        HStack(spacing: 10) {
            title
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            trailing()
            Button {
                columnVisibility = isCollapsed ? .all : .detailOnly
            } label: {
                Image(systemName: "sidebar.leading")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(isCollapsed ? "Afficher la barre latérale" : "Masquer la barre latérale")
        }
        .font(.title3)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .padding(.horizontal, DS.gridMargin)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}
