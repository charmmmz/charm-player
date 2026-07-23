import Foundation
import UIKit

@MainActor
enum AnimatedArtworkFeature {
    static let isEnabled = true
    static let fullScreenBackgroundBottomEdgeOverscan: CGFloat = 2

    /// Sonos reports radio playback without a track duration, so Apple Music
    /// station songs are classified as live streams even when their current
    /// title, artist, and album identify a normal catalog track. Let those
    /// songs reach the existing metadata resolver while keeping ordinary
    /// radio and other durationless inputs out of the animated-artwork path.
    static func canBuildNowPlayingIdentity(
        source: PlaybackSource?,
        isLiveStream: Bool
    ) -> Bool {
        !isLiveStream || source == .appleMusic
    }

    static func canRenderVideo(
        source: PlaybackSource?,
        isReduceMotionEnabled: Bool? = nil,
        isLowPowerModeEnabled: Bool? = nil
    ) -> Bool {
        guard isEnabled else { return false }
        guard source == .appleMusic else { return false }
        guard !(isReduceMotionEnabled ?? UIAccessibility.isReduceMotionEnabled) else { return false }
        guard !(isLowPowerModeEnabled ?? ProcessInfo.processInfo.isLowPowerModeEnabled) else { return false }
        return true
    }

    static func canRenderFullScreenTallArtwork(
        source: PlaybackSource?,
        hasTallArtwork: Bool,
        isCompactHeight: Bool,
        isReduceMotionEnabled: Bool? = nil,
        isLowPowerModeEnabled: Bool? = nil
    ) -> Bool {
        guard hasTallArtwork else { return false }
        guard !isCompactHeight else { return false }
        return canRenderVideo(
            source: source,
            isReduceMotionEnabled: isReduceMotionEnabled,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        )
    }

    static func shouldUseBlurFillForFullScreenArtwork(
        videoAspectRatio: CGFloat?,
        containerAspectRatio: CGFloat,
        tolerance: CGFloat = 0.18
    ) -> Bool {
        guard containerAspectRatio > 0 else { return true }
        guard let videoAspectRatio, videoAspectRatio > 0 else { return true }
        return videoAspectRatio > containerAspectRatio * (1 + tolerance)
    }

    static func fullScreenBlurFillForegroundSize(
        containerSize: CGSize,
        videoAspectRatio: CGFloat?
    ) -> CGSize {
        let containerWidth = max(0, containerSize.width)
        let containerHeight = max(0, containerSize.height)
        guard containerWidth > 0, containerHeight > 0 else { return .zero }

        let aspectRatio = resolvedFullScreenArtworkAspectRatio(videoAspectRatio)
        let width = containerWidth
        let height = min(containerHeight, width / aspectRatio)
        return CGSize(width: width, height: height)
    }

    static func fullScreenBlurFillForegroundTopOffset(containerSize: CGSize) -> CGFloat {
        0
    }

    static func fullScreenExtensionBackdropSize(containerSize: CGSize) -> CGSize {
        CGSize(
            width: max(0, containerSize.width),
            height: max(0, containerSize.height)
        )
    }

    static func shouldUseVideoBlurLayerForFullScreenExtension() -> Bool {
        false
    }

    static func fullScreenExtensionBackdropStartLocation(
        containerSize: CGSize,
        videoAspectRatio: CGFloat?
    ) -> CGFloat {
        let containerHeight = max(0, containerSize.height)
        guard containerHeight > 0 else { return 0 }

        let foregroundSize = fullScreenBlurFillForegroundSize(
            containerSize: containerSize,
            videoAspectRatio: videoAspectRatio
        )
        let foregroundBottom = fullScreenBlurFillForegroundTopOffset(containerSize: containerSize)
            + max(0, foregroundSize.height)
        let rawLocation = foregroundBottom / containerHeight - 0.10
        return min(0.62, max(0.46, rawLocation))
    }

    static func fullScreenBackgroundContainerSize(
        contentSize: CGSize,
        topSafeAreaInset: CGFloat = 0,
        bottomSafeAreaInset: CGFloat
    ) -> CGSize {
        let expandedHeight = max(0, contentSize.height)
            + max(0, topSafeAreaInset)
            + max(0, bottomSafeAreaInset)
        let bottomOverscan = expandedHeight > 0 ? fullScreenBackgroundBottomEdgeOverscan : 0

        return CGSize(
            width: max(0, contentSize.width),
            height: expandedHeight + bottomOverscan
        )
    }

    static func fullScreenBackgroundTopOffset(topSafeAreaInset: CGFloat) -> CGFloat {
        -max(0, topSafeAreaInset)
    }

    static func fullScreenSourceBadgeTopPadding(
        foregroundSize: CGSize,
        foregroundTopOffset: CGFloat,
        controlsTopPadding: CGFloat,
        badgeHeight: CGFloat = 16,
        foregroundBottomPadding: CGFloat = 14,
        contentGap: CGFloat = 12,
        minimumTopPadding: CGFloat = 12
    ) -> CGFloat {
        let foregroundBottom = max(0, foregroundTopOffset + max(0, foregroundSize.height))
        let preferredTop = foregroundBottom - max(0, foregroundBottomPadding) - max(0, badgeHeight)
        let maxTopBeforeContent = max(0, controlsTopPadding) - max(0, contentGap) - max(0, badgeHeight)

        return max(
            max(0, minimumTopPadding),
            min(preferredTop, maxTopBeforeContent)
        )
    }

    private static func resolvedFullScreenArtworkAspectRatio(_ videoAspectRatio: CGFloat?) -> CGFloat {
        guard let videoAspectRatio, videoAspectRatio > 0 else { return 0.75 }
        return max(0.35, videoAspectRatio)
    }
}
