import XCTest
@testable import SonosWidget

final class DetailArtworkURLSelectionTests: XCTestCase {
    func testPrefersResponseArtworkOverEntryArtwork() {
        let url = DetailArtworkURLSelection.firstAvailable(
            entryArtworkURL: "https://example.com/favorite.jpg",
            responseArtworkURL: "https://example.com/response.jpg",
            fallbackArtworkURL: nil
        )

        XCTAssertEqual(url, "https://example.com/response.jpg")
    }

    func testUsesResponseArtworkWhenEntryArtworkIsMissing() {
        let url = DetailArtworkURLSelection.firstAvailable(
            entryArtworkURL: nil,
            responseArtworkURL: "https://example.com/response.jpg",
            fallbackArtworkURL: nil
        )

        XCTAssertEqual(url, "https://example.com/response.jpg")
    }

    func testUsesFallbackArtworkWhenEntryAndResponseArtworkAreMissing() {
        let url = DetailArtworkURLSelection.firstAvailable(
            entryArtworkURL: " ",
            responseArtworkURL: nil,
            fallbackArtworkURL: "https://example.com/track.jpg"
        )

        XCTAssertEqual(url, "https://example.com/track.jpg")
    }
}
