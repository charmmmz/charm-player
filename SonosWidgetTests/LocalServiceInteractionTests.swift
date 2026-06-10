import XCTest
@testable import SonosWidget

final class LocalServiceInteractionTests: XCTestCase {
    func testAlbumDetailActionsExposePlayShuffleAndAppleMusicLink() {
        XCTAssertEqual(
            LocalMusicDetailActions.album(hasAppleMusicURL: true),
            [.play, .shuffle, .openAppleMusic])
    }

    func testAlbumDetailActionsOmitAppleMusicLinkWhenUnavailable() {
        XCTAssertEqual(
            LocalMusicDetailActions.album(hasAppleMusicURL: false),
            [.play, .shuffle])
    }

    func testArtistDetailActionsExposeStationAndAppleMusicLink() {
        XCTAssertEqual(
            LocalMusicDetailActions.artist(hasAppleMusicURL: true),
            [.playStation, .openAppleMusic])
    }

    func testArtistDetailActionsOmitAppleMusicLinkWhenUnavailable() {
        XCTAssertEqual(
            LocalMusicDetailActions.artist(hasAppleMusicURL: false),
            [.playStation])
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
}
