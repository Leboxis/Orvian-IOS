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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                heading
                Spacer(minLength: 6)
                trailing()
                hideButton
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack { heading; Spacer(minLength: 6); hideButton }
                HStack(spacing: 6) { Spacer(minLength: 0); trailing() }
            }
        }
        .font(.body)
        .buttonStyle(.plain)
        .padding(.horizontal, DS.gridMargin)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var heading: some View {
        title.font(.title2.weight(.semibold)).fixedSize(horizontal: true, vertical: false)
    }

    private var hideButton: some View {
        Button {
            columnVisibility = isCollapsed ? .all : .detailOnly
        } label: {
            Image(systemName: "sidebar.leading")
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel(isCollapsed ? "Afficher la barre latérale" : "Masquer la barre latérale")
    }
}
