import XCTest
@testable import SonosWidget

final class RelayArtworkHintTests: XCTestCase {
    func testArtworkHintsBodyEncodesBrowseItemArtworkHints() throws {
        let item = BrowseItem(
            id: "song:123",
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg",
            uri: "x-sonos-http:song%3A123.mp4?sid=204&flags=8232&sn=2",
            isContainer: false,
            serviceId: 52231,
            cloudType: "TRACK"
        )

        let body = RelayClient.ArtworkHintsBody(items: [item])
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hints = try XCTUnwrap(json["hints"] as? [[String: Any]])

        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints[0]["id"] as? String, "song:123")
        XCTAssertEqual(hints[0]["uri"] as? String, "x-sonos-http:song%3A123.mp4?sid=204&flags=8232&sn=2")
        XCTAssertEqual(hints[0]["title"] as? String, "Moon")
        XCTAssertEqual(hints[0]["artist"] as? String, "Daniel Caesar")
        XCTAssertEqual(hints[0]["album"] as? String, "Freudian")
        XCTAssertEqual(hints[0]["cloudType"] as? String, "TRACK")
        XCTAssertEqual(
            hints[0]["artworkUrl"] as? String,
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg"
        )
    }

    func testArtworkHintsBodyDropsItemsWithoutRemoteArtwork() {
        let body = RelayClient.ArtworkHintsBody(items: [
            BrowseItem(
                id: "song:123",
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian",
                albumArtURL: nil,
                isContainer: false,
                cloudType: "TRACK"
            )
        ])

        XCTAssertTrue(body.hints.isEmpty)
    }
}
