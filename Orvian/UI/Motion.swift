import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Un seul interrupteur pour le réglage système « Réduire l'animation »
/// (Réglages → Accessibilité → Mouvement).
///
/// iOS désactive de lui-même certaines animations système, mais pas celles
/// écrites à la main : `withAnimation`, `.animation(_:value:)` et
/// `.transition` continuent de s'exécuter. Chaque site passe donc son animation
/// par `Motion.animation(_:)`, qui renvoie `nil` — « applique le changement
/// immédiatement » — quand l'utilisateur a demandé moins de mouvement. Les
/// `.transition` n'ont pas besoin d'être traités : ils ne s'animent que dans un
/// contexte d'animation, et ces contextes passent désormais tous par ici.
enum Motion {
    /// `false` tant que la racine n'a pas publié le réglage : une interface
    /// animée est préférable à un état figé définitif.
    nonisolated(unsafe) private static var reduceMotion = false

    static var animationsEnabled: Bool { !reduceMotion }

    static func publish(reduceMotion: Bool) {
        Motion.reduceMotion = reduceMotion
    }

    /// `nil` rend l'application du changement instantanée, que ce soit dans
    /// `withAnimation` ou dans `.animation(_:value:)`.
    static func animation(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Change de dossier sans laisser la moindre animation au chrome système.
    ///
    /// `disablesAnimations` ne couvre que l'arbre SwiftUI : la barre de
    /// navigation, tenue par UIKit, anime encore ses boutons (retour, filtre,
    /// recherche, hasard, sélection) pendant une poussée ou un retour. Sur
    /// iPhone, où le contenu du dossier est déjà substitué instantanément, ce
    /// reliquat se voit comme un fondu des boutons fixes à chaque changement
    /// de dossier.
    ///
    /// Les animations UIKit sont donc coupées le temps du changement, puis
    /// rendues quelques images plus tard, une fois la mise à jour de la barre
    /// validée : le changement de dossier ne montre aucune transition, et le
    /// reste de l'application retrouve ses animations.
    @MainActor
    static func withoutNavigationAnimation(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        #if canImport(UIKit)
        let freezesSystemChrome = UIDevice.current.userInterfaceIdiom != .pad
        if freezesSystemChrome { UIView.setAnimationsEnabled(false) }
        withTransaction(transaction, action)
        if freezesSystemChrome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                UIView.setAnimationsEnabled(true)
            }
        }
        #else
        withTransaction(transaction, action)
        #endif
    }
}

extension View {
    /// Publie le réglage système dans `Motion`. À poser une seule fois, à la
    /// racine : tous les sites d'animation de l'app le lisent ensuite.
    func reduceMotionGate() -> some View {
        modifier(ReduceMotionGate())
    }
}

private struct ReduceMotionGate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear { Motion.publish(reduceMotion: reduceMotion) }
            .onChange(of: reduceMotion) { _, enabled in
                Motion.publish(reduceMotion: enabled)
            }
    }
}
