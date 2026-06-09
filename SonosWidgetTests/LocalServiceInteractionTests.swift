import XCTest
@testable import SonosWidget

final class LocalServiceInteractionTests: XCTestCase {
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
