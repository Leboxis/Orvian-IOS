import SwiftUI
import XCTest
@testable import Orvian

@MainActor
final class IPadLayoutTests: XCTestCase {
    func testSettingsRouteSurvivesLayoutChangesAndTabRevisits() {
        let navigation = TabNavigationState()
        navigation.settingsPath = [.security]
        XCTAssertEqual(navigation.settingsPath.last, .security)
        // Le même état appartient à la session, pas à la vue de Réglages recréée.
        navigation.reset(tab: .home)
        XCTAssertEqual(navigation.settingsPath.last, .security)
        navigation.reset(tab: .settings)
        XCTAssertTrue(navigation.settingsPath.isEmpty)
    }

    func testDefaultEnvironmentPreservesPhoneChrome() {
        let layout = EnvironmentValues().driveLayout
        XCTAssertFalse(layout.isPad)
        XCTAssertEqual(layout.bottomInset, DS.floatingBarInset)
        XCTAssertEqual(layout.actionInset, DS.floatingActionInset)
        XCTAssertEqual(layout.pillInset, DS.floatingPillInset)
        XCTAssertEqual(layout.maxGridWidth, DS.maxContentWidth)
    }

    func testHiddenSidebarExpandsGridWithoutChangingStoredDensity() {
        let visible = DriveLayout(isPad: true, width: 1_000)
        let hidden = DriveLayout(isPad: true, width: 1_260)
        XCTAssertGreaterThan(hidden.fileColumns(preferred: 3), visible.fileColumns(preferred: 3))
        XCTAssertEqual(hidden.maxGridWidth, .infinity)
        XCTAssertLessThan(hidden.actionInset, hidden.pillInset)
        XCTAssertLessThan(hidden.bottomInset, DS.floatingBarInset)
        XCTAssertFalse(DriveLayout(isPad: true, width: 500).usesTwoColumns)
    }
}
