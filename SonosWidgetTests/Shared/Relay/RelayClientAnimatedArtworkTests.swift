import XCTest
@testable import SonosWidget

final class RelayClientAnimatedArtworkTests: XCTestCase {
    func testAnimatedArtworkURLBuilderEscapesAlbumURLAndCountry() throws {
        let baseURL = URL(string: "http://192.168.50.2:8787")!
        let albumURL = URL(string: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522?i=1547315527")!

        let url = try XCTUnwrap(RelayClient.animatedArtworkURL(
            baseURL: baseURL,
            albumURL: albumURL,
            countryCode: "us"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "192.168.50.2")
        XCTAssertEqual(components.port, 8787)
        XCTAssertEqual(components.path, "/api/animated-artwork/url")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "url" })?.value,
            albumURL.absoluteString
        )
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "country" })?.value, "us")
    }

    func testAnimatedArtworkSearchURLBuilderEscapesMetadata() throws {
        let baseURL = URL(string: "http://192.168.50.2:8787")!

        let url = try XCTUnwrap(RelayClient.animatedArtworkSearchURL(
            baseURL: baseURL,
            artist: " Doja Cat ",
            album: " Planet Her (Deluxe) ",
            countryCode: "us"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/api/animated-artwork/search")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "artist" })?.value, "Doja Cat")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "album" })?.value, "Planet Her (Deluxe)")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "country" })?.value, "us")
    }

    func testAnimatedArtworkSearchURLRejectsMissingMetadata() {
        let baseURL = URL(string: "http://192.168.50.2:8787")!

        XCTAssertNil(RelayClient.animatedArtworkSearchURL(
            baseURL: baseURL,
            artist: " ",
            album: "Planet Her",
            countryCode: "us"
        ))
        XCTAssertNil(RelayClient.animatedArtworkSearchURL(
            baseURL: baseURL,
            artist: "Doja Cat",
            album: " ",
            countryCode: "us"
        ))
    }

    func testAnimatedArtworkResponseDecodesHitAndUnknownStatus() throws {
        let hitData = Data("""
        {
          "ok": true,
          "status": "hit",
          "artist": "Taylor Swift",
          "album": "evermore",
          "appleMusicUrl": "https://music.apple.com/us/album/evermore-deluxe-version/1547315522",
          "squareUrl": "https://video.example.com/square.m3u8",
          "squareWidth": 1080,
          "squareHeight": 1080,
          "squareAspectRatio": 1.0,
          "tallUrl": null,
          "tallWidth": null,
          "tallHeight": null,
          "tallAspectRatio": null,
          "source": "url"
        }
        """.utf8)

        let hit = try JSONDecoder().decode(RelayClient.AnimatedArtworkResponse.self, from: hitData)
        XCTAssertEqual(hit.status, .hit)
        XCTAssertEqual(hit.squareURLString, "https://video.example.com/square.m3u8")
        XCTAssertEqual(hit.squareWidth, 1080)
        XCTAssertEqual(hit.squareHeight, 1080)
        XCTAssertEqual(hit.squareAspectRatio, 1.0)
        XCTAssertEqual(hit.bestPlayerArtworkURL?.absoluteString, "https://video.example.com/square.m3u8")

        let unknownData = Data("""
        {
          "ok": true,
          "status": "future",
          "artist": null,
          "album": null,
          "appleMusicUrl": null,
          "squareUrl": null,
          "tallUrl": "https://video.example.com/tall.m3u8",
          "tallWidth": 1080,
          "tallHeight": 1440,
          "tallAspectRatio": 0.75,
          "source": "none"
        }
        """.utf8)

        let unknown = try JSONDecoder().decode(RelayClient.AnimatedArtworkResponse.self, from: unknownData)
        XCTAssertEqual(unknown.status, .unknown)
        XCTAssertEqual(unknown.tallWidth, 1080)
        XCTAssertEqual(unknown.tallHeight, 1440)
        XCTAssertEqual(unknown.tallAspectRatio, 0.75)
        XCTAssertEqual(unknown.bestPlayerArtworkURL?.absoluteString, "https://video.example.com/tall.m3u8")
    }
}
