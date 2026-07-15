import AVFoundation
import SwiftUI
import UIKit

// MARK: - Mini Player Bar (persistent across tabs)

enum MiniPlayerLayoutMetrics {
    static let landscapeCompactMaxWidth: CGFloat = 620
    static let homeActionDefaultBottomPadding: CGFloat = 16
    static let systemAccessoryMiniPlayerHeight: CGFloat = 44
    static let systemAccessoryMiniPlayerBottomGap: CGFloat = 8
    static let homeActionMiniPlayerGap: CGFloat = 14
    static let homeActionSystemAccessoryBottomPadding =
        systemAccessoryMiniPlayerHeight
        + systemAccessoryMiniPlayerBottomGap
        + homeActionMiniPlayerGap

    static func maxWidth(isLandscapeCompact: Bool) -> CGFloat? {
        isLandscapeCompact ? landscapeCompactMaxWidth : nil
    }

    static func homeActionBottomPadding(
        isMiniPlayerVisible: Bool,
        usesSystemAccessory: Bool
    ) -> CGFloat {
        if isMiniPlayerVisible && usesSystemAccessory {
            homeActionSystemAccessoryBottomPadding
        } else {
            homeActionDefaultBottomPadding
        }
    }

    static func systemAccessoryContentBottomInset(isMiniPlayerVisible: Bool) -> CGFloat {
        isMiniPlayerVisible
            ? systemAccessoryMiniPlayerHeight + systemAccessoryMiniPlayerBottomGap
            : 0
    }
}

enum HomeActionTrayPresentation {
    enum MountMode: Equatable {
        case overlay
    }

    static let mountMode: MountMode = .overlay
    static let targetMinWidth: CGFloat = 136
    static let targetHeight: CGFloat = 52
    static let actionSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 0
    static let verticalPadding: CGFloat = 0

    static func isVisible(isSpeakerGroupDragActive: Bool) -> Bool {
        isSpeakerGroupDragActive
    }

    static func isVisible(
        hasActiveDragSource: Bool,
        isDragPreviewVisible: Bool
    ) -> Bool {
        hasActiveDragSource || isDragPreviewVisible
    }
}

enum MiniPlayerMountPolicy {
    static func shouldMount(
        isConfigured: Bool,
        isKeyboardVisible: Bool
    ) -> Bool {
        isConfigured && !isKeyboardVisible
    }

    static func isVisible(
        isConfigured: Bool,
        isFullPlayerVisible: Bool,
        isKeyboardVisible: Bool
    ) -> Bool {
        shouldMount(
            isConfigured: isConfigured,
            isKeyboardVisible: isKeyboardVisible
        ) && !isFullPlayerVisible
    }
}

nonisolated enum MiniPlayerDragStateOwner: Equatable {
    case presentationLayer
}

nonisolated enum MiniPlayerDragPresentation {
    static let dragStateOwner: MiniPlayerDragStateOwner = .presentationLayer
    static let gestureMinimumDistance: CGFloat = 1
    static let rubberBandFactor: CGFloat = 0.55
    static let openTranslationThreshold: CGFloat = -40
    static let openPredictedTranslationThreshold: CGFloat = -200

    static func offset(forTranslationHeight translationHeight: CGFloat) -> CGFloat? {
        translationHeight < 0 ? translationHeight * rubberBandFactor : nil
    }

    static func visualOffset(
        dragOffset: CGFloat,
        inSystemAccessory: Bool
    ) -> CGFloat {
        inSystemAccessory ? 0 : dragOffset
    }

    static func shouldOpenDuringDrag(
        inSystemAccessory: Bool,
        translationHeight: CGFloat,
        predictedEndTranslationHeight: CGFloat
    ) -> Bool {
        inSystemAccessory && shouldOpenFullPlayer(
            translationHeight: translationHeight,
            predictedEndTranslationHeight: predictedEndTranslationHeight
        )
    }

    static func shouldOpenFullPlayer(
        translationHeight: CGFloat,
        predictedEndTranslationHeight: CGFloat
    ) -> Bool {
        translationHeight < openTranslationThreshold
            || predictedEndTranslationHeight < openPredictedTranslationThreshold
    }
}

enum NowPlayingBackgroundPresentation {
    nonisolated static let usesSharedArtworkBackground = true
    nonisolated static let usesReflectedArtwork = false
    nonisolated static let sharedArtworkOverlayOpacity = 0.6
}

