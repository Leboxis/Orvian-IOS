import SwiftUI
import XCTest
@testable import Orvian

final class IPadLayoutTests: XCTestCase {
    func testPhoneColumnsKeepTheirStoredMeaning() {
        let phone = IPadLayout(isPad: false, width: 430)
        XCTAssertEqual(phone.fileColumns(preferred: 3, margin: 14, spacing: 10), 3)
        XCTAssertEqual(phone.fileColumns(preferred: 0, margin: 14, spacing: 10), 2)
        XCTAssertEqual(phone.fileColumns(preferred: 99, margin: 14, spacing: 10), 3)
        XCTAssertEqual(phone.horizontalInset(base: 14), 14)
        XCTAssertFalse(phone.usesTwoColumns)
        XCTAssertEqual(phone.recentPreviewLimit, 3)
    }

    func testPadColumnsUseTheActualPaneWidth() {
        let wide = IPadLayout(isPad: true, width: 1366)
        let pane = IPadLayout(isPad: true, width: 760)
        XCTAssertEqual(wide.fileColumns(preferred: 3, margin: 14, spacing: 10), 5)
        XCTAssertEqual(pane.fileColumns(preferred: 3, margin: 14, spacing: 10), 2)
        XCTAssertEqual(wide.horizontalInset(base: 14), 28)
        XCTAssertTrue(wide.usesTwoColumns)
        XCTAssertEqual(wide.recentPreviewLimit, 6)
        XCTAssertFalse(pane.usesTwoColumns)
    }

    func testNarrowAndInvalidGeometryNeverProduceInvalidColumns() {
        for width: CGFloat in [0, -1, .nan, .infinity, .greatestFiniteMagnitude, 320] {
            let layout = IPadLayout(isPad: true, width: width)
            let columns = layout.fileColumns(preferred: 3, margin: 14, spacing: 10)
            XCTAssertTrue((1...12).contains(columns))
        }
        XCTAssertEqual(IPadLayout(isPad: true, width: 320).fileColumns(preferred: 3, margin: 14, spacing: 10), 1)
    }

    func testAccessibilityTextUsesFewerColumnsAndASingleReadingColumn() {
        let regular = IPadLayout(isPad: true, width: 1366)
        let accessible = IPadLayout(isPad: true, width: 1366, largeText: true)
        XCTAssertLessThan(accessible.fileColumns(preferred: 3, margin: 14, spacing: 10),
                          regular.fileColumns(preferred: 3, margin: 14, spacing: 10))
        XCTAssertFalse(accessible.usesTwoColumns)
        XCTAssertEqual(accessible.recentPreviewLimit, 3)
    }

    func testPhoneMinimumSizeAndAccessibleText() {
        for width: CGFloat in [320, 375, 430] {
            let phone = IPadLayout(isPad: false, width: width)
            let count = phone.fileColumns(preferred: 7, margin: 14, spacing: 10)
            XCTAssertGreaterThanOrEqual((width - 28 - CGFloat(count - 1) * 10) / CGFloat(count), 100)
            XCTAssertEqual(IPadLayout(isPad: false, width: width, largeText: true)
                .fileColumns(preferred: 7, margin: 14, spacing: 10), 1)
        }
        let pad = IPadLayout(isPad: true, width: 1366)
        XCTAssertEqual(Set((2...7).map { pad.fileColumns(preferred: $0, margin: 14, spacing: 10) }).count, 6)
    }
}
