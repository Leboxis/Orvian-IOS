import XCTest
import SwiftUI
@testable import Orvian

@MainActor
final class PrivacyWindowTests: XCTestCase {
    final class State: ObservableObject {
        var mounts = 0
    }

    struct RetainedContent: View {
        let state: State
        @SwiftUI.State private var identity = UUID()
        var body: some View {
            Text("Contenu privé \(identity)")
                .onAppear { state.mounts += 1 }
        }
    }

    struct Fixture: View {
        @ObservedObject var state: State
        let privacy: AppPrivacyState
        var body: some View {
            RetainedContent(state: state)
                .background {
                    AppPrivacyWindow(state: privacy)
                }
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    func testOldUnlockCannotBypassANewBackgroundLock() async {
        let privacy = AppPrivacyState(isLockConfigured: { true })
        let oldGeneration = privacy.snapshot.generation
        privacy.transition(to: .background)
        privacy.transition(to: .active)
        privacy.unlock(generation: oldGeneration)
        XCTAssertTrue(privacy.requiresLock(privacy.snapshot))
        privacy.unlock(generation: privacy.snapshot.generation)
        XCTAssertFalse(privacy.requiresLock(privacy.snapshot))
    }

    func testBiometricUnlockAcceptedWhileSceneInactive() async {
        // Le dialogue système Face ID désactive la scène : le succès arrive
        // pendant que la phase est encore .inactive, avant la réactivation.
        let privacy = AppPrivacyState(isLockConfigured: { true })
        privacy.transition(to: .background)
        XCTAssertTrue(privacy.requiresLock(privacy.snapshot))
        privacy.transition(to: .inactive)
        privacy.unlockAfterBiometrics()
        XCTAssertFalse(privacy.requiresLock(privacy.snapshot))
    }

    func testBiometricUnlockRefusedInBackground() async {
        // L'arrière-plan ré-arme le verrouillage : aucun succès biométrique
        // ne peut déverrouiller depuis cet état.
        let privacy = AppPrivacyState(isLockConfigured: { true })
        privacy.transition(to: .background)
        privacy.unlockAfterBiometrics()
        XCTAssertTrue(privacy.requiresLock(privacy.snapshot))
    }

    func testFirstTapAllowedAsSoonAsBiometricUnlockSucceeds() {
        // Succès Face ID scène encore inactive : le contenu est déjà visible
        // (bouclier masqué aussitôt) — le premier tap ne doit pas être avalé
        // en attendant la réactivation.
        let privacy = AppPrivacyState(isLockConfigured: { true })
        privacy.transition(to: .background)
        privacy.transition(to: .inactive)
        privacy.unlockAfterBiometrics()
        XCTAssertTrue(privacy.allowsInteraction(privacy.snapshot))
        // Le ré-armement au passage en arrière-plan rebloque l'interaction.
        privacy.transition(to: .background)
        XCTAssertFalse(privacy.allowsInteraction(privacy.snapshot))
    }

    func testBiometricUnlockWhileInactiveHidesShieldAtOnce() async throws {
        // Le succès Face ID arrive scène encore inactive (le dialogue
        // système désactive la scène, la réactivation suit). Le bouclier
        // doit disparaître aussitôt, sans laisser un écran vide/noir en
        // attendant la réactivation.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let owner = UIWindow(windowScene: scene)
        let state = State()
        let privacy = AppPrivacyState(isLockConfigured: { true })
        privacy.unlock(generation: privacy.snapshot.generation)
        owner.rootViewController = UIHostingController(rootView: Fixture(state: state, privacy: privacy))
        owner.makeKeyAndVisible()
        defer {
            owner.isHidden = true
            owner.rootViewController = nil
            original?.makeKey()
        }
        try await settle()

        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        try await settle()
        let shield = try XCTUnwrap(scene.keyWindow)
        XCTAssertTrue(!shield.isHidden && shield.windowLevel > .alert)
        XCTAssertTrue(shield !== owner)

        // Retour au premier plan puis dialogue Face ID : l'écran reste
        // verrouillé et couvert dans les deux phases.
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await settle()
        XCTAssertFalse(shield.isHidden)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        try await settle()
        XCTAssertFalse(shield.isHidden)

        // Succès biométrique scène inactive : le bouclier se masque
        // immédiatement et rend la clé, avant même la réactivation.
        privacy.unlockAfterBiometrics()
        try await settle()
        XCTAssertTrue(shield.isHidden)
        XCTAssertTrue(owner.isKeyWindow)

        // La réactivation qui suit ne fait rien réapparaître.
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await settle()
        XCTAssertTrue(shield.isHidden)
    }

    func testColdStartBuildsLockWindowBeforePrivateContent() async throws {
        try await AppLockStore.save("1234")
        defer { AppLockStore.clear() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let owner = UIWindow(windowScene: scene)
        owner.rootViewController = UIHostingController(rootView:
            RootView(session: SessionStore()).environment(\.scenePhase, .active))
        owner.makeKeyAndVisible()
        defer {
            owner.isHidden = true
            owner.rootViewController = nil
            original?.makeKey()
        }
        try await settle()
        XCTAssertNotNil(scene.windows.first { !$0.isHidden && $0.windowLevel > .alert })
        XCTAssertTrue(owner.accessibilityElementsHidden)
    }

    func testShieldCoversBackgroundButNotTransientInactivityWithoutPIN() throws {
        // AirPlay, le Centre de contrôle et le Centre de notifications rendent
        // la scène inactive sans quitter l'app : aucun voile ne doit couvrir la
        // vidéo. Le masque reste réservé à l'arrière-plan, instant où le
        // système capture l'aperçu du sélecteur d'applications.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.keyWindow
        let owner = UIWindow(windowScene: scene)
        owner.rootViewController = UIViewController()
        owner.makeKeyAndVisible()
        let privacy = AppPrivacyState(isLockConfigured: { false })
        let coordinator = AppPrivacyWindow.Coordinator(state: privacy)
        defer {
            coordinator.stop()
            owner.isHidden = true
            original?.makeKey()
        }
        coordinator.attach(to: owner)
        privacy.transition(to: .inactive)
        XCTAssertNil(scene.windows.first { !$0.isHidden && $0.windowLevel > .alert && $0 !== owner },
                     "Transient inactivity must not raise the shield")
        XCTAssertFalse(owner.accessibilityElementsHidden)
        coordinator.attach(to: owner) // SwiftUI peut rendre plusieurs fois en phase inactive.
        XCTAssertNil(scene.windows.first { !$0.isHidden && $0.windowLevel > .alert && $0 !== owner })

        privacy.transition(to: .background)
        let shield = try XCTUnwrap(scene.windows.first { !$0.isHidden && $0.windowLevel > .alert && $0 !== owner })
        XCTAssertTrue(owner.accessibilityElementsHidden)
        XCTAssertTrue(scene.keyWindow === shield)

        privacy.transition(to: .active)
        XCTAssertTrue(shield.isHidden)
        XCTAssertTrue(owner.isKeyWindow)
        XCTAssertFalse(owner.accessibilityElementsHidden)
    }

    func testInactivityLeavesLockedContentBehindTheShield() throws {
        // Avec un code configuré, le voile reste en place pendant l'inactivité :
        // il protège le contenu, pas seulement l'aperçu du sélecteur.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.keyWindow
        let owner = UIWindow(windowScene: scene)
        owner.rootViewController = UIViewController()
        owner.makeKeyAndVisible()
        let privacy = AppPrivacyState(isLockConfigured: { true })
        let coordinator = AppPrivacyWindow.Coordinator(state: privacy)
        defer {
            coordinator.stop()
            owner.isHidden = true
            original?.makeKey()
        }
        coordinator.attach(to: owner)
        privacy.transition(to: .inactive)
        // Le voile est vérifié par sa présence au-dessus du contenu, pas par
        // la clé de la scène : l'app hôte des tests possède ses propres
        // fenêtres et peut reprendre la clé entre deux rendus. `makeKey` reste
        // demandé par le coordinateur, mais n'est pas ce qui protège le
        // contenu — le niveau de fenêtre et le masque d'accessibilité, si.
        let shield = try XCTUnwrap(scene.windows.first { !$0.isHidden && $0.windowLevel > .alert && $0 !== owner })
        XCTAssertTrue(owner.accessibilityElementsHidden)
        XCTAssertGreaterThan(shield.windowLevel, owner.windowLevel)
    }

    func testShieldCoversPresentedMediaAndPreservesContent() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let owner = UIWindow(windowScene: scene)
        let state = State()
        let privacy = AppPrivacyState(isLockConfigured: { true })
        privacy.unlock(generation: privacy.snapshot.generation)
        let host = UIHostingController(rootView: Fixture(state: state, privacy: privacy))
        owner.rootViewController = host
        owner.makeKeyAndVisible()
        defer {
            owner.isHidden = true
            owner.rootViewController = nil
            original?.makeKey()
        }
        try await settle()
        let photo = UIHostingController(rootView: Color.red.overlay(Text("PHOTO PRIVÉE")))
        photo.modalPresentationStyle = .fullScreen
        host.present(photo, animated: false)
        try await settle()

        // D'abord l'arrière-plan seul : le bouclier doit déjà couvrir la photo
        // et détenir la clé. L'activation suit ensuite (le déverrouillage
        // exige la phase active). Deux raisons à cet ordre : la vraie app hôte
        // partage la scène et, à l'activation, elle masque son propre bouclier
        // puis redonne la clé à sa fenêtre — ce qui volerait la clé du bouclier
        // du test si on contrôlait après les deux notifications d'un coup.
        // Et on lit la fenêtre clé plutôt que la première fenêtre d'alerte :
        // l'hôte crée lui aussi un bouclier visible à l'arrière-plan, le dernier
        // `makeKey` (celui du test, observateur enregistré après celui de
        // l'app) désigne le nôtre sans ambiguïté d'ordre du tableau.
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        try await settle()
        let shield = try XCTUnwrap(scene.keyWindow)
        XCTAssertTrue(!shield.isHidden && shield.windowLevel > .alert)
        XCTAssertTrue(shield !== owner)
        XCTAssertTrue(owner.accessibilityElementsHidden)
        XCTAssertTrue(host.presentedViewController === photo)
        let mounts = state.mounts

        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await settle()
        privacy.unlock(generation: privacy.snapshot.generation)
        try await settle()
        XCTAssertTrue(shield.isHidden)
        XCTAssertTrue(owner.isKeyWindow)
        XCTAssertFalse(owner.accessibilityElementsHidden)
        XCTAssertTrue(host.presentedViewController === photo)
        XCTAssertEqual(state.mounts, mounts, "Unlock must not rebuild the private view")
        host.dismiss(animated: false)
    }

    func testLockLayoutInBothThemesAndCompactHeight() async throws {
        for dark in [false, true] {
            for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 844, height: 240),
                         CGSize(width: 1024, height: 1366), CGSize(width: 1366, height: 1024), CGSize(width: 600, height: 900)] {
                let host = UIHostingController(rootView:
                    AppLockView(onUnlock: {})
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.dynamicTypeSize, .accessibility3)
                )
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first(where: \.isKeyWindow)
                let window = UIWindow(windowScene: scene)
                let container = UIViewController()
                window.rootViewController = container
                window.makeKeyAndVisible()
                container.addChild(host)
                container.view.addSubview(host.view)
                host.didMove(toParent: container)
                host.view.frame = CGRect(origin: .zero, size: size)
                host.view.layoutIfNeeded()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKey()
                }
                try await settle()
                func scrollViews(_ view: UIView) -> [UIScrollView] {
                    (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                let scroll = try XCTUnwrap(scrollViews(host.view).first)
                XCTAssertGreaterThan(scroll.contentSize.height, 0)
                if size.height < 300 {
                    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height,
                                         "The last keypad row must remain reachable by scrolling")
                }
            }
        }
    }
}
