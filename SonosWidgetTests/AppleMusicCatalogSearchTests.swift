import XCTest
@testable import SonosWidget

final class AppleMusicCatalogSearchTests: XCTestCase {
    func testCatalogItemTypesMapToSonosCloudTypes() {
        XCTAssertEqual(AppleMusicCatalogItemType.song.cloudType, "TRACK")
        XCTAssertEqual(AppleMusicCatalogItemType.album.cloudType, "ALBUM")
        XCTAssertEqual(AppleMusicCatalogItemType.artist.cloudType, "ARTIST")
        XCTAssertEqual(AppleMusicCatalogItemType.playlist.cloudType, "PLAYLIST")
    }

    func testCatalogItemContainerFlagsMatchSearchManagerFactories() {
        XCTAssertFalse(AppleMusicCatalogItemType.song.isContainer)
        XCTAssertTrue(AppleMusicCatalogItemType.album.isContainer)
        XCTAssertFalse(AppleMusicCatalogItemType.artist.isContainer)
        XCTAssertTrue(AppleMusicCatalogItemType.playlist.isContainer)
    }

    func testSearchItemMapsToBrowseItemShape() {
        let item = AppleMusicCatalogSearchItem(
            id: "1440857781",
            type: .album,
            title: "Kind of Blue",
            artist: "Miles Davis",
            album: "Kind of Blue",
            artworkURLString: "https://example.com/cover.jpg",
            duration: nil
        )

        let browseItem = item.browseItem(localServiceId: 204)

        XCTAssertEqual(browseItem.id, "album:1440857781")
        XCTAssertEqual(browseItem.title, "Kind of Blue")
        XCTAssertEqual(browseItem.artist, "Miles Davis")
        XCTAssertEqual(browseItem.album, "Kind of Blue")
        XCTAssertEqual(browseItem.albumArtURL, "https://example.com/cover.jpg")
        XCTAssertTrue(browseItem.isContainer)
        XCTAssertEqual(browseItem.serviceId, 204)
        XCTAssertEqual(browseItem.cloudType, "ALBUM")
    }

    func testSearchItemKeepsTrackDurationAndAlbum() {
        let item = AppleMusicCatalogSearchItem(
            id: "1234567890",
            type: .song,
            title: "Dark Dune",
            artist: "Demuja",
            album: "Dark Dune - Single",
            artworkURLString: nil,
            duration: 245
        )

        let browseItem = item.browseItem(localServiceId: nil)

        XCTAssertEqual(browseItem.album, "Dark Dune - Single")
        XCTAssertEqual(browseItem.duration, 245)
        XCTAssertFalse(browseItem.isContainer)
        XCTAssertNil(browseItem.serviceId)
        XCTAssertEqual(browseItem.cloudType, "TRACK")
        XCTAssertEqual(browseItem.id, "song:1234567890")
    }

    func testSongSearchItemProvidesSonosPlayableObjectID() {
        let item = AppleMusicCatalogSearchItem(
            id: "1234567890",
            type: .song,
            title: "Dark Dune",
            artist: "Demuja",
            album: "Dark Dune - Single",
            artworkURLString: nil,
            duration: 245
        )

        XCTAssertEqual(item.sonosPlayableObjectID, "song:1234567890")
        XCTAssertEqual(item.sonosPlayableMimeType, "audio/mp4")
    }

    func testContainerSearchItemsUseNamespacedSonosObjectID() {
        let item = AppleMusicCatalogSearchItem(
            id: "1440857781",
            type: .album,
            title: "Kind of Blue",
            artist: "Miles Davis",
            album: "Kind of Blue",
            artworkURLString: nil,
            duration: nil
        )

        XCTAssertEqual(item.sonosPlayableObjectID, "album:1440857781")
        XCTAssertNil(item.sonosPlayableMimeType)
    }
}
