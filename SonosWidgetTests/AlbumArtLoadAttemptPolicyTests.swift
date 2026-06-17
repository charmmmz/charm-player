import XCTest
@testable import SonosWidget

final class AlbumArtLoadAttemptPolicyTests: XCTestCase {
    func testRetriesSameURLWhenArtworkIsNotDisplayed() {
        XCTAssertTrue(
            AlbumArtLoadAttemptPolicy.shouldStartLoad(
                urlString: "https://example.com/current.jpg",
                lastLoadedURL: "https://example.com/current.jpg",
                hasDisplayedArtwork: false,
                loadingURL: nil
            )
        )
    }

    func testSkipsSameURLWhenArtworkIsAlreadyDisplayed() {
        XCTAssertFalse(
            AlbumArtLoadAttemptPolicy.shouldStartLoad(
                urlString: "https://example.com/current.jpg",
                lastLoadedURL: "https://example.com/current.jpg",
                hasDisplayedArtwork: true,
                loadingURL: nil
            )
        )
    }

    func testSkipsSameURLWhenLoadIsAlreadyInFlight() {
        XCTAssertFalse(
            AlbumArtLoadAttemptPolicy.shouldStartLoad(
                urlString: "https://example.com/current.jpg",
                lastLoadedURL: nil,
                hasDisplayedArtwork: false,
                loadingURL: "https://example.com/current.jpg"
            )
        )
    }

    func testStartsLoadForNewURL() {
        XCTAssertTrue(
            AlbumArtLoadAttemptPolicy.shouldStartLoad(
                urlString: "https://example.com/new.jpg",
                lastLoadedURL: "https://example.com/old.jpg",
                hasDisplayedArtwork: true,
                loadingURL: nil
            )
        )
    }

    func testDoesNotClearDisplayedArtworkForFirstMissingURLOnNewMusicTrack() {
        XCTAssertFalse(
            AlbumArtLoadAttemptPolicy.shouldClearArtworkForMissingURL(
                trackSource: .appleMusic,
                hasDisplayedArtwork: true,
                displayedTrackIdentity: "meta:song-1",
                incomingTrackIdentity: "meta:song-2",
                hasDeferredMissingArtworkForIncomingTrack: false
            )
        )
    }

    func testClearsDisplayedArtworkForRepeatedMissingURLOnSameIncomingTrack() {
        XCTAssertTrue(
            AlbumArtLoadAttemptPolicy.shouldClearArtworkForMissingURL(
                trackSource: .appleMusic,
                hasDisplayedArtwork: true,
                displayedTrackIdentity: "meta:song-1",
                incomingTrackIdentity: "meta:song-2",
                hasDeferredMissingArtworkForIncomingTrack: true
            )
        )
    }

    func testClearsDisplayedArtworkImmediatelyForTV() {
        XCTAssertTrue(
            AlbumArtLoadAttemptPolicy.shouldClearArtworkForMissingURL(
                trackSource: .tv,
                hasDisplayedArtwork: true,
                displayedTrackIdentity: "meta:song-1",
                incomingTrackIdentity: "meta:tv",
                hasDeferredMissingArtworkForIncomingTrack: false
            )
        )
    }

    func testDoesNotCarryPreviousArtworkURLToDifferentTrack() {
        let previous = TrackInfo(
            title: "Song One",
            artist: "Artist",
            album: "Album",
            albumArtURL: "https://example.com/song-1.jpg",
            source: .appleMusic
        )
        let incoming = TrackInfo(
            title: "Song Two",
            artist: "Artist",
            album: "Album",
            source: .appleMusic
        )

        XCTAssertNil(
            AlbumArtURLCarryoverPolicy.albumArtURL(
                incomingURL: nil,
                previousTrackInfo: previous,
                incomingTrackInfo: incoming
            )
        )
    }

    func testCarriesPreviousArtworkURLForSameTrackWhenIncomingURLIsTemporarilyMissing() {
        let previous = TrackInfo(
            title: "Song One",
            artist: "Artist",
            album: "Album",
            albumArtURL: "https://example.com/song-1.jpg",
            source: .appleMusic
        )
        let incoming = TrackInfo(
            title: "Song One",
            artist: "Artist",
            album: "Album",
            source: .appleMusic
        )

        XCTAssertEqual(
            AlbumArtURLCarryoverPolicy.albumArtURL(
                incomingURL: nil,
                previousTrackInfo: previous,
                incomingTrackInfo: incoming
            ),
            "https://example.com/song-1.jpg"
        )
    }

    func testQueueArtPrefetchLimitsLocalSonosArtworkButKeepsRemoteArtwork() {
        let urls = [
            "http://192.168.50.25:1400/getaa?s=1",
            "http://192.168.50.25:1400/getaa?s=2",
            "http://192.168.50.25:1400/getaa?s=3",
            "https://is1-ssl.mzstatic.com/image/thumb/example.jpg"
        ]

        XCTAssertEqual(
            QueueArtPrefetchPolicy.urlsToPrefetch(
                from: urls,
                cachedURLs: [],
                localSonosArtworkLimit: 2
            ),
            [
                "http://192.168.50.25:1400/getaa?s=1",
                "http://192.168.50.25:1400/getaa?s=2",
                "https://is1-ssl.mzstatic.com/image/thumb/example.jpg"
            ]
        )
    }

    func testQueueArtPrefetchSkipsCachedAndDuplicateURLs() {
        let urls = [
            "http://192.168.50.25:1400/getaa?s=1",
            "http://192.168.50.25:1400/getaa?s=1",
            "https://example.com/remote.jpg"
        ]

        XCTAssertEqual(
            QueueArtPrefetchPolicy.urlsToPrefetch(
                from: urls,
                cachedURLs: ["http://192.168.50.25:1400/getaa?s=1"],
                localSonosArtworkLimit: 2
            ),
            ["https://example.com/remote.jpg"]
        )
    }

    func testQueueArtPrefetchUsesLowerConcurrencyWhenLocalSonosArtworkIsPresent() {
        XCTAssertEqual(
            QueueArtPrefetchPolicy.maxConcurrentFetches(
                for: ["http://192.168.50.25:1400/getaa?s=1"]
            ),
            2
        )
        XCTAssertEqual(
            QueueArtPrefetchPolicy.maxConcurrentFetches(
                for: ["https://is1-ssl.mzstatic.com/image/thumb/example.jpg"]
            ),
            8
        )
    }
}
