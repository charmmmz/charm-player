import AVFoundation
import SwiftUI
import XCTest
@testable import SonosWidget

@MainActor
final class AnimatedArtworkPlayerViewTests: XCTestCase {
    func testLayerViewConfiguresMutedLoopingPlayerForURL() {
        let view = AnimatedArtworkPlayerLayerView()
        let url = URL(string: "https://video.example.com/square.m3u8")!

        view.configure(url: url, videoGravity: .resizeAspectFill, onReadyForDisplay: {})

        XCTAssertEqual(view.configuredURL, url)
        XCTAssertNotNil(view.player)
        XCTAssertEqual(view.player?.isMuted, true)
        XCTAssertEqual(view.player?.actionAtItemEnd, AVPlayer.ActionAtItemEnd.none)
        XCTAssertTrue(view.playerLayer.videoGravity == .resizeAspectFill)
    }

    func testMutedVideoPlaybackAudioSessionAllowsExternalAudioToContinue() {
        let configuration = AnimatedArtworkAudioSessionPolicy.mutedVideoPlaybackConfiguration

        XCTAssertEqual(configuration.category, .ambient)
        XCTAssertTrue(configuration.options.contains(.mixWithOthers))
    }

    func testNowPlayingAnimatedArtworkOnlyPlaysWhenFullPlayerIsVisible() {
        XCTAssertFalse(
            NowPlayingAnimatedArtworkPlaybackPolicy.shouldPlay(isFullPlayerVisible: false)
        )
        XCTAssertTrue(
            NowPlayingAnimatedArtworkPlaybackPolicy.shouldPlay(isFullPlayerVisible: true)
        )
    }

    func testLayerViewKeepsPlayerWhenURLIsUnchanged() {
        let view = AnimatedArtworkPlayerLayerView()
        let url = URL(string: "https://video.example.com/square.m3u8")!

        view.configure(url: url, videoGravity: .resizeAspectFill, onReadyForDisplay: {})
        let firstPlayer = view.player
        view.configure(url: url, videoGravity: .resizeAspectFill, onReadyForDisplay: {})

        XCTAssertTrue(view.player === firstPlayer)
    }

    func testLayerViewUpdatesVideoGravityWithoutReplacingPlayer() {
        let view = AnimatedArtworkPlayerLayerView()
        let url = URL(string: "https://video.example.com/tall.m3u8")!

        view.configure(url: url, videoGravity: .resizeAspectFill, onReadyForDisplay: {})
        let firstPlayer = view.player
        view.configure(url: url, videoGravity: .resizeAspect, onReadyForDisplay: {})

        XCTAssertTrue(view.player === firstPlayer)
        XCTAssertTrue(view.playerLayer.videoGravity == .resizeAspect)
    }

