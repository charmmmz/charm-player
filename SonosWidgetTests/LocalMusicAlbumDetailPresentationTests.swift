import XCTest
@testable import SonosWidget

final class LocalMusicAlbumDetailPresentationTests: XCTestCase {
    func testShowsCompleteAlbumButtonOnlyWhenCatalogAlbumHasMoreTracks() {
        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.shouldShowCompleteAlbumButton(
                currentAlbumID: "l.partial-album",
                currentTrackCount: 2,
                completeAlbumID: "1440864059",
                completeTrackCount: 17)
        )
    }

    func testOmitsCompleteAlbumButtonWhenCatalogAlbumIsNotMoreComplete() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldShowCompleteAlbumButton(
                currentAlbumID: "l.complete-album",
                currentTrackCount: 10,
                completeAlbumID: "1440864059",
                completeTrackCount: 10)
        )
    }

    func testOmitsCompleteAlbumButtonForSameAlbumID() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldShowCompleteAlbumButton(
                currentAlbumID: "1440864059",
                currentTrackCount: 10,
                completeAlbumID: "1440864059",
                completeTrackCount: 17)
        )
    }

    func testPlaybackUsesCurrentPageAlbumEvenWhenCompleteAlbumExists() {
        XCTAssertEqual(
            LocalMusicAlbumDetailPresentation.playbackAlbumID(
                currentAlbumID: "l.partial-album",
                completeAlbumID: "1440864059"),
            "l.partial-album"
        )
    }

    func testAlbumActionUsesDisplayedTracksWhenTracksAreLoaded() {
        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(trackCount: 2)
        )
    }

    func testAlbumActionFallsBackToAlbumContainerWhenNoTracksAreLoaded() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(trackCount: 0)
        )
    }
}
