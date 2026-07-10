import XCTest
@testable import SonosWidget

final class DetailArtworkImageLoadPolicyTests: XCTestCase {
    func testKeepsDisplayedImageWhileReplacementURLIsLoading() {
        XCTAssertTrue(
            DetailArtworkImageLoadPolicy.shouldKeepDisplayingLoadedImage(
                hasLoadedImage: true,
                selectedURL: "https://example.com/high.jpg",
                loadedURL: "https://example.com/low.jpg"
            )
        )
    }

    func testDoesNotCommitStaleImageAfterSelectedURLChanges() {
        XCTAssertFalse(
            DetailArtworkImageLoadPolicy.shouldCommitLoadedImage(
                requestedURL: "https://example.com/low.jpg",
                selectedURL: "https://example.com/high.jpg"
            )
        )
    }

    func testCommitsLoadedImageWhenRequestStillMatchesSelectedURL() {
        XCTAssertTrue(
            DetailArtworkImageLoadPolicy.shouldCommitLoadedImage(
                requestedURL: "https://example.com/high.jpg",
                selectedURL: "https://example.com/high.jpg"
            )
        )
    }
}
