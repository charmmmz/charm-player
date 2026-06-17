import XCTest
@testable import SonosWidget

final class ArtworkURLNormalizerTests: XCTestCase {
    func testResolvesRelativeMusicKitArtworkAATToAppleCDN() {
        let urlString = ArtworkURLNormalizer.loadableURLString(
            from: "musicKit://artwork/library/ABC/600x600?aat=Features125%2Fv4%2Fad%2F0e%2F48%2Fcover%2Epng&at=playlist&et=collection",
            shortSidePixels: 400
        )

        XCTAssertEqual(
            urlString,
            "https://is1-ssl.mzstatic.com/image/thumb/Features125/v4/ad/0e/48/cover.png/400x400bb.jpg"
        )
    }

    func testResizesAppleArtworkURL() {
        let urlString = ArtworkURLNormalizer.loadableURLString(
            from: "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/cover/600x600bb.jpg",
            shortSidePixels: 300
        )

        XCTAssertEqual(
            urlString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/cover/300x300bb.jpg"
        )
    }

    func testBuildsSonosArtworkURLFromRelativePathAndSpeakerIP() {
        let urlString = ArtworkURLNormalizer.loadableURLString(
            from: "/getaa?s=1&u=x-rincon-queue:RINCON_123#0",
            speakerIP: "192.168.1.25"
        )

        XCTAssertEqual(
            urlString,
            "http://192.168.1.25:1400/getaa?s=1&u=x-rincon-queue:RINCON_123#0"
        )
    }

    func testRejectsUnstructuredMusicKitArtworkAAT() {
        let urlString = ArtworkURLNormalizer.loadableURLString(
            from: "musicKit://artwork/library/ABC/600x600?aat=not-a-real-artwork-path&at=playlist&et=collection",
            shortSidePixels: 400
        )

        XCTAssertNil(urlString)
    }
}
