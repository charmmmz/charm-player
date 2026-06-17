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

    func testFittedDisplaySizePreservesWideArtworkInsideSquareBounds() {
        let size = LocalMusicArtworkURL.fittedDisplaySize(
            maximumWidth: 1200,
            maximumHeight: 600,
            boundingWidth: 300,
            boundingHeight: 300)

        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 150)
    }

    func testFittedDisplaySizePreservesTallArtworkInsideSquareBounds() {
        let size = LocalMusicArtworkURL.fittedDisplaySize(
            maximumWidth: 600,
            maximumHeight: 1200,
            boundingWidth: 300,
            boundingHeight: 300)

        XCTAssertEqual(size.width, 150)
        XCTAssertEqual(size.height, 300)
    }

    func testFittedDisplaySizeFallsBackToBoundsWhenSourceSizeIsUnknown() {
        let size = LocalMusicArtworkURL.fittedDisplaySize(
            maximumWidth: 0,
            maximumHeight: 0,
            boundingWidth: 300,
            boundingHeight: 280)

        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 280)
    }

    func testFilledDisplaySizeCoversStationCardWithWideArtwork() {
        let size = LocalMusicArtworkURL.filledDisplaySize(
            maximumWidth: 4320,
            maximumHeight: 1080,
            boundingWidth: 184,
            boundingHeight: 104)

        XCTAssertEqual(size.width, 416)
        XCTAssertEqual(size.height, 104)
    }

    func testStationCardsUseAlbumSizedSquareArtwork() {
        XCTAssertEqual(
            LocalServiceCardArtworkMetrics.size(isStationLike: true),
            LocalServiceCardArtworkSize(width: 138, height: 138))
    }

    func testStationCardsFillWideArtworkFromCenter() {
        XCTAssertEqual(
            LocalServiceCardArtworkMetrics.contentMode(
                isStationLike: true,
                maximumWidth: 4320,
                maximumHeight: 1080),
            .fill)
    }

    func testStationCardsFitSquareArtwork() {
        XCTAssertEqual(
            LocalServiceCardArtworkMetrics.contentMode(
                isStationLike: true,
                maximumWidth: 1200,
                maximumHeight: 1200),
            .fit)
    }

    func testNonStationCardsFillWideArtworkFromCenter() {
        XCTAssertEqual(
            LocalServiceCardArtworkMetrics.contentMode(
                isStationLike: false,
                maximumWidth: 4320,
                maximumHeight: 1080),
            .fill)
    }

    func testImageDownloadURLResolvesRelativeMusicKitPlaylistArtworkToAppleCDN() {
        let url = URL(
            string: "musicKit://artwork/library/ABC/600x600?aat=Features125%2Fv4%2Fad%2F0e%2F48%2Fcover%2Epng&at=playlist&et=collection"
        )!

        XCTAssertEqual(
            LocalMusicArtworkURL.imageDownloadURL(from: url, shortSidePixels: 600)?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Features125/v4/ad/0e/48/cover.png/600x600bb.jpg"
        )
    }

    func testLoadableURLRejectsUnstructuredRelativeMusicKitArtworkAAT() {
        let url = URL(
            string: "musicKit://artwork/library/ABC/600x600?aat=not-a-real-artwork-path&at=playlist&et=collection"
        )!

        XCTAssertNil(LocalMusicArtworkURL.loadableURL(from: url, shortSidePixels: 600))
    }

    func testArtworkSourcePrefersMusicKitArtworkOverRemoteURL() {
        let remoteURL = URL(string: "https://example.com/cover.jpg")

        XCTAssertEqual(
            LocalMusicArtworkSourcePolicy.preferredKind(
                hasMusicKitArtwork: true,
                remoteURL: remoteURL
            ),
            .musicKit
        )
    }

    func testArtworkSourceFallsBackToRemoteURL() {
        let remoteURL = URL(string: "https://example.com/cover.jpg")

        XCTAssertEqual(
            LocalMusicArtworkSourcePolicy.preferredKind(
                hasMusicKitArtwork: false,
                remoteURL: remoteURL
            ),
            .remote
        )
    }

    func testArtworkSourceUsesPlaceholderWithoutArtworkInputs() {
        XCTAssertEqual(
            LocalMusicArtworkSourcePolicy.preferredKind(
                hasMusicKitArtwork: false,
                remoteURL: nil
            ),
            .placeholder
        )
    }

    func testDetailArtworkUsesFillForWidePlaylistCovers() {
        XCTAssertEqual(
            LocalMusicDetailArtworkPresentation.contentMode(
                maximumWidth: 4320,
                maximumHeight: 1080
            ),
            .fill
        )
    }
}
