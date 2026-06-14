import XCTest
@testable import SonosWidget

final class LocalServiceInteractionTests: XCTestCase {
    func testAlbumDetailActionsKeepAppleMusicLinkOnArtwork() {
        XCTAssertEqual(
            LocalMusicDetailActions.album(hasAppleMusicURL: true),
            [.play, .shuffle])
    }

    func testAlbumDetailActionsOmitAppleMusicLinkWhenUnavailable() {
        XCTAssertEqual(
            LocalMusicDetailActions.album(hasAppleMusicURL: false),
            [.play, .shuffle])
    }

    func testArtistDetailActionsKeepAppleMusicLinkOnArtwork() {
        XCTAssertEqual(
            LocalMusicDetailActions.artist(hasAppleMusicURL: true),
            [.playStation])
    }

    func testArtistDetailActionsOmitAppleMusicLinkWhenUnavailable() {
        XCTAssertEqual(
            LocalMusicDetailActions.artist(hasAppleMusicURL: false),
            [.playStation])
    }

    func testPlaylistDetailActionsKeepAppleMusicLinkOnArtwork() {
        XCTAssertEqual(
            LocalMusicDetailActions.playlist(hasAppleMusicURL: true),
            [.play, .shuffle])
    }

    func testAppleMusicURLFallsBackToAlbumCatalogID() {
        let playable = LocalServiceAppleMusicPlayable(
            kind: .album,
            catalogID: "album:1440864059",
            title: "Blonde",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: nil,
            duration: nil)

        XCTAssertEqual(
            LocalMusicAppleMusicURL.url(
                existingURL: nil,
                playable: playable,
                kind: .album)?.absoluteString,
            "https://music.apple.com/us/album/blonde/1440864059")
    }

    func testAppleMusicURLRejectsLibraryAlbumIDFallback() {
        let playable = LocalServiceAppleMusicPlayable(
            kind: .album,
            catalogID: "album:l.library-album-id",
            title: "Blonde",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: nil,
            duration: nil)

        XCTAssertNil(
            LocalMusicAppleMusicURL.url(
                existingURL: nil,
                playable: playable,
                kind: .album))
    }

    func testAppleMusicURLRejectsLibraryArtistIDFallback() {
        let playable = LocalServiceAppleMusicPlayable(
            kind: .artist,
            catalogID: "artist:r.library-artist-id",
            title: "Frank Ocean",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil)

        XCTAssertNil(
            LocalMusicAppleMusicURL.url(
                existingURL: nil,
                playable: playable,
                kind: .artist))
    }

    func testAppleMusicURLPrefersExistingURL() {
        let existingURL = URL(string: "https://music.apple.com/us/album/existing/1")!

        XCTAssertEqual(
            LocalMusicAppleMusicURL.url(
                existingURL: existingURL,
                playable: nil,
                kind: .album),
            existingURL)
    }

    func testAppleMusicURLIgnoresUnsupportedExistingURL() {
        let existingURL = URL(string: "https://music.apple.com/us/library/albums/l.library-album-id")!

        XCTAssertNil(
            LocalMusicAppleMusicURL.url(
                existingURL: existingURL,
                playable: nil,
                kind: .album))
    }

    func testExternalAppleMusicURLCanRequireCatalogURL() {
        let existingURL = URL(string: "https://music.apple.com/us/album/existing/1")!
        let catalogURL = URL(string: "https://music.apple.com/us/album/catalog/2")!

        XCTAssertNil(
            LocalMusicAppleMusicURL.externalURL(
                existingURL: existingURL,
                catalogURL: nil,
                kind: .album,
                requiresCatalogURL: true))
        XCTAssertEqual(
            LocalMusicAppleMusicURL.externalURL(
                existingURL: existingURL,
                catalogURL: catalogURL,
                kind: .album,
                requiresCatalogURL: true),
            catalogURL)
    }

    func testArtistPrimaryActionNavigatesToDetails() {
        XCTAssertEqual(
            LocalServiceLibraryInteraction.primaryAction(for: .artist),
            .navigate)
    }

    func testSongAndStationPrimaryActionsStillPlay() {
        XCTAssertEqual(
            LocalServiceLibraryInteraction.primaryAction(for: .song),
            .play)
        XCTAssertEqual(
            LocalServiceLibraryInteraction.primaryAction(for: .station),
            .play)
    }

    func testMusicResourceActionPolicyExposesQueueActionsForQueueableSongs() {
        XCTAssertEqual(
            MusicResourceActionPolicy.actions(kind: .song, isQueueable: true),
            [.playNow, .playNext, .addToQueue]
        )
    }

    func testMusicResourceActionPolicyKeepsArtistsStationFocused() {
        XCTAssertEqual(
            MusicResourceActionPolicy.actions(kind: .artist, isQueueable: true, supportsStation: true),
            [.startStation]
        )
    }

    func testMusicResourceActionPolicyOmitsQueueActionsWhenItemCannotResolve() {
        XCTAssertEqual(
            MusicResourceActionPolicy.actions(kind: .playlist, isQueueable: false),
            [.playNow]
        )
    }

    func testPlaylistTrackArtworkSelectionPrefersTrackArtwork() {
        let trackURL = URL(string: "https://example.com/track.jpg")!
        let playlistURL = URL(string: "https://example.com/playlist.jpg")!

        XCTAssertEqual(
            MusicResourceArtworkSelection.preferredRowArtworkURL(primary: trackURL, fallback: playlistURL),
            trackURL
        )
    }

    func testPlaylistTrackArtworkSelectionFallsBackToPlaylistArtwork() {
        let playlistURL = URL(string: "https://example.com/playlist.jpg")!

        XCTAssertEqual(
            MusicResourceArtworkSelection.preferredRowArtworkURL(primary: nil, fallback: playlistURL),
            playlistURL
        )
    }
}
