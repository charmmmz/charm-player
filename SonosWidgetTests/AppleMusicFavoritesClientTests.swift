import XCTest
@testable import SonosWidget

final class AppleMusicFavoritesClientTests: XCTestCase {
    func testTrackResourceUsesResolvedAppleMusicSongID() {
        let item = BrowseItem(
            id: "track:local",
            title: "Dark Dune",
            artist: "Demuja",
            album: "Dark Dune",
            uri: "x-sonos-http:100320201234567890.mp4?sid=204&sn=2",
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK"
        )

        let resource = AppleMusicFavoriteResource.fromBrowseItem(item)

        XCTAssertEqual(resource, AppleMusicFavoriteResource(id: "1234567890", type: .songs))
    }

    func testAlbumArtistAndPlaylistResourcesStripSonosObjectNamespaces() {
        XCTAssertEqual(
            AppleMusicFavoriteResource.fromBrowseItem(
                BrowseItem(
                    id: "album:1440857781",
                    title: "Kind of Blue",
                    artist: "Miles Davis",
                    album: "Kind of Blue",
                    isContainer: true,
                    cloudType: "ALBUM"
                )
            ),
            AppleMusicFavoriteResource(id: "1440857781", type: .albums)
        )

        XCTAssertEqual(
            AppleMusicFavoriteResource.fromBrowseItem(
                BrowseItem(
                    id: "10052064artist%3A907",
                    title: "Miles Davis",
                    artist: "",
                    album: "",
                    isContainer: true,
                    cloudType: "ARTIST"
                )
            ),
            AppleMusicFavoriteResource(id: "907", type: .artists)
        )

        XCTAssertEqual(
            AppleMusicFavoriteResource.fromBrowseItem(
                BrowseItem(
                    id: "playlist:pl.u-11zBXe4t8ZL1",
                    title: "Late Night Jazz",
                    artist: "Apple Music Jazz",
                    album: "",
                    isContainer: true,
                    cloudType: "PLAYLIST"
                )
            ),
            AppleMusicFavoriteResource(id: "pl.u-11zBXe4t8ZL1", type: .playlists)
        )
    }

    func testUnsupportedResourcesDoNotProduceAppleMusicFavoriteResource() {
        XCTAssertNil(
            AppleMusicFavoriteResource.fromBrowseItem(
                BrowseItem(
                    id: "radio:ra.123",
                    title: "Artist Station",
                    artist: "",
                    album: "",
                    isContainer: false,
                    cloudType: "PROGRAM"
                )
            )
        )
        XCTAssertNil(
            AppleMusicFavoriteResource.fromBrowseItem(
                BrowseItem(
                    id: "libraryfolder:abc",
                    title: "Folder",
                    artist: "",
                    album: "",
                    isContainer: true,
                    cloudType: "COLLECTION"
                )
            )
        )
    }

    func testAddFavoritesRequestBodyEncodesAppleMusicResourceArray() throws {
        let body = try AppleMusicFavoriteRequestBody(resource:
            AppleMusicFavoriteResource(id: "1234567890", type: .songs)
        ).jsonData()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual(data.first?["id"] as? String, "1234567890")
        XCTAssertEqual(data.first?["type"] as? String, "songs")
    }

    func testAddFavoritesRequestUsesPostJSONToFavoritesEndpoint() throws {
        let resource = AppleMusicFavoriteResource(id: "1234567890", type: .songs)

        let request = try AppleMusicFavoritesClient.addFavoritesRequest(for: resource)

        XCTAssertEqual(request.url, AppleMusicFavoritesClient.favoritesURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertEqual(data.first?["id"] as? String, "1234567890")
        XCTAssertEqual(data.first?["type"] as? String, "songs")
    }

    func testRemoveFavoritesRequestUsesDeleteJSONToFavoritesEndpoint() throws {
        let resource = AppleMusicFavoriteResource(id: "pl.u-11zBXe4t8ZL1", type: .playlists)

        let request = try AppleMusicFavoritesClient.removeFavoritesRequest(for: resource)

        XCTAssertEqual(request.url, AppleMusicFavoritesClient.favoritesURL)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertEqual(data.first?["id"] as? String, "pl.u-11zBXe4t8ZL1")
        XCTAssertEqual(data.first?["type"] as? String, "playlists")
    }

    func testCatalogURLUsesStorefrontResourceTypeAndID() {
        let resource = AppleMusicFavoriteResource(id: "1234567890", type: .songs)

        let url = AppleMusicFavoritesClient.catalogURL(
            storefront: "us",
            resource: resource
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://api.music.apple.com/v1/catalog/us/songs/1234567890"
        )
    }
}
