import XCTest
@testable import SonosWidget

final class LocalServiceAppleMusicPlayableTests: XCTestCase {
    func testSongPrefersCatalogCandidateOverRawLibraryID() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .song,
            rawID: "i.local-library-song",
            playParameterCandidates: ["song:1440857781"],
            title: "Nikes",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: nil,
            duration: 312
        )

        XCTAssertEqual(playable?.catalogID, "song:1440857781")
        XCTAssertEqual(playable?.sonosObjectID, "song:1440857781")
        XCTAssertEqual(playable?.cloudType, "TRACK")
        XCTAssertFalse(playable?.isContainer ?? true)
    }

    func testAlbumNormalizesNamespacedCatalogCandidate() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .album,
            rawID: "library-album-id",
            playParameterCandidates: ["catalog:albums:1440864059"],
            title: "Blonde",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: "https://example.com/cover.jpg",
            duration: nil
        )

        XCTAssertEqual(playable?.catalogID, "album:1440864059")
        XCTAssertEqual(playable?.sonosObjectID, "album:1440864059")
        XCTAssertEqual(playable?.cloudType, "ALBUM")
        XCTAssertTrue(playable?.isContainer ?? false)
    }

    func testPlaylistKeepsCatalogPlaylistID() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .playlist,
            rawID: "library-playlist-id",
            playParameterCandidates: ["pl.abc123"],
            title: "Sunday",
            artist: "Apple Music",
            album: "",
            artworkURLString: nil,
            duration: nil
        )

        XCTAssertEqual(playable?.catalogID, "playlist:pl.abc123")
        XCTAssertEqual(playable?.sonosObjectID, "playlist:pl.abc123")
        XCTAssertEqual(playable?.cloudType, "PLAYLIST")
        XCTAssertTrue(playable?.isContainer ?? false)
    }

    func testRejectsLibraryOnlySongID() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .song,
            rawID: "i.local-library-song",
            playParameterCandidates: [],
            title: "Local File",
            artist: "Unknown",
            album: "",
            artworkURLString: nil,
            duration: nil
        )

        XCTAssertNil(playable)
    }

    func testNumericSongCandidateIsNamespacedForSonos() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .song,
            rawID: "i.local-library-song",
            playParameterCandidates: ["16704742"],
            title: "No Such Thing",
            artist: "John Mayer",
            album: "Room for Squares",
            artworkURLString: nil,
            duration: 231
        )

        XCTAssertEqual(playable?.catalogID, "song:16704742")
        XCTAssertEqual(playable?.sonosObjectID, "song:16704742")
    }

    func testCatalogSearchItemConvertsToPlayable() {
        let item = AppleMusicCatalogSearchItem(
            id: "1440857781",
            type: .song,
            title: "Nikes",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: "https://example.com/cover.jpg",
            duration: 312
        )

        let playable = LocalServiceAppleMusicPlayable.make(catalogItem: item)

        XCTAssertEqual(playable?.kind, .song)
        XCTAssertEqual(playable?.catalogID, "song:1440857781")
        XCTAssertEqual(playable?.title, "Nikes")
        XCTAssertEqual(playable?.artist, "Frank Ocean")
        XCTAssertEqual(playable?.album, "Blonde")
        XCTAssertEqual(playable?.artworkURLString, "https://example.com/cover.jpg")
        XCTAssertEqual(playable?.duration, 312)
    }

    func testPlayableNormalizesMusicKitArtworkURLForBrowseRecentlyPlayed() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .album,
            rawID: "1440864059",
            playParameterCandidates: ["album:1440864059"],
            title: "Blonde",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: "musicKit://artwork/library/ABC/600x600?aat=https%3A%2F%2Fis1-ssl.mzstatic.com%2Fimage%2Fthumb%2FMusic125%2Fv4%2Fcover%2F600x600bb.jpg&at=item&id=1440864059",
            duration: nil
        )

        XCTAssertEqual(
            playable?.artworkURLString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/cover/400x400bb.jpg"
        )
    }

    func testStationNormalizesAppleMusicShareURL() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .station,
            rawID: "library-station-id",
            playParameterCandidates: [
                "https://music.apple.com/us/station/apple-music-chill/ra.1740614260"
            ],
            title: "Apple Music Chill",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil
        )

        XCTAssertEqual(playable?.catalogID, "radio:ra.1740614260")
        XCTAssertEqual(playable?.sonosObjectID, "radio:ra.1740614260")
        XCTAssertEqual(playable?.cloudType, "PROGRAM")
    }

    func testStationNormalizesBareStationID() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .station,
            rawID: "library-station-id",
            playParameterCandidates: ["1740614260"],
            title: "Apple Music Chill",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil
        )

        XCTAssertEqual(playable?.catalogID, "radio:ra.1740614260")
    }

    func testStationNormalizesStationNamespace() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .station,
            rawID: "library-station-id",
            playParameterCandidates: ["station:ra.1740614260"],
            title: "Apple Music Chill",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil
        )

        XCTAssertEqual(playable?.catalogID, "radio:ra.1740614260")
    }

    func testLiveStationCapturesStreamPlaybackToken() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .station,
            rawID: "ra.1740614260",
            playParameterCandidates: [
                "ra.1740614260",
                "stream",
                "radioStation",
                "CgkIBRoF9NT-vQYQBA"
            ],
            title: "Apple Music Chill",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil
        )

        XCTAssertEqual(playable?.catalogID, "radio:ra.1740614260")
        XCTAssertEqual(playable?.stationPlaybackKind, .stream)
        XCTAssertEqual(playable?.stationStreamObjectID, "CgkIBRoF9NT-vQYQBA")
    }

    func testPersonalStationDoesNotUseStreamPlaybackToken() {
        let playable = LocalServiceAppleMusicPlayable.make(
            kind: .station,
            rawID: "ra.u-846cd3c366cfc3081abb70ff757aa95f",
            playParameterCandidates: [
                "ra.u-846cd3c366cfc3081abb70ff757aa95f",
                "tracks",
                "radioStation",
                "CgoIByIGCJnI8_5AEAE"
            ],
            title: "Charm's Station",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil
        )

        XCTAssertEqual(playable?.catalogID, "radio:ra.u-846cd3c366cfc3081abb70ff757aa95f")
        XCTAssertEqual(playable?.stationPlaybackKind, .tracks)
        XCTAssertNil(playable?.stationStreamObjectID)
    }

    func testPlayableUsesFallbackArtworkURLWhenOriginalArtworkIsMissing() throws {
        let playable = try XCTUnwrap(LocalServiceAppleMusicPlayable.make(
            kind: .playlist,
            rawID: "library-playlist-id",
            playParameterCandidates: ["pl.abc123"],
            title: "Sunday",
            artist: "Charm",
            album: "",
            artworkURLString: nil,
            duration: nil
        ))

        let updated = playable.withFallbackArtworkURLString(" https://example.com/playlist.jpg ")

        XCTAssertEqual(updated.artworkURLString, "https://example.com/playlist.jpg")
        XCTAssertEqual(updated.kind, playable.kind)
        XCTAssertEqual(updated.catalogID, playable.catalogID)
    }

    func testPlayableKeepsExistingArtworkURLOverFallbackArtworkURL() throws {
        let playable = try XCTUnwrap(LocalServiceAppleMusicPlayable.make(
            kind: .playlist,
            rawID: "library-playlist-id",
            playParameterCandidates: ["pl.abc123"],
            title: "Sunday",
            artist: "Charm",
            album: "",
            artworkURLString: "https://example.com/original.jpg",
            duration: nil
        ))

        let updated = playable.withFallbackArtworkURLString("https://example.com/fallback.jpg")

        XCTAssertEqual(updated.artworkURLString, "https://example.com/original.jpg")
    }
}
