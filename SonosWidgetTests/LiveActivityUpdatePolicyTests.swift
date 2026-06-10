import XCTest
@testable import SonosWidget

final class LiveActivityUpdatePolicyTests: XCTestCase {
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

    func testNasOwnsRelayActivityAfterTokenRegistrationSucceeds() {
        XCTAssertFalse(
            SonosManager.shouldPerformLocalLiveActivityUpdate(
                usesRelay: true,
                relayWriterReady: true
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
}
