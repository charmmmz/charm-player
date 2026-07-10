import XCTest
@testable import SonosWidget

final class AppleMusicExternalLinkResolverTests: XCTestCase {
    func testCurrentTrackResourcePrefersNowPlayingObjectID() {
        let resource = AppleMusicExternalLinkResolver.currentTrackResource(
            trackURI: "x-sonos-http:100320209999999999.mp4?sid=204&flags=8224&sn=2",
            nowPlayingObjectID: "song:1440857781"
        )

        XCTAssertEqual(resource, AppleMusicFavoriteResource(id: "1440857781", type: .songs))
    }

    func testCurrentTrackResourceFallsBackToTrackURIStoreID() {
        let resource = AppleMusicExternalLinkResolver.currentTrackResource(
            trackURI: "x-sonos-http:100320201440857781.mp4?sid=204&flags=8224&sn=2",
            nowPlayingObjectID: nil
        )

        XCTAssertEqual(resource, AppleMusicFavoriteResource(id: "1440857781", type: .songs))
    }

    func testArtworkTapPolicyRejectsDragTranslations() {
        XCTAssertTrue(
            AppleMusicArtworkTapPolicy.shouldOpen(
                translation: CGSize(width: 0, height: 0)
            )
        )
        XCTAssertTrue(
            AppleMusicArtworkTapPolicy.shouldOpen(
                translation: CGSize(width: 4, height: 4)
            )
        )
        XCTAssertFalse(
            AppleMusicArtworkTapPolicy.shouldOpen(
                translation: CGSize(width: 0, height: 9)
            )
        )
        XCTAssertFalse(
            AppleMusicArtworkTapPolicy.shouldOpen(
                translation: CGSize(width: 7, height: 7)
            )
        )
    }

    func testDetailArtworkResourceAcceptsAppleMusicAlbumArtistAndPlaylist() {
        let searchManager = SearchManager()

        XCTAssertEqual(
            AppleMusicDetailArtworkLink.resource(
                from: BrowseItem(
                    id: "album:1440864059",
                    title: "Abbey Road",
                    artist: "The Beatles",
                    album: "Abbey Road",
                    uri: "x-rincon-cpcontainer:1004206calbum%3A1440864059?sid=204&flags=8300&sn=2",
                    isContainer: true,
                    serviceId: 204,
                    cloudType: "ALBUM"
                ),
                searchManager: searchManager,
                allowedTypes: [.albums]
            ),
            AppleMusicFavoriteResource(id: "1440864059", type: .albums)
        )

        XCTAssertEqual(
            AppleMusicDetailArtworkLink.resource(
                from: BrowseItem(
                    id: "10052064artist%3A909253",
                    title: "The Beatles",
                    artist: "",
                    album: "",
                    uri: "x-rincon-cpcontainer:artist%3A909253?sid=204&flags=8300&sn=2",
                    isContainer: false,
                    serviceId: 204,
                    cloudType: "ARTIST"
                ),
                searchManager: searchManager,
                allowedTypes: [.artists]
            ),
            AppleMusicFavoriteResource(id: "909253", type: .artists)
        )

        XCTAssertEqual(
            AppleMusicDetailArtworkLink.resource(
                from: BrowseItem(
                    id: "playlist:pl.u-11zBXe4t8ZL1",
                    title: "Late Night Jazz",
                    artist: "Apple Music Jazz",
                    album: "",
                    uri: "x-rincon-cpcontainer:1006206cplaylist%3Apl.u-11zBXe4t8ZL1?sid=204&flags=8300&sn=2",
                    isContainer: true,
                    serviceId: 204,
                    cloudType: "PLAYLIST"
                ),
                searchManager: searchManager,
                allowedTypes: [.playlists]
            ),
            AppleMusicFavoriteResource(id: "pl.u-11zBXe4t8ZL1", type: .playlists)
        )
    }

    func testDetailArtworkResourceRejectsNonAppleMusicAndMismatchedTypes() {
        let searchManager = SearchManager()
        let spotifyAlbum = BrowseItem(
            id: "album:spotify-album",
            title: "Other Album",
            artist: "Other Artist",
            album: "Other Album",
            uri: "x-sonos-spotify:spotify%3Aalbum%3Aabc?sid=9&flags=8300&sn=1",
            isContainer: true,
            serviceId: 9,
            cloudType: "ALBUM"
        )
        let appleMusicPlaylist = BrowseItem(
            id: "playlist:pl.u-11zBXe4t8ZL1",
            title: "Late Night Jazz",
            artist: "Apple Music Jazz",
            album: "",
            uri: "x-rincon-cpcontainer:1006206cplaylist%3Apl.u-11zBXe4t8ZL1?sid=204&flags=8300&sn=2",
            isContainer: true,
            serviceId: 204,
            cloudType: "PLAYLIST"
        )

        XCTAssertNil(
            AppleMusicDetailArtworkLink.resource(
                from: spotifyAlbum,
                searchManager: searchManager,
                allowedTypes: [.albums]
            )
        )
        XCTAssertNil(
            AppleMusicDetailArtworkLink.resource(
                from: appleMusicPlaylist,
                searchManager: searchManager,
                allowedTypes: [.albums]
            )
        )
    }
}