    func testFullScreenTallArtworkRequiresAppleMusicTallVideoAndRegularHeight() {
        XCTAssertTrue(AnimatedArtworkFeature.canRenderFullScreenTallArtwork(
            source: .appleMusic,
            hasTallArtwork: true,
            isCompactHeight: false,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        ))

        XCTAssertFalse(AnimatedArtworkFeature.canRenderFullScreenTallArtwork(
            source: .appleMusic,
            hasTallArtwork: false,
            isCompactHeight: false,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(AnimatedArtworkFeature.canRenderFullScreenTallArtwork(
            source: .tv,
            hasTallArtwork: true,
            isCompactHeight: false,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(AnimatedArtworkFeature.canRenderFullScreenTallArtwork(
            source: .appleMusic,
            hasTallArtwork: true,
            isCompactHeight: true,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(AnimatedArtworkFeature.canRenderFullScreenTallArtwork(
            source: .appleMusic,
            hasTallArtwork: true,
            isCompactHeight: false,
            isReduceMotionEnabled: true,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(AnimatedArtworkFeature.canRenderFullScreenTallArtwork(
            source: .appleMusic,
            hasTallArtwork: true,
            isCompactHeight: false,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: true
        ))
    }

    func testFullScreenArtworkUsesBlurFillWhenTallVideoIsWiderThanPhoneScreen() {
        XCTAssertTrue(AnimatedArtworkFeature.shouldUseBlurFillForFullScreenArtwork(
            videoAspectRatio: 0.75,
            containerAspectRatio: 390 / 852
        ))

        XCTAssertFalse(AnimatedArtworkFeature.shouldUseBlurFillForFullScreenArtwork(
            videoAspectRatio: 390 / 852,
            containerAspectRatio: 390 / 852
        ))

        XCTAssertTrue(AnimatedArtworkFeature.shouldUseBlurFillForFullScreenArtwork(
            videoAspectRatio: nil,
            containerAspectRatio: 390 / 852
        ))
    }

    func testBlurFillForegroundUsesFullWidthHeroArtworkWithoutTopOverscan() {
        let size = AnimatedArtworkFeature.fullScreenBlurFillForegroundSize(
            containerSize: CGSize(width: 390, height: 852),
            videoAspectRatio: 0.75
        )
        let topOffset = AnimatedArtworkFeature.fullScreenBlurFillForegroundTopOffset(
            containerSize: CGSize(width: 390, height: 852)
        )

        XCTAssertEqual(size.width, 390, accuracy: 0.5)
        XCTAssertEqual(size.height, 520, accuracy: 0.5)
        XCTAssertEqual(topOffset, 0, accuracy: 0.5)
    }

    func testFullScreenExtensionBackdropCoversWholeSafeAreaExpandedContainer() {
        let size = AnimatedArtworkFeature.fullScreenExtensionBackdropSize(
            containerSize: CGSize(width: 402, height: 908)
        )

        XCTAssertEqual(size.width, 402, accuracy: 0.5)
        XCTAssertEqual(size.height, 908, accuracy: 0.5)
    }

    func testFullScreenExtensionBackdropDoesNotReuseVideoBlurLayer() {
        XCTAssertFalse(AnimatedArtworkFeature.shouldUseVideoBlurLayerForFullScreenExtension())
    }

    func testFullScreenExtensionBackdropStartsNearHeroArtworkBottom() {
        let start = AnimatedArtworkFeature.fullScreenExtensionBackdropStartLocation(
            containerSize: CGSize(width: 390, height: 852),
            videoAspectRatio: 0.75
        )

        XCTAssertEqual(start, 0.51, accuracy: 0.02)
        XCTAssertGreaterThan(start, 0.45)
        XCTAssertLessThan(start, 0.65)
    }

    func testFullScreenBackgroundExtendsBelowSafeAreaWithoutBecomingSquare() {
        let backgroundSize = AnimatedArtworkFeature.fullScreenBackgroundContainerSize(
            contentSize: CGSize(width: 390, height: 774),
            topSafeAreaInset: 0,
            bottomSafeAreaInset: 34
        )
        let foregroundSize = AnimatedArtworkFeature.fullScreenBlurFillForegroundSize(
            containerSize: backgroundSize,
            videoAspectRatio: nil
        )

        XCTAssertEqual(backgroundSize.width, 390, accuracy: 0.5)
        XCTAssertEqual(backgroundSize.height, 810, accuracy: 0.5)
        XCTAssertEqual(foregroundSize.width, 390, accuracy: 0.5)
        XCTAssertEqual(foregroundSize.height, 520, accuracy: 0.5)
    }

    func testFullScreenBackgroundExtendsAboveTopSafeAreaWithoutMovingControls() {
        let backgroundSize = AnimatedArtworkFeature.fullScreenBackgroundContainerSize(
            contentSize: CGSize(width: 402, height: 813),
            topSafeAreaInset: 62,
            bottomSafeAreaInset: 34
        )
        let topOffset = AnimatedArtworkFeature.fullScreenBackgroundTopOffset(
            topSafeAreaInset: 62
        )

        XCTAssertEqual(backgroundSize.width, 402, accuracy: 0.5)
        XCTAssertEqual(backgroundSize.height, 911, accuracy: 0.5)
        XCTAssertEqual(topOffset, -62, accuracy: 0.5)
    }

    func testFullScreenBackgroundAddsBottomEdgeOverscan() {
        let backgroundSize = AnimatedArtworkFeature.fullScreenBackgroundContainerSize(
            contentSize: CGSize(width: 402, height: 774),
            topSafeAreaInset: 0,
            bottomSafeAreaInset: 34
        )

        XCTAssertEqual(
            backgroundSize.height,
            810,
            accuracy: 0.5
        )
    }

    func testFullScreenSourceBadgeStaysAboveTrackInfoWhenForegroundExtendsBehindIt() {
        let backgroundSize = AnimatedArtworkFeature.fullScreenBackgroundContainerSize(
            contentSize: CGSize(width: 390, height: 774),
            topSafeAreaInset: 0,
            bottomSafeAreaInset: 34
        )
        let foregroundSize = AnimatedArtworkFeature.fullScreenBlurFillForegroundSize(
            containerSize: backgroundSize,
            videoAspectRatio: nil
        )
        let foregroundTopOffset = AnimatedArtworkFeature.fullScreenBlurFillForegroundTopOffset(
            containerSize: backgroundSize
        )
        let controlsTopPadding = max(300, 774 * 0.52)
        let topPadding = AnimatedArtworkFeature.fullScreenSourceBadgeTopPadding(
            foregroundSize: foregroundSize,
            foregroundTopOffset: foregroundTopOffset,
            controlsTopPadding: controlsTopPadding
        )

        XCTAssertLessThanOrEqual(topPadding + 16 + 12, controlsTopPadding + 0.5)
        XCTAssertLessThanOrEqual(
            topPadding + 16 + 14,
            foregroundTopOffset + foregroundSize.height + 0.5
        )
    }

    func testNowPlayingOverlayChromeIsFlushToHorizontalScreenEdgesWhenResting() {
        XCTAssertEqual(NowPlayingOverlayPresentation.horizontalPadding, 0)
        XCTAssertGreaterThanOrEqual(NowPlayingOverlayPresentation.topPadding, 0)
        XCTAssertEqual(
            NowPlayingOverlayPresentation.cornerRadius(forDragOffset: 0),
            0
        )
    }

    func testNowPlayingOverlayDisablesTopCardRadiusWhenRestingAndDraggingDown() {
        XCTAssertEqual(
            NowPlayingOverlayPresentation.topCornerRadius(forDragOffset: -20),
            0
        )
        XCTAssertEqual(
            NowPlayingOverlayPresentation.topCornerRadius(forDragOffset: 10),
            0
        )
        XCTAssertEqual(NowPlayingOverlayPresentation.topCornerRadius(forDragOffset: 80), 0)
    }

    func testNowPlayingOverlayUsesZeroClipRadiiWhileDraggingDown() {
        let radii = NowPlayingOverlayPresentation.clipCornerRadii(forDragOffset: 10)

        XCTAssertEqual(radii.topLeading, 0)
        XCTAssertEqual(radii.topTrailing, 0)
        XCTAssertEqual(radii.bottomLeading, 0)
        XCTAssertEqual(radii.bottomTrailing, 0)
    }

    func testNowPlayingDragHandleStaysAtCardTop() {
        XCTAssertEqual(
            NowPlayingOverlayPresentation.dragHandleTopPadding(topSafeAreaInset: 59),
            NowPlayingOverlayPresentation.dragHandleTopMargin,
            accuracy: 0.5
        )
        XCTAssertEqual(
            NowPlayingOverlayPresentation.dragHandleTopPadding(topSafeAreaInset: 0),
            8,
            accuracy: 0.5
        )
    }

    func testNowPlayingOverlayKeepsDragOffsetDuringDragDismissal() {
        XCTAssertFalse(NowPlayingOverlayPresentation.shouldResetDragOffsetImmediately(
            isFullPlayerVisible: false,
            isDismissingFromDrag: true
        ))
        XCTAssertTrue(NowPlayingOverlayPresentation.shouldResetDragOffsetImmediately(
            isFullPlayerVisible: false,
            isDismissingFromDrag: false
        ))
        XCTAssertTrue(NowPlayingOverlayPresentation.shouldResetDragOffsetImmediately(
            isFullPlayerVisible: true,
            isDismissingFromDrag: true
        ))
    }

    func testNowPlayingOverlayHostIgnoresHorizontalAndBottomSafeAreaWhenFullPlayerIsVisible() {
        XCTAssertEqual(
            NowPlayingOverlayHostPresentation.ignoredSafeAreaEdges(isFullPlayerVisible: true),
            [.horizontal, .bottom]
        )
        XCTAssertEqual(
            NowPlayingOverlayHostPresentation.ignoredSafeAreaEdges(isFullPlayerVisible: false),
            .horizontal
        )
    }

    func testNowPlayingOverlayHostMountsOnTabViewOverlayLikePreviousImplementation() {
        XCTAssertEqual(
            String(describing: NowPlayingOverlayHostPresentation.mountTarget),
            "tabViewOverlay"
        )
    }

    func testNowPlayingOverlayHostOwnsDismissDragOffset() {
        XCTAssertEqual(
            NowPlayingOverlayHostPresentation.overlayOffset(
                screenHeight: 852,
                miniPlayerDragOffset: 0,
                isFullPlayerVisible: true,
                dismissDragOffset: 44
            ),
            44,
            accuracy: 0.5
        )
    }

    func testMiniPlayerInteractiveDragStateIsOwnedByPresentationLayer() throws {
        XCTAssertEqual(MiniPlayerDragPresentation.dragStateOwner, .presentationLayer)
        XCTAssertLessThanOrEqual(MiniPlayerDragPresentation.gestureMinimumDistance, 1)
        let dragOffset = try XCTUnwrap(MiniPlayerDragPresentation.offset(forTranslationHeight: -80))
        XCTAssertEqual(dragOffset, -44, accuracy: 0.5)
        XCTAssertNil(MiniPlayerDragPresentation.offset(forTranslationHeight: 12))
        XCTAssertTrue(MiniPlayerDragPresentation.shouldOpenFullPlayer(
            translationHeight: -20,
            predictedEndTranslationHeight: -240
        ))
        XCTAssertFalse(MiniPlayerDragPresentation.shouldOpenFullPlayer(
            translationHeight: -20,
            predictedEndTranslationHeight: -80
        ))
    }

    func testNowPlayingOverlayHostKeepsDismissDragOffsetWhileAnimatingOffscreen() {
        XCTAssertEqual(
            NowPlayingOverlayHostPresentation.overlayOffset(
                screenHeight: 852,
                miniPlayerDragOffset: 0,
                isFullPlayerVisible: false,
                dismissDragOffset: 120
            ),
            972,
            accuracy: 0.5
        )
    }

    func testNowPlayingOverlayHostExpandsSafeAreaAtGeometryLevel() {
        XCTAssertEqual(
            NowPlayingOverlayHostPresentation.safeAreaExpansionTarget,
            .hostGeometry
        )
    }

    func testNowPlayingDismissUsesSlideOnlyTransition() {
        XCTAssertEqual(
            NowPlayingOverlayHostPresentation.dismissTransition,
            .slideOnly
        )
    }

    func testNowPlayingOverlayHostAddsBottomSafeAreaToRootCardFrame() {
        XCTAssertEqual(
            NowPlayingOverlayHostPresentation.cardSize(
                containerSize: CGSize(width: 402, height: 740),
                bottomSafeAreaInset: 34
            ),
            CGSize(width: 402, height: 844)
        )
    }

    func testNowPlayingOverlayHostAllowsInternalBackgroundBottomSafeAreaExpansion() {
        XCTAssertEqual(
            NowPlayingOverlayHostPresentation.cardSize(
                containerSize: CGSize(width: 402, height: 740),
                bottomSafeAreaInset: 34
            ).height,
            844,
            accuracy: 0.5
        )
    }

    func testNowPlayingOverlayHostKeepsBottomOverscanWhileRootClipIsRemoved() {
        XCTAssertEqual(NowPlayingOverlayHostPresentation.bottomEdgeOverscan, 36)
    }

    func testNowPlayingOverlayHostUsesUnclippedRootCardForDragPerformanceProbe() {
        XCTAssertEqual(
            String(describing: NowPlayingOverlayHostPresentation.rootCardCompositingMode),
            "unclipped"
        )
    }

    func testNowPlayingDismissGestureIsOwnedByRootCard() {
        XCTAssertEqual(
            NowPlayingOverlayHostPresentation.dismissGestureAttachment,
            .rootCard
        )
    }

    func testNowPlayingCardClippingIsDisabledForDragPerformanceProbe() {
        XCTAssertEqual(
            String(describing: NowPlayingOverlayHostPresentation.clipOwner),
            "none"
        )
    }

    func testNowPlayingInternalBackgroundDoesNotEscapeRootCard() {
        XCTAssertEqual(
            NowPlayingOverlayPresentation.backgroundSafeAreaMode,
            .clippedToRootCard
        )
    }

    func testNowPlayingBackgroundIgnoresSafeAreaInsideRootCard() {
        XCTAssertEqual(
            NowPlayingOverlayPresentation.backgroundIgnoredSafeAreaEdges,
            .all
        )
    }

    func testNowPlayingInternalBackgroundExtendsIntoBottomSafeArea() {
        XCTAssertEqual(
            NowPlayingOverlayPresentation.internalSafeAreaMode,
            .respectsTopSafeAreaExtendsBottom
        )
        XCTAssertEqual(
            NowPlayingOverlayPresentation.internalIgnoredSafeAreaEdges,
            .bottom
        )
    }

    func testFullScreenArtworkMountsInsideRootCardStack() {
        XCTAssertEqual(
            NowPlayingOverlayPresentation.fullScreenArtworkMount,
            .rootCardStack
        )
    }
}
