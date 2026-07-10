import XCTest
@testable import SonosWidget

final class CloudBrowseItemFactoryTests: XCTestCase {
    private func makeFactory() -> CloudBrowseItemFactory {
        CloudBrowseItemFactory(
            cloudToLocalSid: ["52231": 204],
            appleMusicCloudServiceIds: ["52231"]
        )
    }

    func testTrackItemBuildsAppleMusicPlayableURI() {
        let item = makeFactory().trackItem(
            objectId: "song:1440857781",
            title: "Nikes",
            artist: "Frank Ocean",
            album: "Blonde",
            artURL: nil,
            mimeType: "audio/mp4",
            cloudServiceId: "52231",
            accountId: "2"
        )

        XCTAssertEqual(item.id, "song:1440857781")
        XCTAssertEqual(item.title, "Nikes")
        XCTAssertEqual(item.artist, "Frank Ocean")
        XCTAssertEqual(item.album, "Blonde")
        XCTAssertEqual(item.serviceId, 204)
        XCTAssertEqual(item.cloudType, "TRACK")
        XCTAssertFalse(item.isContainer)
        XCTAssertEqual(
            item.uri,
            "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2"
        )
    }

    func testAppleMusicLibraryTrackWithoutMimeTypeDefaultsToPlayableMP4URI() {
        let item = makeFactory().trackItem(
            objectId: "librarytrack:i.aJGorVIS3GeMrdm",
            title: "Neon",
            artist: "John Mayer",
            album: "Where the Light Is",
            artURL: nil,
            mimeType: nil,
            cloudServiceId: "52231",
            accountId: "2"
        )

        XCTAssertEqual(
            item.uri,
            "x-sonos-http:librarytrack%3ai.aJGorVIS3GeMrdm.mp4?sid=204&flags=8232&sn=2"
        )
    }

    func testPlaylistItemNormalizesArtworkAndKeepsContainerType() {
        let item = makeFactory().playlistItem(
            objectId: "playlist:pl.u-11zBXe4t8ZL1",
            title: "Imagine Dragons Essentials",
            artist: "Apple Music Alternative",
            artURL: "musicKit://artwork/library/ABC/600x600?aat=Features125%2Fv4%2Fad%2F0e%2F48%2Fcover%2Epng&at=playlist&et=collection",
            cloudServiceId: "52231",
            accountId: "2"
        )

        XCTAssertEqual(item.id, "playlist:pl.u-11zBXe4t8ZL1")
        XCTAssertEqual(item.cloudType, "PLAYLIST")
        XCTAssertTrue(item.isContainer)
        XCTAssertEqual(item.serviceId, 204)
        XCTAssertEqual(
            item.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Features125/v4/ad/0e/48/cover.png/400x400bb.jpg"
        )
        XCTAssertEqual(
            item.uri,
            "x-rincon-cpcontainer:1006206cplaylist%3apl.u-11zBXe4t8ZL1?sid=204&flags=8300&sn=2"
        )
    }

    func testAlbumItemStoresThumbnailAndDetailArtworkWhenRequested() {
        let artworkURL = "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/aa/bb/cc/album.jpg/1200x1200bb.jpg"

        let item = makeFactory().albumItem(
            objectId: "album:123",
            title: "Freudian",
            artist: "Daniel Caesar",
            artURL: artworkURL,
            cloudServiceId: "52231",
            accountId: "2",
            preserveArtworkSize: true
        )

        XCTAssertEqual(
            item.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/aa/bb/cc/album.jpg/400x400bb.jpg"
        )
        XCTAssertEqual(item.detailArtworkURL, artworkURL)
        XCTAssertEqual(item.thumbnailArtworkURL, item.albumArtURL)
        XCTAssertEqual(item.preferredDetailArtworkURL, artworkURL)
    }

    func testAlbumItemNormalizesArtworkByDefault() {
        let item = makeFactory().albumItem(
            objectId: "album:123",
            title: "Freudian",
            artist: "Daniel Caesar",
            artURL: "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/aa/bb/cc/album.jpg/1200x1200bb.jpg",
            cloudServiceId: "52231",
            accountId: "2"
        )

        XCTAssertEqual(
            item.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/aa/bb/cc/album.jpg/400x400bb.jpg"
        )
        XCTAssertNil(item.detailArtworkURL)
    }

