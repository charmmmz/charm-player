import XCTest
@testable import SonosWidget

final class ArtistDetailArtistIDResolutionPolicyTests: XCTestCase {
    func testTrustedArtistCatalogIdSkipsSearchResolution() {
        XCTAssertFalse(
            ArtistDetailArtistIDResolutionPolicy.shouldResolveCatalogArtist(
                rawArtistId: "artist%3A1892954657",
                isAppleMusic: true
            )
        )
        XCTAssertEqual(
            ArtistDetailArtistIDResolutionPolicy.browseArtistId(from: "artist%3A1892954657"),
            "artist:1892954657"
        )
    }

    func testNameOnlyArtistIdAllowsSearchResolutionForAppleMusic() {
        XCTAssertTrue(
            ArtistDetailArtistIDResolutionPolicy.shouldResolveCatalogArtist(
                rawArtistId: "Yi",
                isAppleMusic: true
            )
        )
    }

    func testNonExactArtistSearchResultDoesNotReplaceShortArtistName() {
        let selected = ArtistDetailArtistIDResolutionPolicy.preferredArtistResource(
            candidates: [
                .init(name: "Yiyo Sarante", objectId: "artist:500109790", isLibraryScoped: false),
                .init(name: "Yi", objectId: "artist:1892954657", isLibraryScoped: false)
            ],
            targetName: "Yi"
        )

        XCTAssertEqual(selected?.objectId, "artist:1892954657")
    }

    func testNameOnlyFallbackDoesNotUseLooseFirstArtistWhenNoExactMatchExists() {
        let selected = ArtistDetailArtistIDResolutionPolicy.preferredArtistResource(
            candidates: [
                .init(name: "Yiyo Sarante", objectId: "artist:500109790", isLibraryScoped: false)
            ],
            targetName: "Yi"
        )

        XCTAssertNil(selected)
    }
}
