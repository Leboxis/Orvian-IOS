import SwiftUI

/// Barre d'onglets flottante translucide à coins arrondis.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    var onReselect: ((AppTab) -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                TabButton(tab: tab, isSelected: selection == tab) {
                    if selection == tab {
                        onReselect?(tab)
                    } else {
                        withAnimation(.snappy(duration: 0.25)) {
                            selection = tab
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.tabBarRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.tabBarRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
        .padding(.horizontal, DS.gridMargin + 8)
    }
}

private struct TabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.symbolFilled : tab.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .symbolEffect(.bounce, value: isSelected)
                Text(tab.title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Onglets de l'application, de gauche à droite dans la barre.
enum AppTab: String, CaseIterable, Identifiable {
    case settings
    case tag
    case home
    case favorites
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: return "Réglages"
        case .tag: return "Tag"
        case .home: return "Accueil"
        case .favorites: return "Favoris"
        case .profile: return "Profil"
        }
    }

    var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .tag: return "tag"
        case .home: return "house"
        case .favorites: return "star"
        case .profile: return "person"
        }
    }

    var symbolFilled: String {
        switch self {
        case .settings: return "gearshape.fill"
        case .tag: return "tag.fill"
        case .home: return "house.fill"
        case .favorites: return "star.fill"
        case .profile: return "person.fill"
        }
    }
}
