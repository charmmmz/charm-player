import XCTest
@testable import SonosWidget

final class AudioQualityRefreshTests: XCTestCase {
    func testLANRefreshKeepsLocallyConfirmedQualityWhenCloudCanEnhance() {
        let local = AudioQuality(codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2)
        let incoming = TrackInfo(
            title: "Bloom",
            artist: "Radiohead",
            album: "The King of Limbs",
            albumArtURL: "https://example.com/bloom.jpg",
            source: .appleMusic,
            audioQuality: local
        )

        let reconciled = SonosManager.reconciledLANTrackInfo(
            incoming,
            cachedCloudQuality: nil,
            cloudQualityIsAuthoritative: true
        )

        XCTAssertEqual(reconciled.audioQuality, local)
    }

    func testLANRefreshRestoresCachedCloudQualityBeforePublishingTrackInfo() {
        let cached = AudioQuality(codec: "ALAC", sampleRate: 44_100, bitDepth: 16, channels: nil)
        let incoming = TrackInfo(
            title: "Nocturne",
            artist: "Helios",
            album: "Eingya",
            albumArtURL: "https://example.com/nocturne.jpg",
            source: .appleMusic,
            audioQuality: nil
        )

        let reconciled = SonosManager.reconciledLANTrackInfo(
            incoming,
            cachedCloudQuality: (
                trackKey: SonosManager.cloudQualityTrackKey(for: incoming)!,
                quality: cached
            ),
            cloudQualityIsAuthoritative: true
        )

        XCTAssertEqual(reconciled.audioQuality, cached)
    }

    func testLANRefreshDoesNotReuseCachedCloudQualityForDifferentTrackWithSameTitle() {
        let cached = AudioQuality(codec: "ALAC", sampleRate: 44_100, bitDepth: 16, channels: nil)
        let incoming = TrackInfo(
            title: "Intro",
            artist: "Artist B",
            album: "Album B",
            albumArtURL: "https://example.com/b.jpg",
            source: .appleMusic,
            audioQuality: nil
        )

        let reconciled = SonosManager.reconciledLANTrackInfo(
            incoming,
            cachedCloudQuality: (
                trackKey: "Intro|Artist A|https://example.com/a.jpg",
                quality: cached
            ),
            cloudQualityIsAuthoritative: true
        )

        XCTAssertNil(reconciled.audioQuality)
    }

    func testLANRefreshAppliesLocalControlPlaybackQualityWithoutCloudLogin() throws {
        let incoming = TrackInfo(
            title: "Jet Lag",
            artist: "Simple Plan",
            album: "Get Your Heart On!",
            albumArtURL: "https://example.com/jet-lag.jpg",
            source: .appleMusic,
            audioQuality: nil
        )
        let json = """
        {
          "_objectType": "metadataStatus",
          "currentItem": {
            "track": {
              "name": "Jet Lag (feat. Natasha Bedingfield)",
              "artist": { "name": "Simple Plan" },
              "album": { "name": "Get Your Heart On! (Deluxe Version)" },
              "service": { "name": "Apple Music", "id": "204" },
              "quality": {
                "_objectType": "trackQuality",
                "bitDepth": 16,
                "sampleRate": 44100,
                "lossless": true,
                "immersive": false
              }
            }
          }
        }
        """.data(using: .utf8)!
        let metadata = try SonosLocalControlAPI.decodePlaybackMetadata(json)

        let enriched = SonosManager.trackInfo(incoming, applyingPlaybackMetadata: metadata)

        XCTAssertEqual(enriched.title, "Jet Lag (feat. Natasha Bedingfield)")
        XCTAssertEqual(enriched.source, .appleMusic)
        XCTAssertEqual(enriched.audioQuality?.label, "Lossless")
        XCTAssertEqual(enriched.audioQuality?.badgeAssetImageName, "BadgeAppleLossless")
    }

