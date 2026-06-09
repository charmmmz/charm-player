import XCTest
@testable import SonosWidget

final class LiveActivityUpdatePolicyTests: XCTestCase {
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
