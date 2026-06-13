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

    func testMatcherPrefersExactSongTitleAndArtist() {
        let wrongArtist = AppleMusicCatalogSearchItem(
            id: "111",
            type: .song,
            title: "Comfortable",
            artist: "Another Artist",
            album: "Other",
            artworkURLString: nil,
            duration: nil
        )
        let exact = AppleMusicCatalogSearchItem(
            id: "222",
            type: .song,
            title: "Comfortable",
            artist: "John Mayer",
            album: "Inside Wants Out",
            artworkURLString: nil,
            duration: nil
        )

        let match = LocalMusicCatalogMatcher.bestItem(
            in: [wrongArtist, exact],
            kind: .song,
            title: "comfortable",
            artist: "john mayer",
            album: nil)

        XCTAssertEqual(match?.id, "222")
    }

    func testMatcherFallsBackToFirstRequestedKind() {
        let album = AppleMusicCatalogSearchItem(
            id: "album-1",
            type: .album,
            title: "Comfortable",
            artist: "John Mayer",
            album: "Comfortable",
            artworkURLString: nil,
            duration: nil
        )
        let song = AppleMusicCatalogSearchItem(
            id: "song-1",
            type: .song,
            title: "Comfortable - Live",
            artist: "John Mayer",
            album: "Any Given Thursday",
            artworkURLString: nil,
            duration: nil
        )

        let match = LocalMusicCatalogMatcher.bestItem(
            in: [album, song],
            kind: .song,
            title: "Comfortable",
            artist: "John Mayer",
            album: nil)

        XCTAssertEqual(match?.id, "song-1")
    }

    func testArtworkFallbackUsesBestMatchedSongArtworkURL() {
        let wrongArtist = AppleMusicCatalogSearchItem(
            id: "wrong",
            type: .song,
            title: "Comfortable",
            artist: "Someone Else",
            album: "Other Album",
            artworkURLString: "https://example.com/wrong.jpg",
            duration: 120)
        let exact = AppleMusicCatalogSearchItem(
            id: "exact",
            type: .song,
            title: "Comfortable",
            artist: "John Mayer",
            album: "Room for Squares",
            artworkURLString: "https://example.com/exact.jpg",
            duration: 120)

        let urlString = LocalMusicCatalogArtworkFallback.artworkURLString(
            in: [wrongArtist, exact],
            kind: .song,
            title: "Comfortable",
            artist: "John Mayer",
            album: "Room for Squares")

        XCTAssertEqual(urlString, "https://example.com/exact.jpg")
    }

    func testArtworkFallbackUsesRequestedCatalogKind() {
        let matchingSong = AppleMusicCatalogSearchItem(
            id: "song",
            type: .song,
            title: "Kind of Blue",
            artist: "Miles Davis",
            album: "Kind of Blue",
            artworkURLString: "https://example.com/song.jpg",
            duration: 120)
        let matchingAlbum = AppleMusicCatalogSearchItem(
            id: "album",
            type: .album,
            title: "Kind of Blue",
            artist: "Miles Davis",
            album: "Kind of Blue",
            artworkURLString: "https://example.com/album.jpg",
            duration: nil)

        let urlString = LocalMusicCatalogArtworkFallback.artworkURLString(
            in: [matchingSong, matchingAlbum],
            kind: .album,
            title: "Kind of Blue",
            artist: "Miles Davis",
            album: "Kind of Blue")

        XCTAssertEqual(urlString, "https://example.com/album.jpg")
    }

    func testArtworkFallbackSupportsArtistAndPlaylistMatches() {
        let artist = AppleMusicCatalogSearchItem(
            id: "artist",
            type: .artist,
            title: "Miles Davis",
            artist: "",
            album: "",
            artworkURLString: "https://example.com/artist.jpg",
            duration: nil)
        let playlist = AppleMusicCatalogSearchItem(
            id: "playlist",
            type: .playlist,
            title: "Jazz Essentials",
            artist: "Apple Music Jazz",
            album: "",
            artworkURLString: "https://example.com/playlist.jpg",
            duration: nil)

        let artistURLString = LocalMusicCatalogArtworkFallback.artworkURLString(
            in: [artist, playlist],
            kind: .artist,
            title: "Miles Davis",
            artist: "Miles Davis",
            album: nil)
        let playlistURLString = LocalMusicCatalogArtworkFallback.artworkURLString(
            in: [artist, playlist],
            kind: .playlist,
            title: "Jazz Essentials",
            artist: "Apple Music Jazz",
            album: nil)

        XCTAssertEqual(artistURLString, "https://example.com/artist.jpg")
        XCTAssertEqual(playlistURLString, "https://example.com/playlist.jpg")
    }

    func testArtworkFallbackRejectsNonLoadableArtworkURLString() {
        let playlist = AppleMusicCatalogSearchItem(
            id: "playlist",
            type: .playlist,
            title: "Spatial Audio",
            artist: "Apple Music",
            album: "",
            artworkURLString: "musicKit://artwork/library/example/400x400?aat=Features%2Fv4%2Fcover.png",
            duration: nil)

        let urlString = LocalMusicCatalogArtworkFallback.artworkURLString(
            in: [playlist],
            kind: .playlist,
            title: "Spatial Audio",
            artist: "Apple Music",
            album: nil)

        XCTAssertNil(urlString)
    }

    func testWebURLFallbackUsesBestMatchedCatalogURL() {
        let wrongArtist = AppleMusicCatalogSearchItem(
            id: "111",
            type: .album,
            title: "Blonde",
            artist: "Another Artist",
            album: "Blonde",
            artworkURLString: nil,
            duration: nil,
            urlString: "https://music.apple.com/us/album/wrong/111")
        let exact = AppleMusicCatalogSearchItem(
            id: "1440864059",
            type: .album,
            title: "Blonde",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: nil,
            duration: nil,
            urlString: "https://music.apple.com/us/album/blonde/1440864059")

        let urlString = LocalMusicCatalogWebURLFallback.urlString(
            in: [wrongArtist, exact],
            kind: .album,
            title: "Blonde",
            artist: "Frank Ocean",
            album: "Blonde")

        XCTAssertEqual(urlString, "https://music.apple.com/us/album/blonde/1440864059")
    }

    func testWebURLFallbackBuildsURLFromMatchedCatalogIDWhenURLMissing() {
        let artist = AppleMusicCatalogSearchItem(
            id: "442122051",
            type: .artist,
            title: "Frank Ocean",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil,
            urlString: nil)

        let urlString = LocalMusicCatalogWebURLFallback.urlString(
            in: [artist],
            kind: .artist,
            title: "Frank Ocean",
            artist: "Frank Ocean",
            album: nil)

        XCTAssertEqual(urlString, "https://music.apple.com/us/artist/frank-ocean/442122051")
    }

    func testWebURLFallbackCanRequireCatalogURLFromMusicKit() {
        let artist = AppleMusicCatalogSearchItem(
            id: "442122051",
            type: .artist,
            title: "Frank Ocean",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil,
            urlString: nil)

        let urlString = LocalMusicCatalogWebURLFallback.urlString(
            in: [artist],
            kind: .artist,
            title: "Frank Ocean",
            artist: "Frank Ocean",
            album: nil,
            allowGeneratedFallback: false)

        XCTAssertNil(urlString)
    }

    func testPlaylistCatalogIDExtractorPrefersAppleMusicURL() {
        let catalogID = LocalMusicCatalogIDExtractor.playlistCatalogID(
            rawID: "p.library-only",
            urlString: "https://music.apple.com/us/playlist/feeling-happy/pl.u-11zBJkBtxxE?l=en")

        XCTAssertEqual(catalogID, "pl.u-11zBJkBtxxE")
    }

    func testPlaylistCatalogIDExtractorAcceptsNamespacedCatalogID() {
        let catalogID = LocalMusicCatalogIDExtractor.playlistCatalogID(
            rawID: "playlist:pl.u-11zBJkBtxxE",
            urlString: nil)

        XCTAssertEqual(catalogID, "pl.u-11zBJkBtxxE")
    }

    func testPlaylistCatalogIDExtractorRejectsLibraryOnlyID() {
        let catalogID = LocalMusicCatalogIDExtractor.playlistCatalogID(
            rawID: "p.library-only",
            urlString: nil)

        XCTAssertNil(catalogID)
    }
}
