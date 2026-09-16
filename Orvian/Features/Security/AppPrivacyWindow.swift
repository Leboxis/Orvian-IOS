import SwiftUI
import UIKit

/// Fenêtre de protection au-dessus des présentations SwiftUI/UIKit. L'arbre
/// principal reste vivant, mais n'est ni touchable ni parcourable par VoiceOver.
struct AppPrivacyWindow<Content: View>: UIViewRepresentable {
    let isVisible: Bool
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.onAttach = { [weak coordinator = context.coordinator] owner in
            coordinator?.attach(to: owner)
        }
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.content = content()
        context.coordinator.isVisible = isVisible
        context.coordinator.attach(to: view.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
        coordinator.hide()
    }

    final class AttachmentView: UIView {
        var onAttach: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onAttach?(window)
        }
    }

    final class Coordinator {
        var content: Content?
        var isVisible = false
        private weak var owner: UIWindow?
        private var shield: UIWindow?
        private var host: UIHostingController<Content>?
        private var previousAccessibilityHidden = false

        func attach(to window: UIWindow?) {
            // Une présentation .fullScreen retire temporairement la vue
            // d'attache de sa fenêtre. Le propriétaire mémorisé reste valide.
            guard let owner = window ?? owner,
                  let scene = owner.windowScene, let content else { return }
            self.owner = owner
            guard isVisible else { hide(); return }
            if let host { host.rootView = content; return }
            previousAccessibilityHidden = owner.accessibilityElementsHidden
            owner.accessibilityElementsHidden = true
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .systemGroupedBackground
            host.view.accessibilityViewIsModal = true
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = host
            self.host = host
            shield = window
            window.makeKeyAndVisible()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }

        func hide() {
            guard let shield else { return }
            shield.isHidden = true
            shield.rootViewController = nil
            self.shield = nil
            host = nil
            owner?.accessibilityElementsHidden = previousAccessibilityHidden
            owner?.makeKey()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
}
