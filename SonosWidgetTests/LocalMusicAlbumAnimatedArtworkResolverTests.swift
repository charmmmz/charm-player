import XCTest
@testable import SonosWidget

@MainActor
final class LocalMusicAlbumAnimatedArtworkResolverTests: XCTestCase {
    func testResolvesByMetadataSearchWhenAlbumURLIsMissing() async {
        let metadataLookup = expectation(description: "metadata search fallback attempted")
        let resolver = LocalMusicAlbumAnimatedArtworkResolver(
            registry: AnimatedArtworkRegistry(),
            relayURLLookup: { _ in
                XCTFail("URL lookup should not run without an album URL")
                throw URLError(.badURL)
            },
            relayMetadataLookup: { artist, album in
                XCTAssertEqual(artist, "LINKIN PARK")
                XCTAssertEqual(album, "Hybrid Theory (Deluxe Edition)")
                metadataLookup.fulfill()
                return Self.hitResponse(
                    artist: artist,
                    album: album,
                    appleMusicURLString: "https://music.apple.com/us/album/hybrid-theory-deluxe-edition/590431776"
                )
            },
            now: { Date(timeIntervalSince1970: 1) }
        )

        let info = await resolver.resolve(
            albumURL: nil,
            title: "Hybrid Theory (Deluxe Edition)",
            artist: "LINKIN PARK"
        )

        await fulfillment(of: [metadataLookup], timeout: 1)
        XCTAssertEqual(info?.fullScreenPlayerURL?.absoluteString, "https://video.example.com/tall.m3u8")
        XCTAssertEqual(info?.appleMusicURLString, "https://music.apple.com/us/album/hybrid-theory-deluxe-edition/590431776")
        XCTAssertEqual(info?.source, .metadataSearch)
    }

    func testFallsBackToMetadataSearchWhenAlbumURLLookupMisses() async {
        let urlLookup = expectation(description: "URL lookup attempted")
        let metadataLookup = expectation(description: "metadata search fallback attempted")
        let resolver = LocalMusicAlbumAnimatedArtworkResolver(
            registry: AnimatedArtworkRegistry(),
            relayURLLookup: { url in
                XCTAssertEqual(url.absoluteString, "https://music.apple.com/us/song/papercut/590431777")
                urlLookup.fulfill()
                return RelayClient.AnimatedArtworkResponse(
                    ok: true,
                    status: .miss,
                    artist: nil,
                    album: nil,
                    appleMusicURLString: nil,
                    squareURLString: nil,
                    tallURLString: nil,
                    source: "none"
                )
            },
            relayMetadataLookup: { artist, album in
                XCTAssertEqual(artist, "LINKIN PARK")
                XCTAssertEqual(album, "Hybrid Theory (Deluxe Edition)")
                metadataLookup.fulfill()
                return Self.hitResponse(
                    artist: artist,
                    album: album,
                    appleMusicURLString: "https://music.apple.com/us/album/hybrid-theory-deluxe-edition/590431776"
                )
            },
            now: { Date(timeIntervalSince1970: 1) }
        )

        let info = await resolver.resolve(
            albumURL: URL(string: "https://music.apple.com/us/song/papercut/590431777"),
            title: "Hybrid Theory (Deluxe Edition)",
            artist: "LINKIN PARK"
        )

        await fulfillment(of: [urlLookup, metadataLookup], timeout: 1)
        XCTAssertEqual(info?.fullScreenPlayerURL?.absoluteString, "https://video.example.com/tall.m3u8")
        XCTAssertEqual(info?.source, .metadataSearch)
    }

    nonisolated private static func hitResponse(
        artist: String,
        album: String,
        appleMusicURLString: String
    ) -> RelayClient.AnimatedArtworkResponse {
        RelayClient.AnimatedArtworkResponse(
            ok: true,
            status: .hit,
            artist: artist,
            album: album,
            appleMusicURLString: appleMusicURLString,
            squareURLString: "https://video.example.com/square.m3u8",
            squareWidth: 2160,
            squareHeight: 2160,
            squareAspectRatio: 1,
            tallURLString: "https://video.example.com/tall.m3u8",
            tallWidth: 2048,
            tallHeight: 2732,
            tallAspectRatio: 0.749634,
            source: "metadata-search"
        )
    }
}
