import XCTest
@testable import SonosWidget

final class PlaylistDetailPresentationTests: XCTestCase {
    func testTrackListKeepsReportedTotalSlotsWhilePagesAreLoading() {
        XCTAssertEqual(
            PlaylistDetailTrackListPresentation.displayedSlotCount(
                loadedTrackCount: 100,
                reportedTotal: 1_000,
                allPagesLoaded: false
            ),
            1_000
        )
    }

    func testTrackListFallsBackToLoadedCountWhenNoTotalIsReported() {
        XCTAssertEqual(
            PlaylistDetailTrackListPresentation.displayedSlotCount(
                loadedTrackCount: 100,
                reportedTotal: nil,
                allPagesLoaded: false
            ),
            100
        )
    }

    func testTrackListShowsLoadedRowsBeforePlaceholders() {
        XCTAssertEqual(
            PlaylistDetailTrackListPresentation.slotKind(at: 99, loadedTrackCount: 100),
            .loaded(trackIndex: 99)
        )
        XCTAssertEqual(
            PlaylistDetailTrackListPresentation.slotKind(at: 100, loadedTrackCount: 100),
            .placeholder(rowNumber: 101)
        )
    }
}
