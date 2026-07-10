import XCTest
@testable import SonosWidget

final class SonosAlbumBrowseIDTests: XCTestCase {
    func testUsesExistingAlbumObjectIDForBrowse() {
        XCTAssertEqual(SonosAlbumBrowseID.from("album:1440864059"), "album:1440864059")
    }

    func testExtractsAlbumObjectIDFromNamespacedCloudID() {
        XCTAssertEqual(
            SonosAlbumBrowseID.from("appleMusic:album:1440864059#catalog"),
            "album:1440864059"
        )
    }

    func testExtractsAlbumObjectIDFromSonosContainerID() {
        XCTAssertEqual(
            SonosAlbumBrowseID.from("1004206calbum%3A1440864059"),
            "album:1440864059"
        )
    }

    func testExtractsAlbumObjectIDFromSpacedSonosContainerID() {
        XCTAssertEqual(
            SonosAlbumBrowseID.from("1004206c%20album%3A1440864059"),
            "album:1440864059"
        )
    }

    func testRejectsAlbumTitleAsConcreteAlbumObjectID() {
        XCTAssertNil(SonosAlbumBrowseID.concreteAlbumID(from: "一百種生活"))
    }

    func testAcceptsNamespacedAlbumObjectIDAsConcreteAlbumObjectID() {
        XCTAssertEqual(
            SonosAlbumBrowseID.concreteAlbumID(from: "appleMusic:album:1440864059#catalog"),
            "album:1440864059"
        )
    }
}
