import SwiftUI
import UIKit
import Combine

/// État de verrouillage indépendant du rendu : UIKit peut suspendre une vue
/// masquée par une présentation plein écran, mais pas les événements de scène.
@MainActor
final class AppPrivacyState: ObservableObject {
    struct Snapshot {
        var phase: ScenePhase = .active
        var isUnlocked = false
        var hasPresentedContent = false
        var hasGoneBackground = false
        var generation = 0
        var allowsInactiveBiometricDismissal = false
    }
    @Published private(set) var snapshot = Snapshot()
    private let isLockConfigured: @MainActor () -> Bool

    init(isLockConfigured: @escaping @MainActor () -> Bool = { AppLockStore.isConfigured }) {
        self.isLockConfigured = isLockConfigured
    }

    func requiresLock(_ snapshot: Snapshot) -> Bool {
        isLockConfigured() && !snapshot.isUnlocked
    }

    func transition(to phase: ScenePhase) {
        guard phase != snapshot.phase else { return }
        var next = snapshot
        next.phase = phase
        next.allowsInactiveBiometricDismissal = false
        if phase == .background {
            FavoritesDiskCache.shared.flushPending()
            next.hasGoneBackground = true
            if isLockConfigured() {
                next.isUnlocked = false
                next.generation &+= 1
            }
        }
        snapshot = next
    }

    func contentDidAppear() {
        guard !snapshot.hasPresentedContent, !requiresLock(snapshot) else { return }
        snapshot.hasPresentedContent = true
    }

    /// Appelé seulement après validation du PIN ou de la biométrie. Un retour
    /// tardif d'une ancienne tentative ne peut pas déverrouiller la suivante.
    func unlock(generation: Int) {
        guard snapshot.phase == .active, snapshot.generation == generation else { return }
        var next = snapshot
        next.isUnlocked = true
        next.hasPresentedContent = true
        snapshot = next
    }

    /// Succès biométrique : AppLockView invalide déjà toute invite d'une
    /// session précédente (arrière-plan ou disparition annule le contexte LA,
    /// qui ne rappelle alors jamais). Seule une invite de la session courante
    /// peut donc aboutir ici : la génération courante fait foi, sans jeton
    /// capturé au lancement de l'invite qui pourrait être périmé (Face ID
    /// prend 1 à 3 s, le code ~0,3 s). Le code garde `unlock(generation:)`.
    ///
    /// Le succès arrive pendant que la scène est encore inactive : le
    /// dialogue système Face ID désactive la scène, et la réactivation suit
    /// le retour du callback. Exiger `.active` refusait donc à tort ces
    /// succès légitimes (« refusé: phase=inactive »). Seul `.background`
    /// reste refusé (l'arrière-plan ré-arme le verrouillage).
    func unlockAfterBiometrics() {
        guard snapshot.phase != .background else { return }
        var next = snapshot
        next.isUnlocked = true
        next.hasPresentedContent = true
        next.allowsInactiveBiometricDismissal = snapshot.phase == .inactive
        snapshot = next
    }
}

private struct LockPresentation: View {
    @ObservedObject var state: AppPrivacyState
    var body: some View {
        let snapshot = state.snapshot
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            if state.requiresLock(snapshot) {
                AppLockView(
                    autoPromptBiometrics: snapshot.hasGoneBackground,
                    onBiometricUnlock: { state.unlockAfterBiometrics() }
                ) {
                    state.unlock(generation: snapshot.generation)
                }
            }
        }
        .environment(\.scenePhase, snapshot.phase)
    }
}

/// Une fenêtre au-dessus des présentations SwiftUI/UIKit. Sa mise à jour
/// s'abonne à l'état, sans attendre updateUIView d'un écran devenu invisible.
@MainActor
struct AppPrivacyWindow: UIViewRepresentable {
    let state: AppPrivacyState

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.onAttach = { [weak coordinator = context.coordinator] owner in
            coordinator?.attach(to: owner)
        }
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.attach(to: view.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class AttachmentView: UIView {
        var onAttach: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onAttach?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private let state: AppPrivacyState
        private weak var owner: UIWindow?
        private weak var scene: UIWindowScene?
        private var shield: UIWindow?
        private var subscription: AnyCancellable?
        private var observers: [NSObjectProtocol] = []
        private var previousAccessibilityHidden = false

        init(state: AppPrivacyState) {
            self.state = state
            subscription = state.$snapshot.sink { [weak self] snapshot in
                self?.render(snapshot)
            }
        }

        func attach(to window: UIWindow?) {
            guard let owner = window ?? owner, let scene = owner.windowScene else { return }
            self.owner = owner
            if self.scene !== scene {
                observers.forEach { NotificationCenter.default.removeObserver($0) }
                observers.removeAll()
                self.scene = scene
                for (name, phase) in [(UIScene.willDeactivateNotification, ScenePhase.inactive),
                                      (UIScene.didEnterBackgroundNotification, .background),
                                      (UIScene.didActivateNotification, .active)] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { [weak state] _ in
                        MainActor.assumeIsolated { state?.transition(to: phase) }
                    })
                }
                switch scene.activationState {
                case .foregroundActive: state.transition(to: .active)
                case .background: state.transition(to: .background)
                default: state.transition(to: .inactive)
                }
            }
            render(state.snapshot)
        }

        private func render(_ snapshot: AppPrivacyState.Snapshot) {
            guard let owner, let scene else { return }
            defer {
                FileDownloadService.shared.updatePresentation(
                    isAllowed: !state.requiresLock(snapshot) && snapshot.phase == .active,
                    window: owner
                )
            }
            if !state.requiresLock(snapshot), snapshot.allowsInactiveBiometricDismissal {
                // L'écran vient de se déverrouiller alors qu'un bouclier est
                // visible : le masquer aussitôt, même scène inactive. Le
                // succès Face ID arrive avant la réactivation (le dialogue
                // système désactive la scène) ; attendre `.active` laisserait
                // un bouclier vide — noir en mode sombre — affiché pendant la
                // fermeture du dialogue. Cette exception est réservée au
                // succès biométrique et s'efface au prochain changement de
                // phase ; le rideau ordinaire reste visible en arrière-plan.
                hide()
                return
            }
            guard state.requiresLock(snapshot) || snapshot.phase != .active else { hide(); return }
            guard shield == nil else { return }
            previousAccessibilityHidden = owner.accessibilityElementsHidden
            owner.accessibilityElementsHidden = true
            let host = UIHostingController(rootView: LockPresentation(state: state))
            host.view.backgroundColor = .systemGroupedBackground
            host.view.accessibilityViewIsModal = true
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = host
            shield = window
            window.makeKeyAndVisible()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }

        private func hide() {
            guard let shield else { return }
            shield.isHidden = true
            shield.rootViewController = nil
            self.shield = nil
            owner?.accessibilityElementsHidden = previousAccessibilityHidden
            owner?.makeKey()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }

        func stop() {
            FileDownloadService.shared.updatePresentation(isAllowed: false, window: nil)
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            subscription = nil
            hide()
        }
    }
}
