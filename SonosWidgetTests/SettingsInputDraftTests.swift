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

    func testSystemAccessoryContentInsetClearsMiniPlayerHeightAndGap() {
        XCTAssertEqual(
            MiniPlayerLayoutMetrics.systemAccessoryContentBottomInset(
                isMiniPlayerVisible: true
            ),
            52
        )
    }

    func testSystemAccessoryContentInsetCollapsesWhenMiniPlayerIsHidden() {
        XCTAssertEqual(
            MiniPlayerLayoutMetrics.systemAccessoryContentBottomInset(
                isMiniPlayerVisible: false
            ),
            0
        )
    }

    func testHomeActionTrayOnlyAppearsWhileDraggingSpeakerGroup() {
        XCTAssertTrue(
            HomeActionTrayPresentation.isVisible(isSpeakerGroupDragActive: true)
        )
        XCTAssertFalse(
            HomeActionTrayPresentation.isVisible(isSpeakerGroupDragActive: false)
        )
    }

    func testHomeActionTrayAppearsWhenDragSourceStartsBeforePreviewLifecycle() {
        XCTAssertTrue(
            HomeActionTrayPresentation.isVisible(
                hasActiveDragSource: true,
                isDragPreviewVisible: false
            )
        )
        XCTAssertFalse(
            HomeActionTrayPresentation.isVisible(
                hasActiveDragSource: false,
                isDragPreviewVisible: false
            )
        )
    }

    func testHomeActionTrayMountsAsOverlayWithoutChangingScrollSafeArea() {
        XCTAssertEqual(
            HomeActionTrayPresentation.mountMode,
            .overlay
        )
    }

    func testSettingsDetailContentInsetClearsSystemAccessoryMiniPlayer() {
        XCTAssertEqual(
            SettingsDetailFormLayout.bottomContentInset(
                isMiniPlayerVisible: true,
                usesSystemAccessory: true
            ),
            52
        )
    }

    func testSettingsDetailContentInsetIsZeroForLegacyMiniPlayerPath() {
        XCTAssertEqual(
            SettingsDetailFormLayout.bottomContentInset(
                isMiniPlayerVisible: true,
                usesSystemAccessory: false
            ),
            0
        )
    }
}

final class NowPlayingOverlayPresentationTests: XCTestCase {
    func testFullPlayerCardDisablesRootCardCornerRadiusForDragPerformanceProbe() {
        XCTAssertEqual(NowPlayingOverlayPresentation.restingTopCornerRadius, 0)
        XCTAssertEqual(NowPlayingOverlayPresentation.maximumBottomCornerRadius, 0)
        XCTAssertEqual(NowPlayingOverlayPresentation.topCornerRadius(forDragOffset: 0), 0)
        XCTAssertEqual(NowPlayingOverlayPresentation.topCornerRadius(forDragOffset: 120), 0)
        XCTAssertEqual(NowPlayingOverlayPresentation.bottomCornerRadius(forDragOffset: 0), 0)
        XCTAssertEqual(NowPlayingOverlayPresentation.bottomCornerRadius(forDragOffset: 120), 0)
    }

    func testBottomActionsStayConnectedToFullPlayerBottomSafeArea() {
        XCTAssertEqual(
            NowPlayingOverlayPresentation.bottomActionsBottomPadding(bottomSafeAreaInset: 34),
            44
        )
        XCTAssertEqual(
            NowPlayingOverlayPresentation.bottomActionsBottomPadding(bottomSafeAreaInset: 0),
            22
        )
    }

    func testRestingFullPlayerClipUsesZeroRadiiForPerformanceProbe() {
        XCTAssertEqual(
            NowPlayingOverlayPresentation.clipCornerRadii(forDragOffset: 0),
            NowPlayingOverlayCornerRadii(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: 0
            )
        )
    }

    func testDraggedFullPlayerClipShapeKeepsZeroRadiiForPerformanceProbe() {
        XCTAssertEqual(
            NowPlayingOverlayPresentation.clipCornerRadii(forDragOffset: 10),
            NowPlayingOverlayCornerRadii(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: 0
            )
        )
        XCTAssertEqual(
            NowPlayingOverlayPresentation.clipCornerRadii(forDragOffset: 80),
            NowPlayingOverlayCornerRadii(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: 0
            )
        )
    }
}

final class MiniPlayerMountPolicyTests: XCTestCase {
    func testKeepsMiniPlayerMountedWhileFullPlayerIsVisible() {
        XCTAssertTrue(
            MiniPlayerMountPolicy.shouldMount(
                isConfigured: true,
                isKeyboardVisible: false
            )
        )
        XCTAssertFalse(
            MiniPlayerMountPolicy.isVisible(
                isConfigured: true,
                isFullPlayerVisible: true,
                isKeyboardVisible: false
            )
        )
    }

    func testMiniPlayerUnmountsWhenKeyboardIsVisible() {
        XCTAssertFalse(
            MiniPlayerMountPolicy.shouldMount(
                isConfigured: true,
                isKeyboardVisible: true
            )
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
