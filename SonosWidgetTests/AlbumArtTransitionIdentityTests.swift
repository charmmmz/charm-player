import XCTest
@testable import SonosWidget

final class AlbumArtTransitionIdentityTests: XCTestCase {
    func testVisibleArtworkIdentityIgnoresURLChanges() {
        let firstTrack = TrackInfo(
            title: "Dream On",
            artist: "Aerosmith",
            album: "Aerosmith",
            albumArtURL: "https://example.com/artwork-a.jpg",
            trackURI: "x-sonos-http:track-1"
        )
        let secondTrack = TrackInfo(
            title: "Dream On",
            artist: "Aerosmith",
            album: "Aerosmith",
            albumArtURL: "https://cdn.example.com/artwork-a.jpg?size=1200",
            trackURI: "x-sonos-http:track-1"
        )

        let first = AlbumArtTransitionIdentity.id(
            trackIdentity: AlbumArtTrackIdentity.make(from: firstTrack),
            hasDisplayedArtwork: true
        )
        let second = AlbumArtTransitionIdentity.id(
            trackIdentity: AlbumArtTrackIdentity.make(from: secondTrack),
            hasDisplayedArtwork: true
        )

        XCTAssertEqual(first, second)
    }

    func testVisibleArtworkIdentityChangesForDifferentTracks() {
        let first = AlbumArtTransitionIdentity.id(
            trackIdentity: "uri:track-1",
            hasDisplayedArtwork: true
        )
        let second = AlbumArtTransitionIdentity.id(
            trackIdentity: "uri:track-2",
            hasDisplayedArtwork: true
        )

        XCTAssertNotEqual(first, second)
    }

    func testIdentityChangesOnlyWhenArtworkAppearsOrDisappears() {
        let placeholder = AlbumArtTransitionIdentity.id(
            trackIdentity: "uri:track-1",
            hasDisplayedArtwork: false
        )
        let visibleArtwork = AlbumArtTransitionIdentity.id(
            trackIdentity: "uri:track-1",
            hasDisplayedArtwork: true
        )

        XCTAssertNotEqual(placeholder, visibleArtwork)
    }

    func testDisplayedArtworkIdentityWinsWhileCurrentTrackHasAlreadyChanged() {
        let id = AlbumArtTransitionIdentity.id(
            displayedTrackIdentity: "uri:track-1",
            currentTrackIdentity: "uri:track-2",
            hasDisplayedArtwork: true
        )

        XCTAssertEqual(
            id,
            AlbumArtTransitionIdentity.id(
                trackIdentity: "uri:track-1",
                hasDisplayedArtwork: true
            )
        )
    }

    func testMusicPlaceholderIconIsHiddenWhileArtworkIsDisplayed() {
        XCTAssertNil(
            AlbumArtPlaceholderIcon.systemName(
                source: .appleMusic,
                hasDisplayedArtwork: true
            )
        )
    }

    func testMusicPlaceholderIconShowsWhenNoArtworkIsDisplayed() {
        XCTAssertEqual(
            AlbumArtPlaceholderIcon.systemName(
                source: .appleMusic,
                hasDisplayedArtwork: false
            ),
            "music.note"
        )
    }

    func testTVPlaceholderIconStillShowsWhenArtworkSlotIsEmpty() {
        XCTAssertEqual(
            AlbumArtPlaceholderIcon.systemName(
                source: .tv,
                hasDisplayedArtwork: false
            ),
            "tv"
        )
    }

    func testRefreshPolicyPreservesVisibleArtworkForSameTrackIdentity() {
        XCTAssertTrue(
            AlbumArtRefreshPolicy.shouldPreserveDisplayedArtwork(
                hasDisplayedArtwork: true,
                displayedTrackIdentity: "uri:track-1",
                incomingTrackIdentity: "uri:track-1"
            )
        )
    }

    func testRefreshPolicyDoesNotPreserveVisibleArtworkForDifferentTrackIdentity() {
        XCTAssertFalse(
            AlbumArtRefreshPolicy.shouldPreserveDisplayedArtwork(
                hasDisplayedArtwork: true,
                displayedTrackIdentity: "uri:track-1",
                incomingTrackIdentity: "uri:track-2"
            )
        )
    }
}
