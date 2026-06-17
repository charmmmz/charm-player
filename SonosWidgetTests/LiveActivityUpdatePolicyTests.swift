import XCTest
import UIKit
@testable import SonosWidget

final class LiveActivityUpdatePolicyTests: XCTestCase {
    @MainActor
    func testRefreshRequestGateCoalescesConcurrentRuns() async {
        let gate = RefreshRequestGate()
        let release = AsyncTestLatch()
        var runCount = 0

        async let first: Void = gate.run {
            runCount += 1
            await release.wait()
        }

        while runCount == 0 {
            await Task.yield()
        }

        async let second: Void = gate.run {
            runCount += 1
        }

        for _ in 0..<5 {
            await Task.yield()
        }

        XCTAssertEqual(runCount, 1)
        await release.open()
        await first
        await second
        XCTAssertEqual(runCount, 1)
    }

    func testWidgetTimelineRefreshPolicyUsesTrackEndWhenSoonerThanFallback() {
        let now = Date(timeIntervalSince1970: 1_000)

        let nextRefresh = WidgetTimelineRefreshPolicy.nextRefreshDate(
            now: now,
            isPlaying: true,
            positionSeconds: 170,
            durationSeconds: 180,
            fallbackInterval: 120
        )

        XCTAssertEqual(nextRefresh, now.addingTimeInterval(12))
    }

