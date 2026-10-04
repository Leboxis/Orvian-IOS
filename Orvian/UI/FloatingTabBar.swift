import SwiftUI

/// Disposition Apple Music : quatre onglets dans une capsule et Profil à part.
/// La coque des onglets reste propriétaire de leur état et de leur navigation.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    /// Appelé au toucher d'un onglet différent, juste avant sa sélection.
    var onSelect: ((AppTab) -> Void)? = nil
    var onReselect: ((AppTab) -> Void)? = nil
    @AppStorage("hapticFeedbackEnabled") private var hapticFeedbackEnabled = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selectionAnimation

    private let height: CGFloat = 64
    private let spacing: CGFloat = 8
    private let inset: CGFloat = 4
    private let groupedTabs: [AppTab] = [.settings, .tag, .home, .favorites]

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                HStack(spacing: 0) {
                    ForEach(groupedTabs) { tab in
                        TabButton(
                            tab: tab,
                            isSelected: selection == tab,
                            height: height - inset * 2
                        ) {
                            select(tab)
                        }
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(.primary.opacity(0.10))
                                    .matchedGeometryEffect(id: "selection", in: selectionAnimation)
                            }
                        }
                    }
                }
                .padding(inset)
                .frame(height: height)
                .modifier(TabGlassSurface(shape: Capsule(), opaque: reduceTransparency))

                TabButton(
                    tab: .profile,
                    isSelected: selection == .profile,
                    height: height,
                    iconOnly: true
                ) {
                    select(.profile)
                }
                .frame(width: height, height: height)
                .modifier(TabGlassSurface(shape: Circle(), opaque: reduceTransparency))
            }
        }
        // La valeur couvre aussi les changements d'onglet programmatiques.
        .animation(Motion.animation(.snappy(duration: 0.25)), value: selection)
        .frame(maxWidth: DS.maxTabBarWidth)
        .padding(.horizontal, 16)
        .sensoryFeedback(.selection, trigger: selection) { oldValue, newValue in
            hapticFeedbackEnabled && oldValue != newValue
        }
    }

    private func select(_ tab: AppTab) {
        if selection == tab {
            onReselect?(tab)
        } else {
            onSelect?(tab)
            selection = tab
        }
    }
}

/// Un seul verre par surface : aucun verre imbriqué dans la capsule.
/// Le projet cible iOS 26 ; un fond opaque respecte Réduire la transparence.
private struct TabGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let opaque: Bool

    func body(content: Content) -> some View {
        if opaque {
            content
                .background(Color(uiColor: .systemBackground), in: shape)
                .overlay {
                    shape.stroke(.primary.opacity(0.15), lineWidth: 0.5)
                }
        } else {
            content.glassEffect(.regular.interactive(), in: shape)
        }
    }
}

private struct TabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let height: CGFloat
    var iconOnly = false
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var showsTitle: Bool {
        !iconOnly && dynamicTypeSize < .accessibility1
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.symbolFilled : tab.symbol)
                    .font(.system(size: iconOnly ? 23 : 20, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 28, height: 26)
                if showsTitle {
                    Text(tab.title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Capsule())
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
        case .settings: return "slider.horizontal.3"
        case .tag: return "tag"
        case .home: return "house.fill"
        case .favorites: return "heart"
        case .profile: return "person.crop.circle"
        }
    }

    var symbolFilled: String {
        switch self {
        case .settings: return "slider.horizontal.3"
        case .tag: return "tag.fill"
        case .home: return "house.fill"
        case .favorites: return "heart.fill"
        case .profile: return "person.crop.circle.fill"
        }
    }
}
