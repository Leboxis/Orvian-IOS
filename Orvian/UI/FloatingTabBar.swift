import SwiftUI

/// Barre d'onglets flottante « Liquid Glass » (iOS 26) : verre fondu avec
/// reflets spéculaires réactifs au toucher, et pilule de sélection teintée
/// qui se métamorphose d'un onglet à l'autre au sein d'un conteneur à effet
/// de fusion (`GlassEffectContainer`).
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    var onReselect: ((AppTab) -> Void)? = nil
    @AppStorage("hapticFeedbackEnabled") private var hapticFeedbackEnabled = true
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: selection == tab,
                        namespace: glassNamespace
                    ) {
                        if selection == tab {
                            onReselect?(tab)
                        } else {
                            withAnimation(.snappy(duration: 0.3)) {
                                selection = tab
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: DS.tabBarRadius, style: .continuous)
            )
        }
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 8)
        .padding(.horizontal, DS.gridMargin + 8)
        .sensoryFeedback(.selection, trigger: selection) { oldValue, newValue in
            hapticFeedbackEnabled && oldValue != newValue
        }
    }
}

private struct TabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let namespace: Namespace.ID
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
                    // Pilule de sélection en verre teinté : grâce au
                    // `GlassEffectContainer` parent et au `glassEffectID`
                    // partagé, elle se liquéfie et migre d'un onglet à
                    // l'autre lors du changement de sélection.
                    Color.clear
                        .glassEffect(
                            Glass.regular
                                .tint(Color.accentColor.opacity(0.22))
                                .interactive(),
                            in: Capsule()
                        )
                        .glassEffectID(tab, in: namespace)
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
