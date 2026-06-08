import XCTest
@testable import SonosWidget

final class LocalMusicArtworkURLTests: XCTestCase {
    func testFittedRequestSizePreservesWideArtworkAspectRatio() {
        let size = LocalMusicArtworkURL.fittedRequestSize(
            maximumWidth: 1200,
            maximumHeight: 600,
            shortSidePixels: 300)

        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 300)
    }

    func testFittedRequestSizePreservesTallArtworkAspectRatio() {
        let size = LocalMusicArtworkURL.fittedRequestSize(
            maximumWidth: 600,
            maximumHeight: 1200,
            shortSidePixels: 300)

        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 600)
    }

    func testFittedRequestSizeKeepsSquareArtworkSquare() {
        let size = LocalMusicArtworkURL.fittedRequestSize(
            maximumWidth: 1200,
            maximumHeight: 1200,
            shortSidePixels: 300)

        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 300)
    }

    func testFittedRequestSizeFallsBackToRequestedSquareWhenSourceSizeIsUnknown() {
        let size = LocalMusicArtworkURL.fittedRequestSize(
            maximumWidth: 0,
            maximumHeight: 0,
            shortSidePixels: 300)

        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 300)
    }
}