    func testCloudFavoriteItemInfersTypeAndNormalizesArtwork() throws {
        let favorite = try decodeCloudFavorite(
            """
            {
              "id": "favorite-1",
              "name": "Sunday Queue",
              "description": "Apple Music Pop",
              "imageUrl": "musicKit://artwork/library/ABC/600x600?aat=Features125%2Fv4%2Fad%2F0e%2F48%2Fcover%2Epng&at=playlist&et=collection",
              "service": {
                "name": "Apple Music",
                "id": {
                  "serviceId": "52231",
                  "accountId": "2",
                  "objectId": "playlist:pl.u-11zBXe4t8ZL1"
                }
              },
              "resource": {
                "type": "playlist",
                "name": "Sunday Queue"
              }
            }
            """
        )

        let item = makeFactory().cloudFavoriteItem(from: favorite)

        XCTAssertEqual(item.id, "favorite-1")
        XCTAssertEqual(item.title, "Sunday Queue")
        XCTAssertEqual(item.artist, "Apple Music Pop")
        XCTAssertEqual(item.album, "")
        XCTAssertNil(item.uri)
        XCTAssertNil(item.resMD)
        XCTAssertTrue(item.isContainer)
        XCTAssertEqual(item.serviceId, 204)
        XCTAssertEqual(item.cloudType, "PLAYLIST")
        XCTAssertEqual(item.cloudFavoriteId, "favorite-1")
        XCTAssertEqual(
            item.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Features125/v4/ad/0e/48/cover.png/400x400bb.jpg"
        )
    }

    func testAlbumTrackItemBuildsPlayableTrackItem() throws {
        let track = try decodeAlbumTrackItem(
            """
            {
              "id": "row-1",
              "title": "Nikes",
              "subtitle": "Frank Ocean",
              "images": {
                "tile1x1": "musicKit://artwork/library/ABC/600x600?aat=Features125%2Fv4%2Fad%2F0e%2F48%2Fcover%2Epng&at=playlist&et=collection"
              },
              "type": "TRACK",
              "resource": {
                "type": "TRACK",
                "id": {
                  "objectId": "catalog:track:song:1440857781#frag",
                  "serviceId": "52231",
                  "accountId": "2"
                },
                "defaults": "eyJtaW1lVHlwZSI6ImF1ZGlvL21wNCJ9"
              },
              "artists": [
                {
                  "id": "artist:1",
                  "name": "Frank Ocean"
                }
              ],
              "ordinal": 4,
              "duration": "312"
            }
            """
        )

        let item = makeFactory().albumTrackItem(
            from: track,
            fallbackAlbumTitle: "Blonde",
            fallbackArtist: nil,
            fallbackArtURL: nil,
            fallbackServiceId: nil,
            fallbackAccountId: nil
        )

        XCTAssertEqual(item.id, "track:song:1440857781")
        XCTAssertEqual(item.title, "Nikes")
        XCTAssertEqual(item.artist, "Frank Ocean")
        XCTAssertEqual(item.album, "Blonde")
        XCTAssertEqual(item.duration, 312)
        XCTAssertEqual(item.serviceId, 204)
        XCTAssertEqual(item.cloudType, "TRACK")
        XCTAssertFalse(item.isContainer)
        XCTAssertEqual(
            item.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Features125/v4/ad/0e/48/cover.png/400x400bb.jpg"
        )
        XCTAssertEqual(
            item.uri,
            "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2"
        )
    }

    func testAlbumTrackContainerItemBuildsPlayablePlaylistContainer() throws {
        let playlist = try decodeAlbumTrackItem(
            """
            {
              "id": "row-playlist",
              "title": "Sunday Queue",
              "subtitle": "Apple Music Pop",
              "images": {
                "tile1x1": "musicKit://artwork/library/ABC/600x600?aat=Features125%2Fv4%2Fad%2F0e%2F48%2Fcover%2Epng&at=playlist&et=collection"
              },
              "type": "PLAYLIST",
              "resource": {
                "type": "PLAYLIST",
                "id": {
                  "objectId": "playlist:pl.u-11zBXe4t8ZL1",
                  "serviceId": "52231",
                  "accountId": "2"
                }
              },
              "actions": ["BROWSE"]
            }
            """
        )

        let item = makeFactory().albumTrackContainerItem(from: playlist)

        XCTAssertEqual(item.id, "playlist:pl.u-11zBXe4t8ZL1")
        XCTAssertEqual(item.title, "Sunday Queue")
        XCTAssertEqual(item.artist, "Apple Music Pop")
        XCTAssertEqual(item.album, "")
        XCTAssertEqual(item.serviceId, 204)
        XCTAssertEqual(item.cloudType, "PLAYLIST")
        XCTAssertTrue(item.isContainer)
        XCTAssertEqual(
            item.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Features125/v4/ad/0e/48/cover.png/400x400bb.jpg"
        )
        XCTAssertEqual(
            item.uri,
            "x-rincon-cpcontainer:1006206cplaylist%3apl.u-11zBXe4t8ZL1?sid=204&flags=8300&sn=2"
        )
    }

    private func decodeCloudFavorite(_ json: String) throws -> SonosCloudAPI.CloudFavorite {
        try JSONDecoder().decode(
            SonosCloudAPI.CloudFavorite.self,
            from: Data(json.utf8)
        )
    }

    private func decodeAlbumTrackItem(_ json: String) throws -> SonosCloudAPI.AlbumTrackItem {
        try JSONDecoder().decode(
            SonosCloudAPI.AlbumTrackItem.self,
            from: Data(json.utf8)
        )
    }
}
