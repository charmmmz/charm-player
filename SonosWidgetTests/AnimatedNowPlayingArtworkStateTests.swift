import XCTest
@testable import SonosWidget

@MainActor
final class AnimatedNowPlayingArtworkStateTests: XCTestCase {
    func testEligibilityRejectsReduceMotionLowPowerAndNonAppleMusic() {
        XCTAssertFalse(AnimatedArtworkFeature.canRenderVideo(
            source: .appleMusic,
            isReduceMotionEnabled: true,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(AnimatedArtworkFeature.canRenderVideo(
            source: .appleMusic,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: true
        ))
        XCTAssertFalse(AnimatedArtworkFeature.canRenderVideo(
            source: .spotify,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        ))
        XCTAssertTrue(AnimatedArtworkFeature.canRenderVideo(
            source: .appleMusic,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        ))
    }

    func testStaleLookupResultIsDiscarded() {
        let state = AnimatedNowPlayingArtworkState(registry: AnimatedArtworkRegistry())
        let oldIdentity = AnimatedNowPlayingArtworkState.Identity(
            trackURI: "old",
            title: "Old",
            artist: "Artist",
            album: "Album"
        )
        let newIdentity = AnimatedNowPlayingArtworkState.Identity(
            trackURI: "new",
            title: "New",
            artist: "Artist",
            album: "Album"
        )

        state.beginLookup(identity: oldIdentity)
        state.beginLookup(identity: newIdentity)
        state.apply(
            info: AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/old.m3u8",
                tallURLString: nil,
                appleMusicURLString: nil,
                artist: "Artist",
                album: "Album",
                source: .metadataSearch,
                resolvedAt: Date()
            ),
            for: oldIdentity
        )

        XCTAssertNil(state.currentInfo)
        XCTAssertNil(state.currentURL)
    }

    func testResolveUsesRegistryHitBeforeRelayLookup() {
        let registry = AnimatedArtworkRegistry()
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/cached.m3u8",
                tallURLString: nil,
                appleMusicURLString: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522",
                artist: "Taylor Swift",
                album: "evermore",
                source: .url,
                resolvedAt: Date()
            )
        )
        let state = AnimatedNowPlayingArtworkState(
            registry: registry,
            relayLookup: { _ in
                XCTFail("Relay lookup should not run after registry hit")
                throw URLError(.badServerResponse)
            }
        )

        state.resolve(
            identity: .init(
                trackURI: "track",
                title: "willow",
                artist: "Taylor Swift",
                album: "evermore"
            ),
            albumURL: URL(string: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522"),
            relayBaseURL: URL(string: "http://192.168.50.2:8787"),
            source: .appleMusic,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        )

        XCTAssertEqual(state.currentURL?.absoluteString, "https://video.example.com/cached.m3u8")
    }

    func testResolveFallsBackToMetadataSearchWhenURLLookupMisses() async {
        let urlLookup = expectation(description: "URL lookup attempted")
        let metadataSearch = expectation(description: "metadata search fallback attempted")
        let state = AnimatedNowPlayingArtworkState(
            registry: AnimatedArtworkRegistry(),
            relayLookup: { request in
                if request.albumURL != nil {
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
                }

                metadataSearch.fulfill()
                return RelayClient.AnimatedArtworkResponse(
                    ok: true,
                    status: .hit,
                    artist: request.artist,
                    album: request.album,
                    appleMusicURLString: "https://music.apple.com/us/album/after-hours/1499385848",
                    squareURLString: "https://video.example.com/square.m3u8",
                    tallURLString: "https://video.example.com/tall.m3u8",
                    source: "metadata-search"
                )
            }
        )

        state.resolve(
            identity: .init(
                trackURI: "song",
                title: "Blinding Lights",
                artist: "The Weeknd",
                album: "After Hours"
            ),
            albumURL: URL(string: "https://music.apple.com/us/song/blinding-lights/1499378607"),
            relayBaseURL: URL(string: "http://192.168.50.2:8787"),
            source: .appleMusic,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        )

        await fulfillment(of: [urlLookup, metadataSearch], timeout: 1)
        await waitForCurrentURL(in: state)

        XCTAssertEqual(state.currentURL?.absoluteString, "https://video.example.com/square.m3u8")
        XCTAssertEqual(state.currentInfo?.fullScreenPlayerURL?.absoluteString, "https://video.example.com/tall.m3u8")
    }

    private func waitForCurrentURL(
        in state: AnimatedNowPlayingArtworkState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 {
            if state.currentURL != nil { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for animated artwork URL", file: file, line: line)
    }
}
