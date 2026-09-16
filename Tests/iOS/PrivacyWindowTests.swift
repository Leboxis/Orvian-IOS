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

    func testOldUnlockCannotBypassANewBackgroundLock() {
        let privacy = AppPrivacyState(isLockConfigured: { true })
        let oldGeneration = privacy.snapshot.generation
        privacy.transition(to: .background)
        privacy.transition(to: .active)
        privacy.unlock(generation: oldGeneration)
        XCTAssertTrue(privacy.requiresLock(privacy.snapshot))
        privacy.unlock(generation: privacy.snapshot.generation)
        XCTAssertFalse(privacy.requiresLock(privacy.snapshot))
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

        privacy.transition(to: .background)
        privacy.transition(to: .active)
        try await settle()
        let shield = try XCTUnwrap(scene.windows.first { !$0.isHidden && $0.windowLevel > .alert })
        XCTAssertTrue(shield.isKeyWindow)
        XCTAssertTrue(owner.accessibilityElementsHidden)
        XCTAssertTrue(host.presentedViewController === photo)
        let mounts = state.mounts

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
