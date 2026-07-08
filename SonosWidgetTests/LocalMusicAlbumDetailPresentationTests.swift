import XCTest
@testable import SonosWidget

final class LocalMusicAlbumDetailPresentationTests: XCTestCase {
    func testShowsCompleteAlbumButtonOnlyWhenCatalogAlbumHasMoreTracks() {
        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.shouldShowCompleteAlbumButton(
                currentAlbumID: "l.partial-album",
                currentTrackCount: 2,
                completeAlbumID: "1440864059",
                completeTrackCount: 17)
        )
    }

    func testOmitsCompleteAlbumButtonWhenCatalogAlbumIsNotMoreComplete() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldShowCompleteAlbumButton(
                currentAlbumID: "l.complete-album",
                currentTrackCount: 10,
                completeAlbumID: "1440864059",
                completeTrackCount: 10)
        )
    }

    func testOmitsCompleteAlbumButtonForSameAlbumID() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldShowCompleteAlbumButton(
                currentAlbumID: "1440864059",
                currentTrackCount: 10,
                completeAlbumID: "1440864059",
                completeTrackCount: 17)
        )
    }

    func testPlaybackUsesCurrentPageAlbumEvenWhenCompleteAlbumExists() {
        XCTAssertEqual(
            LocalMusicAlbumDetailPresentation.playbackAlbumID(
                currentAlbumID: "l.partial-album",
                completeAlbumID: "1440864059"),
            "l.partial-album"
        )
    }

    func testLibraryPartialAlbumActionUsesDisplayedTracks() {
        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(
                currentAlbumID: "l.partial-album",
                currentTrackCount: 2,
                completeAlbumID: "1440864059",
                completeTrackCount: 17)
        )
    }

    func testCatalogAlbumActionUsesAlbumContainerWhenTracksAreLoaded() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(
                currentAlbumID: "1839352404",
                currentTrackCount: 12,
                completeAlbumID: "1839352404",
                completeTrackCount: 12)
        )
    }

    func testLibraryCompleteAlbumActionUsesAlbumContainer() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(
                currentAlbumID: "l.complete-album",
                currentTrackCount: 10,
                completeAlbumID: "1440864059",
                completeTrackCount: 10)
        )
    }

    func testLocalMusicAlbumAnimatedArtworkCanResolveWithMetadataFallback() throws {
        let url = try XCTUnwrap(URL(string: "https://music.apple.com/us/album/never-enough/1681198089"))

        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.shouldResolveAnimatedArtwork(
                albumURL: url,
                title: "NEVER ENOUGH",
                artist: "Daniel Caesar",
                isEnabled: true)
        )
        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.shouldResolveAnimatedArtwork(
                albumURL: nil,
                title: "NEVER ENOUGH",
                artist: "Daniel Caesar",
                isEnabled: true)
        )
    }

    func testLocalMusicAlbumAnimatedArtworkLookupIDChangesWhenCompleteCatalogAlbumArrives() {
        let initialID = LocalMusicAlbumDetailPresentation.animatedArtworkLookupID(
            currentAlbumID: "album:75426404",
            title: "A Thousand Suns (Deluxe Edition)",
            artist: "LINKIN PARK",
            completeCatalogAlbumID: nil)
        let resolvedID = LocalMusicAlbumDetailPresentation.animatedArtworkLookupID(
            currentAlbumID: "album:75426404",
            title: "A Thousand Suns (Deluxe Edition)",
            artist: "LINKIN PARK",
            completeCatalogAlbumID: "590434066")

        XCTAssertNotEqual(initialID, resolvedID)
        XCTAssertTrue(resolvedID.contains("590434066"))
    }

    func testLocalMusicAlbumAnimatedArtworkPrefersCompleteCatalogIDOverLocalPlayableID() {
        XCTAssertEqual(
            LocalMusicAlbumDetailPresentation.preferredAnimatedArtworkCatalogID(
                currentPlayableCatalogID: "album:75426404",
                completeCatalogAlbumID: "590434066"),
            "590434066"
        )
    }

    func testLocalMusicAlbumTitleLinkCanUseResolvedAppleMusicURL() throws {
        let url = try XCTUnwrap(URL(string: "https://music.apple.com/us/album/never-enough/1681198089"))

        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.canResolveAppleMusicTitleLink(
                appleMusicURL: url,
                title: " ",
                artist: "Unknown")
        )
    }

    func testLocalMusicAlbumTitleLinkCanUseMetadataFallback() {
        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.canResolveAppleMusicTitleLink(
                appleMusicURL: nil,
                title: "NEVER ENOUGH",
                artist: "Daniel Caesar")
        )
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.canResolveAppleMusicTitleLink(
                appleMusicURL: nil,
                title: "NEVER ENOUGH",
                artist: "Unknown")
        )
    }

    func testLocalMusicAlbumAnimatedArtworkRetriesForLateRelayOrCatalogResults() {
        XCTAssertEqual(
            LocalMusicAlbumDetailPresentation.animatedArtworkRetryDelayNanoseconds(
                afterFailedAttempt: 0,
                hasAnimatedArtwork: false),
            400_000_000
        )
        XCTAssertEqual(
            LocalMusicAlbumDetailPresentation.animatedArtworkRetryDelayNanoseconds(
                afterFailedAttempt: 4,
                hasAnimatedArtwork: false),
            5_000_000_000
        )
        XCTAssertNil(
            LocalMusicAlbumDetailPresentation.animatedArtworkRetryDelayNanoseconds(
                afterFailedAttempt: 5,
                hasAnimatedArtwork: false)
        )
        XCTAssertNil(
            LocalMusicAlbumDetailPresentation.animatedArtworkRetryDelayNanoseconds(
                afterFailedAttempt: 0,
                hasAnimatedArtwork: true)
        )
    }

    func testLocalMusicAlbumAnimatedArtworkLookupStartKeepsExistingArtworkWhileEnabled() {
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldClearAnimatedArtworkBeforeLookup(
                isEnabled: true)
        )
        XCTAssertTrue(
            LocalMusicAlbumDetailPresentation.shouldClearAnimatedArtworkBeforeLookup(
                isEnabled: false)
        )
    }

    func testLocalMusicAlbumAnimatedArtworkCacheMissPreservesExistingArtwork() throws {
        let current = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/current.m3u8",
            tallURLString: "https://video.example.com/current-tall.m3u8",
            tallAspectRatio: 0.75,
            appleMusicURLString: "https://music.apple.com/us/album/current/1",
            artist: "Artist",
            album: "Current",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )
        let cached = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/new.m3u8",
            tallURLString: "https://video.example.com/new-tall.m3u8",
            tallAspectRatio: 0.75,
            appleMusicURLString: "https://music.apple.com/us/album/new/2",
            artist: "Artist",
            album: "New",
            source: .cache,
            resolvedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(
            LocalMusicAlbumDetailPresentation.animatedArtworkInfoAfterCacheLookup(
                current: current,
                cached: nil,
                isEnabled: true),
            current
        )
        XCTAssertEqual(
            LocalMusicAlbumDetailPresentation.animatedArtworkInfoAfterCacheLookup(
                current: current,
                cached: cached,
                isEnabled: true),
            cached
        )
        XCTAssertNil(
            LocalMusicAlbumDetailPresentation.animatedArtworkInfoAfterCacheLookup(
                current: current,
                cached: cached,
                isEnabled: false)
        )
    }

    func testLocalMusicAlbumAnimatedArtworkRequiresMeaningfulMetadata() throws {
        let url = try XCTUnwrap(URL(string: "https://music.apple.com/us/album/never-enough/1681198089"))

        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldResolveAnimatedArtwork(
                albumURL: url,
                title: " ",
                artist: "Daniel Caesar",
                isEnabled: true)
        )
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldResolveAnimatedArtwork(
                albumURL: url,
                title: "NEVER ENOUGH",
                artist: "Unknown",
                isEnabled: true)
        )
        XCTAssertFalse(
            LocalMusicAlbumDetailPresentation.shouldResolveAnimatedArtwork(
                albumURL: url,
                title: "NEVER ENOUGH",
                artist: "Daniel Caesar",
                isEnabled: false)
        )
    }

    func testLocalMusicAlbumAnimatedArtworkUsesFullScreenTallPresentation() {
        let info = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: "https://video.example.com/tall.m3u8",
            appleMusicURLString: "https://music.apple.com/us/album/never-enough/1681198089",
            artist: "Daniel Caesar",
            album: "NEVER ENOUGH",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            LocalMusicAlbumDetailPresentation.animatedArtworkBackgroundURL(
                info: info,
                isEnabled: true
            )?.absoluteString,
            "https://video.example.com/tall.m3u8"
        )
        XCTAssertNil(
            LocalMusicAlbumDetailPresentation.animatedArtworkHeaderURL(
                info: info,
                isEnabled: true
            )
        )
    }
}
