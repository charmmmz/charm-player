import XCTest
@testable import SonosWidget

final class LocalMusicTrackNumberLabelTests: XCTestCase {
    func testAlbumRowsPreferAlbumTrackNumber() {
        XCTAssertEqual(
            LocalMusicTrackNumberLabel.text(
                trackNumber: 9,
                index: 2,
                style: .albumTrackNumber),
            "9")
    }

    func testPlaylistRowsUseListPositionInsteadOfAlbumTrackNumber() {
        XCTAssertEqual(
            LocalMusicTrackNumberLabel.text(
                trackNumber: 9,
                index: 2,
                style: .listPosition),
            "3")
    }

    func testAlbumRowsFallBackToListPositionWhenTrackNumberIsMissing() {
        XCTAssertEqual(
            LocalMusicTrackNumberLabel.text(
                trackNumber: nil,
                index: 2,
                style: .albumTrackNumber),
            "3")
    }
}
