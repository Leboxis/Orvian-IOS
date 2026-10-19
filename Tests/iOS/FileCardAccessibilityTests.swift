import SwiftUI
import XCTest
@testable import Orvian

@MainActor
final class FileCardAccessibilityTests: XCTestCase {
    func testDetailsWaitsUntilContextMenuHasReleasedItsCard() {
        let dismissal = ContextMenuDismissal()
        var openings = 0
        dismissal.begin()
        dismissal.perform { openings += 1 }
        XCTAssertEqual(openings, 0, "The inspector must not resize the menu's anchor during dismissal")
        dismissal.complete()
        XCTAssertEqual(openings, 1)
        dismissal.complete()
        XCTAssertEqual(openings, 1, "A completion must not open details twice")
        dismissal.perform { openings += 1 }
        XCTAssertEqual(openings, 2, "Actions without an active menu remain immediate")
        dismissal.begin()
        dismissal.complete()
        XCTAssertEqual(openings, 2, "Cancelling a menu must not open details")
    }
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testCardHasAccessibleActivationSelectionAndContextActions() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let file = DriveFile.root(name: "Dossier accessible")
        var opened = 0
        var renamed = false
        let card = FileCardView(file: file, driveId: 42,
            onPresent: { if case .rename = $0 { renamed = true } },
            action: { opened += 1 })
            .frame(width: 180)
        let host = UIHostingController(rootView: AnyView(card))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        await Task.yield()
        host.view.layoutIfNeeded()
        let button = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == file.name })
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
        XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        let interaction = try XCTUnwrap(button.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
        // L'appui long ouvre le menu : la carte ne doit jamais rester grisée.
        // Sur iPhone un retour visuel s'affiche à l'appui et l'ouverture du
        // menu doit l'effacer ; sur iPad il n'y a pas de retour du tout.
        button.isHighlighted = true
        let configuration = try XCTUnwrap(interaction.delegate?.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero))
        XCTAssertEqual(button.backgroundColor, .clear, "A long press must not gray the card")
        let preview = try XCTUnwrap(interaction.delegate?.contextMenuInteraction?(interaction, previewForHighlightingMenuWithConfiguration: configuration))
        XCTAssertEqual(preview.parameters.backgroundColor, .clear)
        XCTAssertTrue(preview.parameters.shadowPath?.isEmpty == true, "The native preview must not outline the whole card")
        XCTAssertTrue(button.accessibilityActivate())
        XCTAssertEqual(opened, 1)
        let rename = try XCTUnwrap(button.accessibilityCustomActions?.first { $0.name == "Renommer" })
        XCTAssertEqual(rename.actionHandler?(rename), true)
        XCTAssertTrue(renamed)

        var selected = 0
        let selectionCard = FileCardView(file: file, driveId: 42,
            selectionMode: true, isSelected: true,
            onToggleSelection: { selected += 1 }, action: {})
            .frame(width: 180)
        host.rootView = AnyView(selectionCard)
        await Task.yield()
        host.view.layoutIfNeeded()
        let selection = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == file.name })
        XCTAssertTrue(selection.accessibilityTraits.contains(.selected))
        XCTAssertTrue(selection.accessibilityCustomActions?.isEmpty == true)
        XCTAssertTrue(selection.accessibilityActivate())
        XCTAssertEqual(selected, 1)

        host.rootView = AnyView(selectionCard.disabled(true))
        await Task.yield()
        host.view.layoutIfNeeded()
        let locked = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == file.name })
        XCTAssertFalse(locked.isEnabled)
        XCTAssertFalse(locked.accessibilityActivate())
        XCTAssertEqual(selected, 1)
    }

    func testPresentationOrderAndFavoriteSymbolsAreConsistent() {
        XCTAssertEqual(AppTab.presentationOrder, [.settings, .tag, .home, .favorites, .profile])
        XCTAssertEqual(AppTab.favorites.symbol, "star")
        XCTAssertEqual(AppTab.favorites.symbolFilled, "star.fill")
    }
}
