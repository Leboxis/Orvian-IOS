import SwiftUI

/// Barre d'onglets flottante « Liquid Glass » (iOS 26) : capsule de verre
/// fondu avec reflets spéculaires réactifs au toucher, et lentille de
/// sélection claire qui se métamorphose d'un onglet à l'autre au sein d'un
/// conteneur à effet de fusion (`GlassEffectContainer`).
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
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 8)
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
                    // Lentille de sélection : verre clair légèrement teinté,
                    // surmonté d'un reflet spéculaire (brillant en haut,
                    // diffus vers le bas) pour l'effet « lentille » d'Apple.
                    // Grâce au `GlassEffectContainer` parent et au
                    // `glassEffectID` partagé, la lentille se liquéfie et
                    // migre d'un onglet à l'autre lors du changement.
                    Color.clear
                        .glassEffect(
                            Glass.regular
                                .tint(Color.accentColor.opacity(0.16))
                                .interactive(),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.45),
                                            .white.opacity(0.05),
                                            .clear,
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .allowsHitTesting(false)
                        }
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