nonisolated enum NowPlayingAnimatedArtworkPlaybackPolicy {
    static func shouldPlay(isFullPlayerVisible: Bool) -> Bool {
        isFullPlayerVisible
    }
}

nonisolated struct NowPlayingOverlayCornerRadii: Equatable {
    let topLeading: CGFloat
    let bottomLeading: CGFloat
    let bottomTrailing: CGFloat
    let topTrailing: CGFloat

    var rectangleCornerRadii: RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: topLeading,
            bottomLeading: bottomLeading,
            bottomTrailing: bottomTrailing,
            topTrailing: topTrailing
        )
    }
}

nonisolated enum NowPlayingOverlayPresentation {
    enum BackgroundSafeAreaMode: Equatable {
        case clippedToRootCard
    }
    enum InternalSafeAreaMode: Equatable {
        case respectsTopSafeAreaExtendsBottom
    }
    enum FullScreenArtworkMount: Equatable {
        case rootCardStack
    }

    static let horizontalPadding: CGFloat = 0
    static let topPadding: CGFloat = 0
    static let restingCornerRadius: CGFloat = 0
    static let restingTopCornerRadius: CGFloat = 0
    static let maximumBottomCornerRadius: CGFloat = 0
    static let maximumDraggedCornerRadius: CGFloat = maximumBottomCornerRadius
    static let bottomActionsBottomMargin: CGFloat = 22
    static let bottomActionsHomeIndicatorGap: CGFloat = 10
    static let backgroundSafeAreaMode: BackgroundSafeAreaMode = .clippedToRootCard
    static let backgroundIgnoredSafeAreaEdges: Edge.Set = .all
    static let internalSafeAreaMode: InternalSafeAreaMode = .respectsTopSafeAreaExtendsBottom
    static let internalIgnoredSafeAreaEdges: Edge.Set = .bottom
    static let fullScreenArtworkMount: FullScreenArtworkMount = .rootCardStack

    static func cornerRadius(forDragOffset _: CGFloat) -> CGFloat {
        restingCornerRadius
    }

    static func topCornerRadius(forDragOffset _: CGFloat) -> CGFloat {
        restingTopCornerRadius
    }

    static func bottomCornerRadius(forDragOffset _: CGFloat) -> CGFloat {
        maximumBottomCornerRadius
    }

    static func clipCornerRadii(forDragOffset dragOffset: CGFloat) -> NowPlayingOverlayCornerRadii {
        let topRadius = topCornerRadius(forDragOffset: dragOffset)
        let bottomRadius = bottomCornerRadius(forDragOffset: dragOffset)

        return NowPlayingOverlayCornerRadii(
            topLeading: topRadius,
            bottomLeading: bottomRadius,
            bottomTrailing: bottomRadius,
            topTrailing: topRadius
        )
    }

    static func bottomActionsBottomPadding(bottomSafeAreaInset: CGFloat) -> CGFloat {
        max(bottomActionsBottomMargin, max(0, bottomSafeAreaInset) + bottomActionsHomeIndicatorGap)
    }

}

