import XCTest
@testable import SonosWidget

final class SonosPlaybackLinkDiagnosticsTests: XCTestCase {
    func testPlaybackLinkValueKeepsURIsSingleLine() {
        let value = "x-rincon-cpcontainer:1004206calbum%3A123\n?sid=204&flags=8300&sn=2"

        let logged = SonosLog.playbackLinkValue(value)

        XCTAssertEqual(logged, "x-rincon-cpcontainer:1004206calbum%3A123\\n?sid=204&flags=8300&sn=2")
    }

    func testPlaybackLinkValueTruncatesVeryLongValues() {
        let value = String(repeating: "a", count: 20)

        let logged = SonosLog.playbackLinkValue(value, maxLength: 8)

        XCTAssertEqual(logged, "aaaaaaaa…[truncated 12 chars]")
    }

    func testPlaybackMetadataSummaryIncludesCoreIdentifiers() {
        let metadata = """
        <DIDL-Lite><item id="1004206calbum%3A123"><dc:title>Album</dc:title><desc>SA_RINCON52231_X_#Svc52231-2-Token</desc><upnp:albumArtURI>https://example.com/a.jpg</upnp:albumArtURI></item></DIDL-Lite>
        """

        let summary = SonosLog.playbackMetadataSummary(metadata)

        XCTAssertTrue(summary.contains("bytes="))
        XCTAssertTrue(summary.contains("itemId=1004206calbum%3A123"))
        XCTAssertTrue(summary.contains("desc=SA_RINCON52231_X_#Svc52231-2-Token"))
        XCTAssertTrue(summary.contains("hasArt=true"))
    }
}
