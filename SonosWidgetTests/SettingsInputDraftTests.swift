import XCTest
@testable import SonosWidget

final class SettingsInputDraftTests: XCTestCase {
    func testCommitFocusedRelayFieldSavesRelayDraftAndClearsFocus() {
        let drafts = SettingsInputDrafts(
            relayURL: " http://192.168.50.10:8787 "
        )
        var savedRelayURL: String?

        let nextFocus = drafts.commit(
            focusedField: .relayURL,
            relayURL: { savedRelayURL = $0 }
        )

        XCTAssertNil(nextFocus)
        XCTAssertEqual(savedRelayURL, " http://192.168.50.10:8787 ")
    }
}

final class MiniPlayerLayoutMetricsTests: XCTestCase {
    func testLandscapeCompactMiniPlayerUsesShortCapsuleWidth() {
        XCTAssertEqual(
            MiniPlayerLayoutMetrics.maxWidth(isLandscapeCompact: true),
            620
        )
    }

    func testNonLandscapeCompactMiniPlayerKeepsFullWidth() {
        XCTAssertNil(MiniPlayerLayoutMetrics.maxWidth(isLandscapeCompact: false))
    }

    func testHomeActionsClearSystemAccessoryMiniPlayer() {
        XCTAssertEqual(
            MiniPlayerLayoutMetrics.homeActionBottomPadding(
                isMiniPlayerVisible: true,
                usesSystemAccessory: true
            ),
            66
        )
    }

    func testHomeActionsKeepCompactPaddingWhenMiniPlayerIsAlreadyInset() {
        XCTAssertEqual(
            MiniPlayerLayoutMetrics.homeActionBottomPadding(
                isMiniPlayerVisible: true,
                usesSystemAccessory: false
            ),
            16
        )
    }

    func testHomeActionsKeepCompactPaddingWhenMiniPlayerIsHidden() {
        XCTAssertEqual(
            MiniPlayerLayoutMetrics.homeActionBottomPadding(
                isMiniPlayerVisible: false,
                usesSystemAccessory: true
            ),
            16
        )
    }
}

final class PlaybackControlPresentationTests: XCTestCase {
    func testLiveStreamPresentationUsesStopAndHidesTrackControls() {
        XCTAssertEqual(
            PlaybackControlPresentation.primarySystemImage(isPlaying: true, isLiveStream: true),
            "stop.fill"
        )
        XCTAssertEqual(
            PlaybackControlPresentation.primarySystemImage(isPlaying: false, isLiveStream: true),
            "play.fill"
        )
        XCTAssertFalse(PlaybackControlPresentation.showsNextButton(isLiveStream: true))
        XCTAssertFalse(PlaybackControlPresentation.showsProgressRing(isLiveStream: true))
    }

    func testStandardPresentationKeepsPauseNextAndProgressRing() {
        XCTAssertEqual(
            PlaybackControlPresentation.primarySystemImage(isPlaying: true, isLiveStream: false),
            "pause.fill"
        )
        XCTAssertEqual(
            PlaybackControlPresentation.primarySystemImage(isPlaying: false, isLiveStream: false),
            "play.fill"
        )
        XCTAssertTrue(PlaybackControlPresentation.showsNextButton(isLiveStream: false))
        XCTAssertTrue(PlaybackControlPresentation.showsProgressRing(isLiveStream: false))
    }
}
