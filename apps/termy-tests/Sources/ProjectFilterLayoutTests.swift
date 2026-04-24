import XCTest
@testable import termy

final class ProjectFilterLayoutTests: XCTestCase {
    func test_centeredContent_getsLeadingInset() {
        XCTAssertEqual(
            ProjectFilterLayout.leadingInset(contentWidth: 240, viewportWidth: 500),
            130
        )
    }

    func test_overflowingContent_staysLeadingAligned() {
        XCTAssertEqual(
            ProjectFilterLayout.leadingInset(contentWidth: 640, viewportWidth: 500),
            0
        )
    }

    func test_documentWidth_expandsToViewportWhenCentered() {
        XCTAssertEqual(
            ProjectFilterLayout.documentWidth(contentWidth: 240, viewportWidth: 500),
            500
        )
    }

    func test_documentWidth_preservesScrollableContentWidth() {
        XCTAssertEqual(
            ProjectFilterLayout.documentWidth(contentWidth: 640, viewportWidth: 500),
            640
        )
    }

    func test_buttonWidths_preserveNaturalWidthsWhenTheyFit() {
        XCTAssertEqual(
            ProjectFilterLayout.buttonWidths(
                naturalWidths: [80, 90],
                spacing: 6,
                viewportWidth: 200
            ),
            [80, 90]
        )
    }

    func test_buttonWidths_shrinkEvenlyToFitViewport() {
        XCTAssertEqual(
            ProjectFilterLayout.buttonWidths(
                naturalWidths: [120, 100, 90],
                spacing: 6,
                viewportWidth: 252
            ),
            [80, 80, 80]
        )
    }

    func test_buttonWidths_useMinimumWidthWhenTooManyFiltersFit() {
        XCTAssertEqual(
            ProjectFilterLayout.buttonWidths(
                naturalWidths: [120, 100, 90],
                spacing: 6,
                viewportWidth: 132
            ),
            [48, 48, 48]
        )
    }
}
