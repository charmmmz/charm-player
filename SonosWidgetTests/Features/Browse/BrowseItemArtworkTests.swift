import XCTest
@testable import SonosWidget

final class BrowseItemArtworkTests: XCTestCase {
    func testArtworkURLsRoundTripAsThumbnailAndDetailFields() throws {
        let item = BrowseItem(
            id: "album:123",
            title: "Freudian",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "https://example.com/400.jpg",
            detailArtworkURL: "https://example.com/1200.jpg",
            isContainer: true,
            serviceId: 204,
            cloudType: "ALBUM"
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(BrowseItem.self, from: data)

        XCTAssertEqual(decoded.albumArtURL, "https://example.com/400.jpg")
        XCTAssertEqual(decoded.detailArtworkURL, "https://example.com/1200.jpg")
        XCTAssertEqual(decoded.thumbnailArtworkURL, "https://example.com/400.jpg")
        XCTAssertEqual(decoded.preferredDetailArtworkURL, "https://example.com/1200.jpg")
    }

    func testLegacyArtworkURLIsUsedAsDetailFallback() throws {
        let data = """
        [{
          "id": "album:123",
          "title": "Freudian",
          "artist": "Daniel Caesar",
          "album": "Freudian",
          "albumArtURL": "https://example.com/legacy.jpg",
          "isContainer": true,
          "serviceId": 204,
          "cloudType": "ALBUM"
        }]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([BrowseItem].self, from: data)

        XCTAssertEqual(decoded.first?.albumArtURL, "https://example.com/legacy.jpg")
        XCTAssertNil(decoded.first?.detailArtworkURL)
        XCTAssertEqual(decoded.first?.thumbnailArtworkURL, "https://example.com/legacy.jpg")
        XCTAssertEqual(decoded.first?.preferredDetailArtworkURL, "https://example.com/legacy.jpg")
    }
}
