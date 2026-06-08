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
}
