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

    func testLibraryPartialAlbumActionUsesDisplayedTracks() {
        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(
                currentAlbumID: "l.partial-album",
                currentTrackCount: 2,
                completeAlbumID: "1440864059",
                completeTrackCount: 17)
        )
    }

    func testCatalogAlbumActionUsesAlbumContainerWhenTracksAreLoaded() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(
                currentAlbumID: "1839352404",
                currentTrackCount: 12,
                completeAlbumID: "1839352404",
                completeTrackCount: 12)
        )
    }

    func testLibraryCompleteAlbumActionUsesAlbumContainer() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(
                currentAlbumID: "l.complete-album",
                currentTrackCount: 10,
                completeAlbumID: "1440864059",
                completeTrackCount: 10)
        )
    }
}
