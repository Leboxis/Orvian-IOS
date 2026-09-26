import SwiftUI

/// Barre d'onglets flottante translucide à coins arrondis.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    /// Appelé au toucher d'un onglet différent, juste avant sa sélection.
    var onSelect: ((AppTab) -> Void)? = nil
    var onReselect: ((AppTab) -> Void)? = nil
    @AppStorage("hapticFeedbackEnabled") private var hapticFeedbackEnabled = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                TabButton(tab: tab, isSelected: selection == tab) {
                    if selection == tab {
                        onReselect?(tab)
                    } else {
                        onSelect?(tab)
                        selection = tab
                    }
                }
            }
        }
        // L'animation est attachée à la **valeur** et non au geste : un
        // changement d'onglet obtenu autrement (remise à zéro au second appui,
        // ouverture automatique) s'anime exactement comme un tap.
        .animation(Motion.animation(.snappy(duration: 0.25)), value: selection)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .floatingChrome(RoundedRectangle(cornerRadius: DS.tabBarRadius, style: .continuous))
        // Bornée sur iPad : sans cette largeur maximale, les cinq onglets
        // s'étirent sur toute la largeur de l'écran. Sur iPhone, la largeur
        // proposée est déjà inférieure : la barre ne bouge pas.
        .frame(maxWidth: DS.maxTabBarWidth)
        .padding(.horizontal, DS.gridMargin + 8)
        .sensoryFeedback(.selection, trigger: selection) { oldValue, newValue in
            hapticFeedbackEnabled && oldValue != newValue
        }
    }
}

private struct TabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let action: () -> Void

    /// Au-delà d'Accessibility 1, les cinq libellés ne tiennent plus dans la
    /// largeur d'un onglet. Ils sont alors masqués : l'icône reste seule, et
    /// le nom continue d'être lu par VoiceOver (`accessibilityLabel`).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var showsTitle: Bool { dynamicTypeSize < .accessibility1 }

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.symbolFilled : tab.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .modifier(SymbolBounce(enabled: isSelected && Motion.animationsEnabled))
                if showsTitle {
                    Text(tab.title)
                        .font(.caption2.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
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

/// Rebond de l'icône à la sélection, désactivé quand l'utilisateur a demandé
/// moins de mouvement.
private struct SymbolBounce: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.symbolEffect(.bounce, value: enabled)
        } else {
            content
        }
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

    /// Onglets conservés montés entre deux visites : leurs données et leur
    /// position de défilement survivent, ce qui supprime le squelette et le
    /// retour en haut à chaque aller-retour. Profil et Réglages sont recréés à
    /// chaque visite — leur contenu est peu coûteux à reconstruire et le gain
    /// de mémoire vaut le coup.
    var isKeptAlive: Bool {
        switch self {
        case .home, .favorites, .tag: return true
        case .settings, .profile: return false
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