    func testPlaybackMetadataWithIncompleteQualityKeepsExistingAudioQuality() throws {
        let existing = AudioQuality(codec: "ALAC", sampleRate: 44_100, bitDepth: 16, channels: nil)
        let incoming = TrackInfo(
            title: "A Face to Call Home",
            artist: "John Mayer",
            album: "Born and Raised",
            albumArtURL: "https://example.com/born-and-raised.jpg",
            source: .appleMusic,
            audioQuality: existing
        )
        let json = """
        {
          "_objectType": "metadataStatus",
          "currentItem": {
            "track": {
              "name": "A Face to Call Home",
              "artist": { "name": "John Mayer" },
              "album": { "name": "Born and Raised" },
              "service": { "name": "Apple Music" },
              "quality": {
                "_objectType": "trackQuality",
                "bitDepth": 16,
                "sampleRate": 44100,
                "immersive": false
              }
            }
          }
        }
        """.data(using: .utf8)!
        let metadata = try SonosLocalControlAPI.decodePlaybackMetadata(json)

        XCTAssertTrue(SonosManager.playbackMetadataQualityNeedsRetry(metadata))

        let enriched = SonosManager.trackInfo(incoming, applyingPlaybackMetadata: metadata)

        XCTAssertEqual(enriched.audioQuality, existing)
    }

    func testPlaybackMetadataWithGenericTechnicalQualityNeedsBadgeRetry() throws {
        let json = """
        {
          "_objectType": "metadataStatus",
          "currentItem": {
            "track": {
              "name": "Tiao",
              "artist": { "name": "Yi" },
              "album": { "name": "Tiao - Single" },
              "service": { "name": "Apple Music" },
              "quality": {
                "_objectType": "trackQuality",
                "codec": "audio",
                "bitDepth": 16,
                "sampleRate": 48000,
                "lossless": false,
                "immersive": false
              }
            }
          }
        }
        """.data(using: .utf8)!
        let metadata = try SonosLocalControlAPI.decodePlaybackMetadata(json)

        XCTAssertTrue(SonosManager.playbackMetadataQualityNeedsRetry(metadata))
    }

    func testDelayedBadgeRetryOnlyNeededForTechnicalFallbackQuality() {
        let technical = AudioQuality(
            codec: "Audio",
            sampleRate: 48_000,
            bitDepth: 16,
            channels: nil,
            lossless: false,
            immersive: false
        )
        let lossless = AudioQuality(
            codec: "ALAC",
            sampleRate: 44_100,
            bitDepth: 16,
            channels: nil,
            lossless: true,
            immersive: false
        )

        XCTAssertTrue(SonosManager.audioQualityNeedsDelayedBadgeRetry(technical))
        XCTAssertFalse(SonosManager.audioQualityNeedsDelayedBadgeRetry(lossless))
    }

    func testPlaybackMetadataContainerFallbackEnrichesAppleMusicLiveStation() throws {
        let incoming = TrackInfo(
            title: "Unknown",
            artist: "Unknown",
            album: "",
            duration: "00:00:00",
            position: "00:00:00",
            source: .appleMusic
        )
        let json = """
        {
          "_objectType": "metadataStatus",
          "container": {
            "name": "Apple Music Chill",
            "type": "station",
            "imageUrl": "https://example.com/chill.jpg"
          }
        }
        """.data(using: .utf8)!
        let metadata = try SonosLocalControlAPI.decodePlaybackMetadata(json)

        let enriched = SonosManager.trackInfo(incoming, applyingPlaybackMetadata: metadata)

        XCTAssertEqual(enriched.title, "Apple Music Chill")
        XCTAssertEqual(enriched.artist, "Apple Music")
        XCTAssertEqual(enriched.albumArtURL, "https://example.com/chill.jpg")
        XCTAssertEqual(enriched.source, .appleMusic)
        XCTAssertTrue(enriched.isLiveStream)
    }

    func testLANTrackInfoUsesLocalControlMetadataForAppleMusicLiveStation() throws {
        let positionInfo = TrackInfo(
            title: "Unknown",
            artist: "Unknown",
            album: "",
            duration: "00:00:00",
            position: "00:00:00",
            source: .appleMusic
        )
        let json = """
        {
          "_objectType": "metadataStatus",
          "container": {
            "name": "Apple Music Chill",
            "type": "station",
            "imageUrl": "https://example.com/chill.jpg"
          }
        }
        """.data(using: .utf8)!
        let metadata = try SonosLocalControlAPI.decodePlaybackMetadata(json)

        let enriched = SonosManager.lanTrackInfo(
            positionInfo,
            localMetadata: metadata,
            cachedCloudQuality: nil,
            cloudQualityIsAuthoritative: false
        )

        XCTAssertEqual(enriched.title, "Apple Music Chill")
        XCTAssertEqual(enriched.artist, "Apple Music")
        XCTAssertEqual(enriched.albumArtURL, "https://example.com/chill.jpg")
        XCTAssertEqual(enriched.source, .appleMusic)
        XCTAssertTrue(enriched.isLiveStream)
    }
}
