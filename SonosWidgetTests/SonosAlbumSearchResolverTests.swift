import XCTest
@testable import SonosWidget

final class SonosAlbumSearchResolverTests: XCTestCase {
    func testResolvesAlbumIDByExactTitleAndArtist() throws {
        let result = try decodeSearchResponse(
            """
            {
              "resourceOrder": ["albums"],
              "albums": {
                "resources": [
                  {
                    "type": "ALBUM",
                    "name": "一百種生活",
                    "id": { "objectId": "album:123456789", "serviceId": "52231", "accountId": "2" },
                    "artists": [{ "name": "Crowd Lu" }]
                  },
                  {
                    "type": "ALBUM",
                    "name": "一百種生活",
                    "id": { "objectId": "album:987654321", "serviceId": "52231", "accountId": "2" },
                    "artists": [{ "name": "Another Artist" }]
                  }
                ]
              }
            }
            """
        )

        XCTAssertEqual(
            SonosAlbumSearchResolver.preferredAlbumID(
                in: result,
                title: "一百種生活",
                artist: "Crowd Lu"
            ),
            "album:123456789"
        )
    }

    func testRejectsTitleOnlyObjectIDFromSearchResults() throws {
        let result = try decodeSearchResponse(
            """
            {
              "resourceOrder": ["albums"],
              "albums": {
                "resources": [
                  {
                    "type": "ALBUM",
                    "name": "一百種生活",
                    "id": { "objectId": "一百種生活", "serviceId": "52231", "accountId": "2" },
                    "artists": [{ "name": "Crowd Lu" }]
                  }
                ]
              }
            }
            """
        )

        XCTAssertNil(
            SonosAlbumSearchResolver.preferredAlbumID(
                in: result,
                title: "一百種生活",
                artist: "Crowd Lu"
            )
        )
    }

    private func decodeSearchResponse(_ json: String) throws -> SonosCloudAPI.ServiceSearchResponse {
        try JSONDecoder().decode(SonosCloudAPI.ServiceSearchResponse.self, from: Data(json.utf8))
    }
}
