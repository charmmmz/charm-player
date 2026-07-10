import XCTest
@testable import SonosWidget

@MainActor
final class AnimatedArtworkRegistryTests: XCTestCase {
    func testLookupPrefersAlbumURLOverMetadataFallback() {
        let registry = AnimatedArtworkRegistry()
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/url.m3u8",
                tallURLString: nil,
                appleMusicURLString: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522",
                artist: "Taylor Swift",
                album: "evermore",
                source: .url,
                resolvedAt: Date(timeIntervalSince1970: 1)
            )
        )
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/metadata.m3u8",
                tallURLString: nil,
                appleMusicURLString: nil,
                artist: "Taylor Swift",
                album: "evermore",
                source: .metadataSearch,
                resolvedAt: Date(timeIntervalSince1970: 2)
            )
        )

        let result = registry.artwork(
            appleMusicURLString: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522",
            artist: "Taylor Swift",
            album: "evermore"
        )

        XCTAssertEqual(result?.squareURLString, "https://video.example.com/url.m3u8")
    }

    func testCatalogIDMatchesWhenAppleMusicURLShapeDiffers() {
        let registry = AnimatedArtworkRegistry()
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/catalog.m3u8",
                tallURLString: nil,
                appleMusicURLString: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522",
                artist: "Taylor Swift",
                album: "evermore",
                source: .url,
                resolvedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let result = registry.artwork(
            appleMusicURLString: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522?i=1547315527",
            artist: nil,
            album: nil
        )

        XCTAssertEqual(result?.squareURLString, "https://video.example.com/catalog.m3u8")
    }

    func testAmbiguousMetadataDoesNotReturnStaleVideo() {
        let registry = AnimatedArtworkRegistry()
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/a.m3u8",
                tallURLString: nil,
                appleMusicURLString: nil,
                artist: "Artist",
                album: "Album",
                source: .metadataSearch,
                resolvedAt: Date(timeIntervalSince1970: 1)
            )
        )
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/b.m3u8",
                tallURLString: nil,
                appleMusicURLString: nil,
                artist: "Artist",
                album: "Album",
                source: .metadataSearch,
                resolvedAt: Date(timeIntervalSince1970: 2)
            )
        )

        XCTAssertNil(registry.artwork(appleMusicURLString: nil, artist: "Artist", album: "Album"))
    }

    func testInfoFromRelayResponseUsesFallbacksAndRejectsMisses() throws {
        let hit = RelayClient.AnimatedArtworkResponse(
            ok: true,
            status: .hit,
            artist: nil,
            album: nil,
            appleMusicURLString: nil,
            squareURLString: nil,
            tallURLString: "https://video.example.com/tall.m3u8",
            tallWidth: 1080,
            tallHeight: 1440,
            tallAspectRatio: 0.75,
            source: "metadata-search"
        )

        let info = try XCTUnwrap(AnimatedArtworkInfo(
            response: hit,
            fallbackAppleMusicURLString: "https://music.apple.com/us/album/planet-her-deluxe/1574004234",
            fallbackArtist: "Doja Cat",
            fallbackAlbum: "Planet Her",
            resolvedAt: Date(timeIntervalSince1970: 42)
        ))

        XCTAssertEqual(info.tallURLString, "https://video.example.com/tall.m3u8")
        XCTAssertEqual(info.tallWidth, 1080)
        XCTAssertEqual(info.tallHeight, 1440)
        XCTAssertEqual(info.tallAspectRatio, 0.75)
        XCTAssertEqual(info.appleMusicURLString, "https://music.apple.com/us/album/planet-her-deluxe/1574004234")
        XCTAssertEqual(info.artist, "Doja Cat")
        XCTAssertEqual(info.album, "Planet Her")
        XCTAssertEqual(info.source, .metadataSearch)
        XCTAssertEqual(info.resolvedAt, Date(timeIntervalSince1970: 42))

        let miss = RelayClient.AnimatedArtworkResponse(
            ok: true,
            status: .miss,
            artist: "Doja Cat",
            album: "Planet Her",
            appleMusicURLString: nil,
            squareURLString: nil,
            tallURLString: nil,
            source: "none"
        )

        XCTAssertNil(AnimatedArtworkInfo(
            response: miss,
            fallbackAppleMusicURLString: nil,
            fallbackArtist: nil,
            fallbackAlbum: nil,
            resolvedAt: Date()
        ))
    }

    func testFullScreenPlayerURLPrefersTallArtworkWithoutChangingCompactURL() throws {
        let info = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: "https://video.example.com/tall.m3u8",
            appleMusicURLString: nil,
            artist: "The Weeknd",
            album: "After Hours",
            source: .metadataSearch,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(info.playerURL?.absoluteString, "https://video.example.com/square.m3u8")
        XCTAssertEqual(info.fullScreenPlayerURL?.absoluteString, "https://video.example.com/tall.m3u8")
    }

    func testFullScreenPlayerURLFallsBackToSquareWhenTallArtworkIsMissing() throws {
        let info = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: nil,
            appleMusicURLString: nil,
            artist: "The Weeknd",
            album: "After Hours",
            source: .metadataSearch,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(info.fullScreenPlayerURL?.absoluteString, "https://video.example.com/square.m3u8")
    }
}
