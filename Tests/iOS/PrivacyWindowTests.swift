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

    func testPrivacyShieldSurvivesInactiveRendersAndBackgroundWithoutPIN() throws {
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
        let shield = try XCTUnwrap(scene.keyWindow)
        XCTAssertTrue(shield !== owner && shield.windowLevel > .alert)
        coordinator.attach(to: owner) // SwiftUI peut rendre plusieurs fois en phase inactive.
        XCTAssertFalse(shield.isHidden)
        privacy.transition(to: .background)
        XCTAssertFalse(shield.isHidden)
        XCTAssertTrue(owner.accessibilityElementsHidden)
        privacy.transition(to: .active)
        XCTAssertTrue(shield.isHidden)
        XCTAssertTrue(owner.isKeyWindow)
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
        let protectedImage = UIGraphicsImageRenderer(bounds: shield.bounds).image { _ in
            shield.drawHierarchy(in: shield.bounds, afterScreenUpdates: true)
        }
        let protectedAttachment = XCTAttachment(image: protectedImage)
        protectedAttachment.name = "Verrouillage-au-dessus-photo"
        protectedAttachment.lifetime = .keepAlways
        add(protectedAttachment)
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
            for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 844, height: 240)] {
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
                let image = UIGraphicsImageRenderer(size: size).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Pavé-\(dark ? "sombre" : "clair")-\(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
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
