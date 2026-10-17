import XCTest
@testable import Orvian

@MainActor
final class IPadScreenStateTests: XCTestCase {
    func testChangingTagClearsThePreviousFolderPath() {
        var navigation = IPadTagNavigation()
        navigation.select(10)
        navigation.folders = [.root(name: "Ancien dossier")]
        navigation.select(20)
        XCTAssertEqual(navigation.categoryID, 20)
        XCTAssertTrue(navigation.folders.isEmpty)
    }

    func testSelectingTheSameTagReturnsToItsRoot() {
        var navigation = IPadTagNavigation()
        navigation.select(10)
        navigation.folders = [.root(name: "Sous-dossier")]
        navigation.select(10)
        XCTAssertEqual(navigation.categoryID, 10)
        XCTAssertTrue(navigation.folders.isEmpty)
        navigation.select(nil)
        XCTAssertNil(navigation.categoryID)
    }

    func testTagResetDoesNotChangeHomeOrSettings() {
        let navigation = TabNavigationState()
        let home = [DriveFile.root(name: "Accueil conservé")]
        navigation.homePath = home
        navigation.iPadTags.select(20)
        navigation.iPadTags.folders = [.root(name: "Dossier de tag")]
        navigation.settingsSelection = .security
        navigation.reset(tab: .tag)
        XCTAssertNil(navigation.iPadTags.categoryID)
        XCTAssertTrue(navigation.iPadTags.folders.isEmpty)
        XCTAssertEqual(navigation.homePath, home)
        XCTAssertEqual(navigation.settingsSelection, .security)
        navigation.reset(tab: .settings)
        XCTAssertEqual(navigation.settingsSelection, .appearance)
    }
}
