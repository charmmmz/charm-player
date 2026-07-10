import XCTest
@testable import SonosWidget

final class AppleMusicShareLinkParserTests: XCTestCase {
    func testParsesSongURL() {
        let link = AppleMusicShareLinkParser.parse("https://music.apple.com/us/song/nikes/1440857781")

        XCTAssertEqual(link?.kind, .song)
        XCTAssertEqual(link?.catalogID, "1440857781")
        XCTAssertEqual(link?.originalURLString, "https://music.apple.com/us/song/nikes/1440857781")
    }

    func testAlbumURLWithSongQueryPrefersSongID() {
        let link = AppleMusicShareLinkParser.parse(
            "https://music.apple.com/us/album/blonde/1440864059?i=1440857781&ls=1"
        )

        XCTAssertEqual(link?.kind, .song)
        XCTAssertEqual(link?.catalogID, "1440857781")
    }

    func testParsesAlbumURLWithoutSongQuery() {
        let link = AppleMusicShareLinkParser.parse("https://music.apple.com/us/album/blonde/1440864059")

        XCTAssertEqual(link?.kind, .album)
        XCTAssertEqual(link?.catalogID, "1440864059")
    }

    func testParsesPlaylistURLWithNonNumericCatalogID() {
        let link = AppleMusicShareLinkParser.parse(
            "https://music.apple.com/us/playlist/sunday/pl.u-11zBJkBtxxE"
        )

        XCTAssertEqual(link?.kind, .playlist)
        XCTAssertEqual(link?.catalogID, "pl.u-11zBJkBtxxE")
    }

    func testParsesArtistURL() {
        let link = AppleMusicShareLinkParser.parse("https://music.apple.com/us/artist/frank-ocean/442122051")

        XCTAssertEqual(link?.kind, .artist)
        XCTAssertEqual(link?.catalogID, "442122051")
    }

    func testExtractsFirstAppleMusicURLFromSharedText() {
        let link = AppleMusicShareLinkParser.parse(
            "Listen to Nikes by Frank Ocean on Apple Music. https://music.apple.com/us/song/nikes/1440857781?l=en"
        )

        XCTAssertEqual(link?.kind, .song)
        XCTAssertEqual(link?.catalogID, "1440857781")
    }

    func testRejectsUnsupportedDomains() {
        let link = AppleMusicShareLinkParser.parse("https://example.com/us/song/nikes/1440857781")

        XCTAssertNil(link)
    }

    func testRejectsUnsupportedAppleMusicKind() {
        let link = AppleMusicShareLinkParser.parse("https://music.apple.com/us/music-video/example/1234567890")

        XCTAssertNil(link)
    }

    func testRejectsPlainTextWithoutURL() {
        let link = AppleMusicShareLinkParser.parse("Nikes by Frank Ocean")

        XCTAssertNil(link)
    }
}