nonisolated enum PlaybackControlPresentation {
    static func primarySystemImage(isPlaying: Bool, isLiveStream: Bool) -> String {
        if isLiveStream {
            return isPlaying ? "stop.fill" : "play.fill"
        }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    static func primaryAccessibilityLabel(isPlaying: Bool, isLiveStream: Bool) -> String {
        if isLiveStream {
            return isPlaying ? "Stop Live Stream" : "Play Live Stream"
        }
        return isPlaying ? "Pause" : "Play"
    }

    static func showsNextButton(isLiveStream: Bool) -> Bool {
        !isLiveStream
    }

    static func showsProgressRing(isLiveStream: Bool) -> Bool {
        !isLiveStream
    }
}

/// Compact now-playing bar that lives at the bottom of the app and stays
/// visible on every tab (Home / Search / …) — tapping it opens the full
/// player; dragging up does the same with an interactive rubber-band.
///
/// Use the `.miniPlayerInset(manager:)` modifier on each tab's root view
/// to mount it above the tab bar with matching content padding.
struct MiniPlayerBar: View {
    @Bindable var manager: SonosManager
    @Binding var dragOffset: CGFloat
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// When mounted inside iOS 26's `tabViewBottomAccessory` slot the system
    /// provides its own liquid-glass capsule + horizontal inset, and renders
    /// the accessory *inline with the selected tab icon* once the user
    /// scrolls. In that case we must not apply our own material/insets or
    /// the double chrome looks wrong.
    var inSystemAccessory: Bool = false

    var body: some View {
        Button {
            openFullPlayer()
        } label: {
            HStack(spacing: 12) {
                let isTV = manager.trackInfo?.source == .tv
                let isLiveStream = manager.trackInfo?.isLiveStream == true
                let artSize: CGFloat = inSystemAccessory ? 32 : 44
                let cornerRadius: CGFloat = inSystemAccessory ? 6 : 8
                miniPlayerArtworkView(
                    isTV: isTV,
                    image: manager.albumArtImage,
                    size: artSize,
                    cornerRadius: cornerRadius
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(manager.trackInfo?.title ?? "Not Playing")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        // Only the unreachable warning remains inline — the
                        // cloud/remote affordance lives exclusively on the
                        // Home speakers list so the mini-player stays quiet
                        // in the common case.
                        if let glyph = backendMiniGlyph {
                            Image(systemName: glyph.name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(glyph.tint)
                                .accessibilityLabel(glyph.label)
                        }
                    }
                    Text(manager.trackInfo?.artist ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    Task { await manager.togglePlayPause() }
                } label: {
                    Image(systemName: PlaybackControlPresentation.primarySystemImage(
                        isPlaying: manager.isPlaying,
                        isLiveStream: isLiveStream
                    ))
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PlaybackControlPresentation.primaryAccessibilityLabel(
                    isPlaying: manager.isPlaying,
                    isLiveStream: isLiveStream
                ))

                if PlaybackControlPresentation.showsNextButton(isLiveStream: isLiveStream) {
                    Button {
                        Task { await manager.nextTrack() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, inSystemAccessory ? 12 : 16)
            .padding(.vertical, inSystemAccessory ? 6 : 10)
            .modifier(MiniPlayerWidthModifier(maxWidth: MiniPlayerLayoutMetrics.maxWidth(
                isLandscapeCompact: verticalSizeClass == .compact
            )))
            .modifier(MiniPlayerChromeModifier(useCustomChrome: !inSystemAccessory))
            // Make the ENTIRE bar hit-testable — without this, SwiftUI only
            // counts taps on the HStack's concrete subviews (art + text +
            // controls) and the `Spacer()` gap in the middle silently
            // swallows touches, so tapping the empty area between title and
            // the play button does nothing.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: MiniPlayerDragPresentation.visualOffset(
            dragOffset: dragOffset,
            inSystemAccessory: inSystemAccessory
        ))
        .simultaneousGesture(
            DragGesture(minimumDistance: MiniPlayerDragPresentation.gestureMinimumDistance)
                .onChanged { value in
                    if MiniPlayerDragPresentation.shouldOpenDuringDrag(
                        inSystemAccessory: inSystemAccessory,
                        translationHeight: value.translation.height,
                        predictedEndTranslationHeight: value.predictedEndTranslation.height
                    ) {
                        openFullPlayer()
                        return
                    }

                    if inSystemAccessory {
                        dragOffset = 0
                        return
                    }

                    if let offset = MiniPlayerDragPresentation.offset(
                        forTranslationHeight: value.translation.height
                    ) {
                        dragOffset = offset
                    }
                }
                .onEnded { value in
                    if MiniPlayerDragPresentation.shouldOpenFullPlayer(
                        translationHeight: value.translation.height,
                        predictedEndTranslationHeight: value.predictedEndTranslation.height
                    ) {
                        openFullPlayer()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

    private func openFullPlayer() {
        guard !manager.showFullPlayer else { return }
        dragOffset = 0
        manager.showFullPlayer = true
    }

    /// Mini-player only lights up when the speaker is genuinely unreachable
    /// (no LAN, no cloud). Cloud mode is signaled instead by the pill at the
    /// top-left of the Home speakers list so we don't stamp a glyph onto
    /// every track title while remote-controlling normally.
    private var backendMiniGlyph: (name: String, tint: Color, label: String)? {
        switch manager.transportBackend {
        case .unknown where manager.isConfigured:
            return ("wifi.exclamationmark", .orange, "Speaker unreachable")
        default:
            return nil
        }
    }

    @ViewBuilder
    private func miniPlayerArtworkView(
        isTV: Bool,
        image: UIImage?,
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        ZStack {
            if isTV {
                // TV input never has cover art — show a `tv` glyph instead
                // of the music note so the mini-player matches the home card.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary)
                Image(systemName: "tv")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary)
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

private struct MiniPlayerWidthModifier: ViewModifier {
    let maxWidth: CGFloat?

    func body(content: Content) -> some View {
        if let maxWidth {
            content.frame(maxWidth: maxWidth, alignment: .leading)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Chrome wrapper for `MiniPlayerBar`. When used outside iOS 26's
/// `tabViewBottomAccessory` slot we draw our own rounded material capsule;
/// inside the system accessory slot we rely on the liquid-glass chrome that
/// the tab bar provides (and fuses with the selected tab icon on scroll).
private struct MiniPlayerChromeModifier: ViewModifier {
    let useCustomChrome: Bool

    func body(content: Content) -> some View {
        if useCustomChrome {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        } else {
            content
        }
    }
}

/// Renders `MiniPlayerBar` only when it should be visible — i.e. the user
/// has a speaker configured, isn't looking at the full player, and isn't
/// actively typing (soft keyboard up). Keyboard awareness matters because
/// both the `safeAreaInset` (iOS < 26) and `tabViewBottomAccessory`
/// (iOS 26+) mount points ride up with the keyboard by default and waste
/// half of the search-results viewport. Apple Music / Spotify drop their
/// mini-players the same way during active input.
private struct KeyboardAwareMiniPlayer: View {
    @Bindable var manager: SonosManager
    @Binding var dragOffset: CGFloat
    var inSystemAccessory: Bool = false
    @State private var isKeyboardVisible = false

    var body: some View {
        Group {
            if MiniPlayerMountPolicy.shouldMount(
                isConfigured: manager.isConfigured,
                isKeyboardVisible: isKeyboardVisible
            ) {
                let isVisible = MiniPlayerMountPolicy.isVisible(
                    isConfigured: manager.isConfigured,
                    isFullPlayerVisible: manager.showFullPlayer,
                    isKeyboardVisible: isKeyboardVisible
                )
                MiniPlayerBar(
                    manager: manager,
                    dragOffset: $dragOffset,
                    inSystemAccessory: inSystemAccessory)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .accessibilityHidden(!isVisible)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
    }
}

/// ViewModifier that inserts `MiniPlayerBar` into a tab's bottom safe-area
/// inset. Used only on iOS < 26 — newer OSes get the mini-player through
/// `tabViewBottomAccessory`.
private struct MiniPlayerInset: ViewModifier {
    @Bindable var manager: SonosManager
    @Binding var dragOffset: CGFloat

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            KeyboardAwareMiniPlayer(manager: manager, dragOffset: $dragOffset)
        }
    }
}

private struct MiniPlayerSystemAccessoryContentInset: ViewModifier {
    @Bindable var manager: SonosManager

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            KeyboardAwareMiniPlayerContentSpacer(manager: manager)
        }
    }
}

private struct KeyboardAwareMiniPlayerContentSpacer: View {
    @Bindable var manager: SonosManager
    @State private var isKeyboardVisible = false

    var body: some View {
        Color.clear
            .frame(height: MiniPlayerLayoutMetrics.systemAccessoryContentBottomInset(
                isMiniPlayerVisible: manager.isConfigured
                    && !manager.showFullPlayer
                    && !isKeyboardVisible
            ))
            .allowsHitTesting(false)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
    }
}

extension View {
    /// Mounts the per-tab content inset needed to keep scrollable pages clear
    /// of the persistent mini-player.
    @ViewBuilder
    func miniPlayerTabContentInset(
        manager: SonosManager,
        dragOffset: Binding<CGFloat>
    ) -> some View {
        if #available(iOS 26.0, *) {
            modifier(MiniPlayerSystemAccessoryContentInset(manager: manager))
        } else {
            modifier(MiniPlayerInset(manager: manager, dragOffset: dragOffset))
        }
    }

    /// iOS 26+: attach the mini-player as the tab bar's bottom accessory
    /// so the OS can collapse the inactive tabs on scroll and render the
    /// selected-tab icon side-by-side with the mini-player capsule.
    @ViewBuilder
    func miniPlayerSystemAccessoryIfAvailable(
        manager: SonosManager,
        dragOffset: Binding<CGFloat>
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.tabViewBottomAccessory {
                KeyboardAwareMiniPlayer(
                    manager: manager,
                    dragOffset: dragOffset,
                    inSystemAccessory: true)
            }
        } else {
            self
        }
    }

    /// iOS 26+: minimize the tab bar when the user scrolls content down, so
    /// the selected-tab icon slides next to the mini-player accessory. Apple's
    /// default behavior on iOS is `.automatic`, which does *not* enable this
    /// on iPhone — we have to opt in explicitly.
    @ViewBuilder
    func tabBarMinimizeOnScrollIfAvailable() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
