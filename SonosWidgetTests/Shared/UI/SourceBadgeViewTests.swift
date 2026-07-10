import XCTest
@testable import SonosWidget

@MainActor
final class SourceBadgeViewTests: XCTestCase {
    func testAppleMusicBadgeUsesBundledAppleMusicWordmark() {
        let presentation = SourceBadgePresentation(source: .appleMusic)

        XCTAssertNil(presentation.iconSystemName)
        XCTAssertNil(presentation.title)
        XCTAssertEqual(presentation.brandAssetImageName, "BrandAppleMusicWordmark")
        XCTAssertEqual(presentation.brandMarkWidth(compact: false), 46)
        XCTAssertEqual(presentation.brandMarkWidth(compact: true), 38)
    }

    func testOtherStreamingBadgesKeepBundledBrandAssetsWithoutDuplicatingTitles() {
        let presentation = SourceBadgePresentation(source: .spotify)

        XCTAssertNil(presentation.iconSystemName)
        XCTAssertNil(presentation.title)
        XCTAssertEqual(presentation.brandAssetImageName, "BrandSpotify")
        XCTAssertEqual(presentation.brandMarkWidth(compact: false), 14)
        XCTAssertEqual(presentation.brandMarkWidth(compact: true), 12)
    }

    func testNonBrandSourcesKeepSystemIconAndTitle() {
        let presentation = SourceBadgePresentation(source: .airplay)

        XCTAssertNil(presentation.brandAssetImageName)
        XCTAssertEqual(presentation.iconSystemName, "airplayaudio")
        XCTAssertEqual(presentation.title, "AirPlay")
    }
}
