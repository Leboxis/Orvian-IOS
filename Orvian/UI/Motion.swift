import SwiftUI

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