    func testWidgetTimelineRefreshPolicyFallsBackForPausedOrUnknownDuration() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            WidgetTimelineRefreshPolicy.nextRefreshDate(
                now: now,
                isPlaying: false,
                positionSeconds: 170,
                durationSeconds: 180,
                fallbackInterval: 120),
            now.addingTimeInterval(120)
        )
        XCTAssertEqual(
            WidgetTimelineRefreshPolicy.nextRefreshDate(
                now: now,
                isPlaying: true,
                positionSeconds: 0,
                durationSeconds: 0,
                fallbackInterval: 120),
            now.addingTimeInterval(120)
        )
    }

    func testCachedArtworkFetchPolicySkipsSameURLWhenDataExists() {
        XCTAssertFalse(
            CachedArtworkFetchPolicy.shouldFetch(
                incomingURLString: "http://speaker/getaa?s=1",
                cachedURLString: "http://speaker/getaa?s=1",
                hasCachedData: true)
        )
        XCTAssertTrue(
            CachedArtworkFetchPolicy.shouldFetch(
                incomingURLString: "http://speaker/getaa?s=1",
                cachedURLString: "http://speaker/getaa?s=1",
                hasCachedData: false)
        )
        XCTAssertTrue(
            CachedArtworkFetchPolicy.shouldFetch(
                incomingURLString: "http://speaker/getaa?s=2",
                cachedURLString: "http://speaker/getaa?s=1",
                hasCachedData: true)
        )
        XCTAssertFalse(
            CachedArtworkFetchPolicy.shouldFetch(
                incomingURLString: nil,
                cachedURLString: "http://speaker/getaa?s=1",
                hasCachedData: true)
        )
    }

    func testAutoRefreshUsesWatchdogCadenceWhenLANEventsAreSubscribed() {
        let plan = SonosManager.autoRefreshPlan(
            transportBackend: .lan,
            hasLANEventSubscriptions: true,
            cycle: 0
        )

        XCTAssertTrue(plan.refreshState)
        XCTAssertTrue(plan.refreshGroups)
        XCTAssertEqual(plan.sleepSeconds, 30)
    }

    func testAutoRefreshKeepsFastCadenceWhenLANEventsAreNotSubscribed() {
        let firstPlan = SonosManager.autoRefreshPlan(
            transportBackend: .lan,
            hasLANEventSubscriptions: false,
            cycle: 0
        )
        let secondPlan = SonosManager.autoRefreshPlan(
            transportBackend: .lan,
            hasLANEventSubscriptions: false,
            cycle: 1
        )

        XCTAssertTrue(firstPlan.refreshState)
        XCTAssertFalse(firstPlan.refreshGroups)
        XCTAssertEqual(firstPlan.sleepSeconds, 3)
        XCTAssertTrue(secondPlan.refreshState)
        XCTAssertTrue(secondPlan.refreshGroups)
        XCTAssertEqual(secondPlan.sleepSeconds, 3)
    }

    func testAutoRefreshKeepsCloudRefreshRateLimited() {
        let firstPlan = SonosManager.autoRefreshPlan(
            transportBackend: .cloud,
            hasLANEventSubscriptions: false,
            cycle: 0
        )
        let secondPlan = SonosManager.autoRefreshPlan(
            transportBackend: .cloud,
            hasLANEventSubscriptions: false,
            cycle: 1
        )

        XCTAssertTrue(firstPlan.refreshState)
        XCTAssertFalse(firstPlan.refreshGroups)
        XCTAssertEqual(firstPlan.sleepSeconds, 3)
        XCTAssertFalse(secondPlan.refreshState)
        XCTAssertTrue(secondPlan.refreshGroups)
        XCTAssertEqual(secondPlan.sleepSeconds, 3)
    }

    func testWidgetLiveActivityStyleUsesWidgetCardForMusicSources() {
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "Between the Bars",
            artist: "Elliott Smith",
            album: "Either/Or",
            isPlaying: true,
            positionSeconds: 42,
            durationSeconds: 180,
            playbackSourceRaw: PlaybackSource.appleMusic.rawValue,
            liveActivityStyleRaw: LiveActivityStyle.widget.rawValue
        )

        XCTAssertEqual(state.liveActivityStyle, .widget)
        XCTAssertEqual(state.resolvedLiveActivityPresentation, .widgetCard)
    }

    func testWidgetLiveActivityStyleUsesRemoteForTVSources() {
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "TV Audio",
            artist: "Dolby Atmos · MAT",
            album: "",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 0,
            playbackSourceRaw: PlaybackSource.tv.rawValue,
            liveActivityStyleRaw: LiveActivityStyle.widget.rawValue
        )

        XCTAssertEqual(state.liveActivityStyle, .widget)
        XCTAssertEqual(state.resolvedLiveActivityPresentation, .widgetTVRemote)
    }

    func testClassicLiveActivityStyleKeepsClassicPresentationForTVSources() {
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "TV Audio",
            artist: "Dolby Atmos · MAT",
            album: "",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 0,
            playbackSourceRaw: PlaybackSource.tv.rawValue,
            liveActivityStyleRaw: LiveActivityStyle.classic.rawValue
        )

        XCTAssertEqual(state.liveActivityStyle, .classic)
        XCTAssertEqual(state.resolvedLiveActivityPresentation, .classic)
    }

    func testLiveActivityStyleLabelsUseSimpleAndRichNames() {
        XCTAssertEqual(LiveActivityStyle.classic.displayName, "Simple")
        XCTAssertEqual(LiveActivityStyle.widget.displayName, "Rich")
    }

    func testLiveActivityStateCarriesAudioQualityLabel() {
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "Waiting On the World to Change",
            artist: "John Mayer",
            album: "Continuum",
            isPlaying: true,
            positionSeconds: 12,
            durationSeconds: 240,
            audioQualityLabel: "Dolby Atmos · MAT"
        )

        XCTAssertEqual(state.audioQualityLabel, "Dolby Atmos · MAT")
    }

    func testTVSourceLiveActivityStateCarriesSoundbarControls() {
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "TV",
            artist: "Live audio",
            album: "",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 0,
            playbackSourceRaw: PlaybackSource.tv.rawValue,
            soundbarNightMode: true,
            soundbarSpeechEnhancementRawLevel: SpeechEnhancementLevel.medium.rawValue
        )

        XCTAssertTrue(state.isTVSource)
        XCTAssertTrue(state.isLiveSource)
        XCTAssertEqual(state.soundbarSpeechEnhancementLevel, .medium)
        XCTAssertTrue(state.isSoundbarNightModeEnabled)
    }

    func testTVLiveActivityTitleReplacesPlaybackPlaceholder() {
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "Not Playing",
            artist: "Live audio",
            album: "",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 0,
            playbackSourceRaw: PlaybackSource.tv.rawValue
        )

        XCTAssertEqual(state.tvLiveActivityTitle, "TV Audio")
    }

    func testTVLiveActivitySubtitlePrefersAudioFormatLabel() {
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "TV",
            artist: "Live audio",
            album: "",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 0,
            playbackSourceRaw: PlaybackSource.tv.rawValue,
            audioQualityLabel: "Dolby Atmos · MAT"
        )

        XCTAssertEqual(state.tvLiveActivitySubtitle, "Dolby Atmos · MAT")
    }

    func testTVLiveActivityAppliesSoundbarControlUpdates() {
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "TV",
            artist: "Live audio",
            album: "",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 0,
            playbackSourceRaw: PlaybackSource.tv.rawValue,
            soundbarNightMode: false,
            soundbarSpeechEnhancementRawLevel: SpeechEnhancementLevel.off.rawValue
        )

        let updated = state.applyingSoundbarLiveActivityUpdate(
            nightMode: true,
            speechEnhancement: .medium
        )

        XCTAssertEqual(updated.soundbarNightMode, true)
        XCTAssertEqual(updated.soundbarSpeechEnhancementRawLevel, SpeechEnhancementLevel.medium.rawValue)
    }

    func testSoundbarControlUpdatesIgnoreNonTVLiveActivityState() {
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "Nude",
            artist: "Radiohead",
            album: "In Rainbows",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 255,
            playbackSourceRaw: PlaybackSource.appleMusic.rawValue,
            soundbarNightMode: false,
            soundbarSpeechEnhancementRawLevel: SpeechEnhancementLevel.off.rawValue
        )

        let updated = state.applyingSoundbarLiveActivityUpdate(
            nightMode: true,
            speechEnhancement: .medium
        )

        XCTAssertEqual(updated.soundbarNightMode, false)
        XCTAssertEqual(updated.soundbarSpeechEnhancementRawLevel, SpeechEnhancementLevel.off.rawValue)
    }

    func testAppKeepsUpdatingLocalLiveActivities() {
        XCTAssertTrue(
            SonosManager.shouldPerformLocalLiveActivityUpdate(
                usesRelay: false,
                relayWriterReady: false
            )
        )
    }

    func testAppTemporarilyUpdatesRelayActivityUntilTokenRegistrationSucceeds() {
        XCTAssertTrue(
            SonosManager.shouldPerformLocalLiveActivityUpdate(
                usesRelay: true,
                relayWriterReady: false
            )
        )
    }

    func testAppStopsLocalContentUpdatesAfterRelayTokenRegistrationSucceeds() {
        XCTAssertFalse(
            SonosManager.shouldPerformLocalLiveActivityUpdate(
                usesRelay: true,
                relayWriterReady: true
            )
        )
    }

    func testTVSoundbarCommandsUseRelayWhenRelayIsPrimaryWriter() {
        XCTAssertTrue(
            SonosManager.shouldSendSoundbarCommandThroughRelay(
                usesRelay: true,
                relayWriterReady: true
            )
        )

        XCTAssertFalse(
            SonosManager.shouldSendSoundbarCommandThroughRelay(
                usesRelay: true,
                relayWriterReady: false
            )
        )

        XCTAssertFalse(
            SonosManager.shouldSendSoundbarCommandThroughRelay(
                usesRelay: false,
                relayWriterReady: true
            )
        )
    }

    func testLiveActivityPlaybackStateCanBeReplacedFromFreshTrackInfo() throws {
        let oldState = SonosActivityAttributes.ContentState(
            trackTitle: "15 Step",
            artist: "Radiohead",
            album: "In Rainbows",
            isPlaying: true,
            positionSeconds: 180,
            durationSeconds: 237,
            dominantColorHex: "#FFE970",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endsAt: Date(timeIntervalSince1970: 1_057),
            albumArtThumbnail: Data([1, 2, 3]),
            groupMemberCount: 2,
            playbackSourceRaw: PlaybackSource.appleMusic.rawValue,
            liveActivityStyleRaw: LiveActivityStyle.widget.rawValue,
            audioQualityLabel: "Lossless"
        )
        let freshTrack = TrackInfo(
            title: "Nude",
            artist: "Radiohead",
            album: "In Rainbows",
            duration: "00:04:15",
            position: "00:00:11",
            source: .appleMusic,
            audioQuality: AudioQuality(
                codec: "lossless",
                sampleRate: 44_100,
                bitDepth: 16,
                channels: 2,
                lossless: true
            )
        )
        let now = Date(timeIntervalSince1970: 2_000)

        let updated = LiveActivityPlaybackStateBuilder.replacing(
            oldState,
            with: freshTrack,
            isPlaying: true,
            now: now,
            dominantColorHex: "#123456",
            liveActivityStyleRaw: LiveActivityStyle.widget.rawValue
        )

        XCTAssertEqual(updated.trackTitle, "Nude")
        XCTAssertEqual(updated.artist, "Radiohead")
        XCTAssertEqual(updated.album, "In Rainbows")
        XCTAssertEqual(updated.positionSeconds, 11)
        XCTAssertEqual(updated.durationSeconds, 255)
        XCTAssertEqual(updated.dominantColorHex, "#123456")
        XCTAssertNil(updated.albumArtThumbnail)
        XCTAssertEqual(updated.groupMemberCount, 2)
        XCTAssertEqual(updated.playbackSourceRaw, PlaybackSource.appleMusic.rawValue)
        XCTAssertEqual(updated.audioQualityLabel, "Lossless")
        XCTAssertEqual(updated.startedAt, now.addingTimeInterval(-11))
        XCTAssertEqual(updated.endsAt, now.addingTimeInterval(244))
    }

    func testKeepsExistingLiveActivityDuringWidgetTrackSkipLock() {
        let now = Date()

        XCTAssertTrue(
            SonosManager.shouldKeepLiveActivity(
                isPlaying: false,
                transportState: .stopped,
                currentActivityExists: true,
                playStateLockUntil: now.addingTimeInterval(5),
                now: now
            )
        )
    }

    func testDoesNotCreateLiveActivityForStoppedStateBecauseOfExpiredTrackSkipLock() {
        let now = Date()

        XCTAssertFalse(
            SonosManager.shouldKeepLiveActivity(
                isPlaying: false,
                transportState: .stopped,
                currentActivityExists: false,
                playStateLockUntil: now.addingTimeInterval(-1),
                now: now
            )
        )
    }

    func testSkipsLiveActivityContentUpdateDuringWidgetTrackSkipLock() {
        let now = Date()

        XCTAssertTrue(
            SonosManager.shouldSkipLiveActivityContentUpdateDuringPlayStateLock(
                isPlaying: false,
                transportState: .stopped,
                playStateLockUntil: now.addingTimeInterval(5),
                now: now
            )
        )
    }

    func testRecreatesLiveActivityWhenSelectedSpeakerGroupChanges() {
        XCTAssertTrue(
            SonosManager.shouldRecreateLiveActivityForSpeakerChange(
                currentActivityExists: true,
                previousGroupId: "192.168.50.25",
                nextGroupId: "192.168.50.30"
            )
        )
    }

    func testKeepsLiveActivityWhenSelectedSpeakerGroupIsUnchanged() {
        XCTAssertFalse(
            SonosManager.shouldRecreateLiveActivityForSpeakerChange(
                currentActivityExists: true,
                previousGroupId: "192.168.50.25",
                nextGroupId: "192.168.50.25"
            )
        )
    }

    func testDoesNotRecreateMissingLiveActivityForSpeakerChange() {
        XCTAssertFalse(
            SonosManager.shouldRecreateLiveActivityForSpeakerChange(
                currentActivityExists: false,
                previousGroupId: "192.168.50.25",
                nextGroupId: "192.168.50.30"
            )
        )
    }

    func testLiveActivityArtworkThumbnailKeepsSimpleArtworkUnderPayloadBudget() throws {
        let image = Self.makeSolidImage(color: .systemBlue)

        let thumbnail = try XCTUnwrap(LiveActivityArtworkThumbnail.make(from: image))

        XCTAssertLessThanOrEqual(thumbnail.count, LiveActivityArtworkThumbnail.maxBytes)
    }

    func testLiveActivityArtworkThumbnailNeverReturnsOversizedBusyArtwork() {
        let image = Self.makeBusyArtwork()

        let thumbnail = LiveActivityArtworkThumbnail.make(from: image)

        XCTAssertLessThanOrEqual(thumbnail?.count ?? 0, LiveActivityArtworkThumbnail.maxBytes)
    }

    func testLiveActivityArtworkPrefersMatchingCachedArtworkOverPayloadThumbnail() {
        let payloadThumbnail = Data([1, 2, 3])
        let cachedArtwork = Data([4, 5, 6])
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "15 Step",
            artist: "Radiohead",
            album: "In Rainbows",
            isPlaying: true,
            positionSeconds: 5,
            durationSeconds: 237,
            albumArtThumbnail: payloadThumbnail,
            playbackSourceRaw: PlaybackSource.appleMusic.rawValue
        )

        let data = LiveActivityArtworkData.resolve(
            for: state,
            cachedTrackTitle: "15 Step",
            cachedArtist: "Radiohead",
            cachedAlbum: "In Rainbows",
            cachedPlaybackSourceRaw: PlaybackSource.appleMusic.rawValue,
            cachedArtworkData: cachedArtwork
        )

        XCTAssertEqual(data, cachedArtwork)
    }

    func testLiveActivityArtworkFallsBackToPayloadThumbnailWhenCachedArtworkIsForAnotherTrack() {
        let payloadThumbnail = Data([1, 2, 3])
        let cachedArtwork = Data([4, 5, 6])
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "15 Step",
            artist: "Radiohead",
            album: "In Rainbows",
            isPlaying: true,
            positionSeconds: 5,
            durationSeconds: 237,
            albumArtThumbnail: payloadThumbnail,
            playbackSourceRaw: PlaybackSource.appleMusic.rawValue
        )

        let data = LiveActivityArtworkData.resolve(
            for: state,
            cachedTrackTitle: "Videotape",
            cachedArtist: "Radiohead",
            cachedAlbum: "In Rainbows",
            cachedPlaybackSourceRaw: PlaybackSource.appleMusic.rawValue,
            cachedArtworkData: cachedArtwork
        )

        XCTAssertEqual(data, payloadThumbnail)
    }

    func testLiveActivityCompactArtworkPrefersPayloadThumbnailOverMatchingCachedArtwork() {
        let payloadThumbnail = Data([1, 2, 3])
        let cachedArtwork = Data([4, 5, 6])
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "Details In the Fabric",
            artist: "Jason Mraz",
            album: "We Sing. We Dance. We Steal Things.",
            isPlaying: true,
            positionSeconds: 5,
            durationSeconds: 237,
            albumArtThumbnail: payloadThumbnail,
            playbackSourceRaw: PlaybackSource.appleMusic.rawValue
        )

        let data = LiveActivityArtworkData.resolveCompact(
            for: state,
            cachedTrackTitle: "Details In the Fabric",
            cachedArtist: "Jason Mraz",
            cachedAlbum: "We Sing. We Dance. We Steal Things.",
            cachedPlaybackSourceRaw: PlaybackSource.appleMusic.rawValue,
            cachedArtworkData: cachedArtwork
        )

        XCTAssertEqual(data, payloadThumbnail)
    }

    func testLiveActivityCompactArtworkFallsBackToMatchingCachedArtworkWhenPayloadIsMissing() {
        let cachedArtwork = Data([4, 5, 6])
        let state = SonosActivityAttributes.ContentState(
            trackTitle: "Details In the Fabric",
            artist: "Jason Mraz",
            album: "We Sing. We Dance. We Steal Things.",
            isPlaying: true,
            positionSeconds: 5,
            durationSeconds: 237,
            albumArtThumbnail: nil,
            playbackSourceRaw: PlaybackSource.appleMusic.rawValue
        )

        let data = LiveActivityArtworkData.resolveCompact(
            for: state,
            cachedTrackTitle: "Details In the Fabric",
            cachedArtist: "Jason Mraz",
            cachedAlbum: "We Sing. We Dance. We Steal Things.",
            cachedPlaybackSourceRaw: PlaybackSource.appleMusic.rawValue,
            cachedArtworkData: cachedArtwork
        )

        XCTAssertEqual(data, cachedArtwork)
    }

    func testLiveActivityPlaybackLayoutMetricsStayStableAcrossPlayState() {
        let playing = SonosActivityAttributes.ContentState(
            trackTitle: "Music For a Sushi Restaurant",
            artist: "Harry Styles",
            album: "Harry's House",
            isPlaying: true,
            positionSeconds: 42,
            durationSeconds: 193,
            startedAt: Date(timeIntervalSince1970: 2_000),
            endsAt: Date(timeIntervalSince1970: 2_151),
            playbackSourceRaw: PlaybackSource.appleMusic.rawValue
        )
        var paused = playing
        paused.isPlaying = false
        paused.startedAt = nil
        paused.endsAt = nil

        XCTAssertEqual(
            LiveActivityLayoutMetrics.progressHeight(for: playing),
            LiveActivityLayoutMetrics.progressHeight(for: paused)
        )
        XCTAssertEqual(LiveActivityLayoutMetrics.progressHeight(for: playing), 12)
        XCTAssertEqual(
            LiveActivityLayoutMetrics.waveformWidth(barCount: 3),
            9,
            accuracy: 0.001
        )
        XCTAssertEqual(LiveActivityLayoutMetrics.transportButtonSlotWidth, 24)
        XCTAssertEqual(LiveActivityLayoutMetrics.regularTransportClusterWidth, 116)
    }

    private static func makeSolidImage(color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 240, height: 240)))
        }
    }

    private static func makeBusyArtwork() -> UIImage {
        let size = CGSize(width: 240, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            for y in stride(from: 0, to: Int(size.height), by: 4) {
                for x in stride(from: 0, to: Int(size.width), by: 4) {
                    let hue = CGFloat((x * 31 + y * 17) % 255) / 255
                    let saturation = CGFloat(65 + ((x + y) % 35)) / 100
                    let brightness = CGFloat(55 + ((x * y) % 45)) / 100
                    UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
    }
}

private actor AsyncTestLatch {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
