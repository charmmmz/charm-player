import XCTest
@testable import SonosWidget

final class QueueArtworkLoadPolicyTests: XCTestCase {
    func testDoesNotLoadDiskCacheWhileArtworkCachingIsDisabled() {
        XCTAssertFalse(
            QueueArtworkLoadPolicy.shouldLoadQueueDiskCacheAsync(
                urlString: "https://is1-ssl.mzstatic.com/image/thumb/Music/example.jpg/600x600bb.jpg",
                hasQueueMemoryImage: false,
                isKnownDiskCached: true
            )
        )
    }

    func testDoesNotLoadDiskCacheWhenMemoryCacheAlreadyHasImage() {
        XCTAssertFalse(
            QueueArtworkLoadPolicy.shouldLoadQueueDiskCacheAsync(
                urlString: "https://is1-ssl.mzstatic.com/image/thumb/Music/example.jpg/600x600bb.jpg",
                hasQueueMemoryImage: true,
                isKnownDiskCached: true
            )
        )
    }

    func testDoesNotLoadDiskCacheForMissingURL() {
        XCTAssertFalse(
            QueueArtworkLoadPolicy.shouldLoadQueueDiskCacheAsync(
                urlString: nil,
                hasQueueMemoryImage: false,
                isKnownDiskCached: true
            )
        )
    }

    func testAttemptsPlaybackArtworkResolutionForAppleMusicSonosArtworkURL() {
        XCTAssertTrue(
            QueueArtworkLoadPolicy.shouldAttemptPlaybackArtworkResolution(
                urlString: "http://192.168.50.249:1400/getaa?s=1&u=x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
                isAppleMusicQueueItem: true
            )
        )
    }

    func testDoesNotAttemptPlaybackArtworkResolutionForNonAppleMusicQueueItem() {
        XCTAssertFalse(
            QueueArtworkLoadPolicy.shouldAttemptPlaybackArtworkResolution(
                urlString: "http://192.168.50.249:1400/getaa?s=1&u=x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
                isAppleMusicQueueItem: false
            )
        )
    }

    func testDefersSonosRemoteArtworkLoadUntilPlaybackArtworkResolutionMisses() {
        let urlString = "http://192.168.50.249:1400/getaa?s=1&u=x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2"

        XCTAssertFalse(
            QueueArtworkLoadPolicy.shouldLoadRemoteArtwork(
                urlString: urlString,
                isAppleMusicQueueItem: true,
                didMissPlaybackArtworkResolution: false
            )
        )
        XCTAssertTrue(
            QueueArtworkLoadPolicy.shouldLoadRemoteArtwork(
                urlString: urlString,
                isAppleMusicQueueItem: true,
                didMissPlaybackArtworkResolution: true
            )
        )
    }

    func testLoadsPublicAppleArtworkWithoutWaitingForResolution() {
        XCTAssertTrue(
            QueueArtworkLoadPolicy.shouldLoadRemoteArtwork(
                urlString: "https://is1-ssl.mzstatic.com/image/thumb/Music/example.jpg/600x600bb.jpg",
                isAppleMusicQueueItem: true,
                didMissPlaybackArtworkResolution: false
            )
        )
    }
}
