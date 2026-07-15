import AVFoundation
import SwiftUI
import UIKit

extension NowPlayingOverlay {

    // MARK: - Portrait Layout

    @ViewBuilder
    func portraitLayout(geo: GeometryProxy) -> some View {
        if usesFullScreenAnimatedArtwork {
            immersivePortraitLayout(geo: geo)
        } else {
            standardPortraitLayout(geo: geo)
        }
    }

    func standardPortraitLayout(geo: GeometryProxy) -> some View {
        let h = geo.size.height
        // Full-bleed square cover. Cap at h * 0.55 as a safety on small
        // devices (e.g. SE) where a width-sized square would crowd out the
        // transport row below; on every modern iPhone width wins this min.
        let artSz = max(1, min(geo.size.width, h * 0.55))
        let s = max(0.5, h / 760)
        let bottomActionsBottomPadding = bottomActionsBottomPadding(geo: geo)

        return VStack(spacing: 0) {
            albumArtView(size: artSz)

            trackInfoView
                .padding(.horizontal, 32)
                .padding(.top, 22 * s)

            progressView
                .padding(.top, 18 * s)

            // TV input has no transport actions worth surfacing
            // (`GetCurrentTransportActions` returns just `Set, Play` and the
            // soundbar can't seek or skip a live stream). Swap the row for
            // the soundbar EQ toggles so the slot doesn't feel empty.
            if manager.trackInfo?.source == .tv {
                soundbarEQPanel
                    .padding(.top, 18 * s)
                    .padding(.horizontal, 32)
            } else {
                playbackControls
                    .padding(.top, 22 * s)
            }

            volumeControl
                .padding(.top, manager.trackInfo?.source == .tv ? 18 * s : 22 * s)

            Spacer(minLength: 0)

            // Queue is meaningless for TV input (the soundbar isn't playing
            // a queue, it's passing through HDMI/optical), so hide the list
            // button and let the speaker picker fill the row.
            bottomActions(showQueue: manager.trackInfo?.source != .tv)
                .padding(.top, 16 * s)
                .padding(.bottom, bottomActionsBottomPadding)

            errorBanner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    func immersivePortraitLayout(geo: GeometryProxy) -> some View {
        let h = geo.size.height
        let s = max(0.5, h / 760)
        let controlsTopPadding = max(300, h * 0.52)
        let bottomActionsBottomPadding = bottomActionsBottomPadding(geo: geo)
        let backgroundSize = AnimatedArtworkFeature.fullScreenBackgroundContainerSize(
            contentSize: geo.size,
            topSafeAreaInset: geo.safeAreaInsets.top,
            bottomSafeAreaInset: geo.safeAreaInsets.bottom
        )
        let foregroundSize = AnimatedArtworkFeature.fullScreenBlurFillForegroundSize(
            containerSize: backgroundSize,
            videoAspectRatio: fullScreenAnimatedArtworkAspectRatio
        )
        let foregroundTopOffset = AnimatedArtworkFeature.fullScreenBlurFillForegroundTopOffset(
            containerSize: backgroundSize
        )
        let sourceBadgeTopPadding = AnimatedArtworkFeature.fullScreenSourceBadgeTopPadding(
            foregroundSize: foregroundSize,
            foregroundTopOffset: foregroundTopOffset,
            controlsTopPadding: controlsTopPadding
        )

        return VStack(spacing: 0) {
            Spacer(minLength: controlsTopPadding)

            trackInfoView
                .padding(.horizontal, 32)

            progressView
                .padding(.top, 18 * s)

            playbackControls
                .padding(.top, 22 * s)

            volumeControl
                .padding(.top, 22 * s)

            Spacer(minLength: 0)

            bottomActions(showQueue: true)
                .padding(.top, 16 * s)
                .padding(.bottom, bottomActionsBottomPadding)

            errorBanner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            fullScreenAnimatedArtworkSourceBadge
                .padding(.leading, 32)
                .padding(.top, sourceBadgeTopPadding)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Landscape Layout (player left | queue right)

    func landscapeLayout(geo: GeometryProxy) -> some View {
        let leftW = geo.size.width * 0.55
        let topPad: CGFloat = 12
        let fixedBelow: CGFloat = 196
        let artSz = max(80, min(leftW * 0.38, geo.size.height - topPad - fixedBelow))

        return HStack(spacing: 0) {
            // ── Left panel: player ──
            VStack(spacing: 0) {
                Spacer(minLength: topPad)

                HStack(alignment: .center, spacing: 16) {
                    albumArtView(size: artSz)

                    VStack(alignment: .leading) {
                        Spacer(minLength: 0)
                        nowPlayingTitleLabel(lineLimit: 2, usesShadow: false)
                        // Hide artist/album rows for TV — the format pill in
                        // `tvFormatPanel` already conveys the codec.
                        if manager.trackInfo?.source != .tv {
                            Text(manager.trackInfo?.artist ?? "—")
                                .font(MusicDetailHeaderTypography.nowPlayingArtistStyle.font)
                                .fontWeight(.regular)
                                .foregroundStyle(.white.opacity(MusicDetailHeaderTypography.artistOpacity))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .padding(.top, 3)
                            Text(manager.trackInfo?.album ?? "")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .padding(.top, 1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: artSz, alignment: .leading)
                }
                .padding(.horizontal, 20)

                progressContent
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                if manager.trackInfo?.source == .tv {
                    soundbarEQPanel
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                } else {
                    playbackControls.padding(.top, 10)
                }
                volumeControl.padding(.top, 6)
                bottomActions(showQueue: false).padding(.top, 6)

                Spacer(minLength: 0)
                errorBanner
            }
            .frame(width: leftW)
            .contentShape(Rectangle())

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 0.5)

            // ── Right panel: queue ──
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("QUEUE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                    if !manager.isPlayingFromQueue {
                        Text("· NOT IN USE")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.5)
                    }
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

                QueueView(manager: manager, showNavigation: false)
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                if manager.queue.isEmpty {
                    Task { await manager.loadQueue() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Background

    @ViewBuilder
    func artBackground(size: CGSize) -> some View {
        let transitionID = albumArtTransitionID
        ZStack {
            SonosArtworkBackground(
                image: manager.albumArtImage,
                fallbackColor: manager.albumArtDominantColor,
                overlayOpacity: usesFullScreenAnimatedArtwork
                    ? 0.18
                    : NowPlayingBackgroundPresentation.sharedArtworkOverlayOpacity
            )
            .id(transitionID)

            if shouldPlayAnimatedArtworkVideo, let url = fullScreenAnimatedArtworkURL {
                fullScreenAnimatedArtworkPresentation(
                    url: url,
                    size: size
                )
                .frame(width: size.width, height: size.height, alignment: .top)
                .opacity(fullScreenAnimatedArtworkReadyURL == url ? 1 : 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)

                fullScreenAnimatedArtworkScrim
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .ignoresSafeArea(
            .container,
            edges: NowPlayingOverlayPresentation.backgroundIgnoredSafeAreaEdges
        )
        .animation(.easeInOut(duration: 0.8), value: transitionID)
        .animation(.easeInOut(duration: 0.8), value: manager.albumArtDominantColor)
        .animation(.easeInOut(duration: 0.45), value: fullScreenAnimatedArtworkReadyURL)
    }

    @ViewBuilder
    func fullScreenAnimatedArtworkPresentation(
        url: URL,
        size: CGSize
    ) -> some View {
        let containerAspectRatio = size.height > 0 ? size.width / size.height : 0
        let videoAspectRatio = fullScreenAnimatedArtworkAspectRatio
        let usesBlurFill = AnimatedArtworkFeature.shouldUseBlurFillForFullScreenArtwork(
            videoAspectRatio: videoAspectRatio,
            containerAspectRatio: containerAspectRatio
        )

        if usesBlurFill {
            fullScreenAnimatedArtworkBlurFill(
                url: url,
                size: size,
                videoAspectRatio: videoAspectRatio
            )
        } else {
            AnimatedArtworkPlayerView(
                url: url,
                isPlaying: shouldPlayAnimatedArtworkVideo,
                videoGravity: .resizeAspectFill,
                onReadyForDisplay: {
                    markFullScreenAnimatedArtworkReady(url)
                }
            )
        }
    }

    func fullScreenAnimatedArtworkBlurFill(
        url: URL,
        size: CGSize,
        videoAspectRatio: CGFloat?
    ) -> some View {
        let foregroundSize = AnimatedArtworkFeature.fullScreenBlurFillForegroundSize(
            containerSize: size,
            videoAspectRatio: videoAspectRatio
        )
        let foregroundTopOffset = AnimatedArtworkFeature.fullScreenBlurFillForegroundTopOffset(
            containerSize: size
        )

        return ZStack(alignment: .top) {
            FullScreenAnimatedArtworkExtensionBackdrop(
                size: size,
                videoAspectRatio: videoAspectRatio
            )

            AnimatedArtworkPlayerView(
                url: url,
                isPlaying: shouldPlayAnimatedArtworkVideo,
                videoGravity: .resizeAspect,
                onReadyForDisplay: {
                    markFullScreenAnimatedArtworkReady(url)
                }
            )
            .frame(width: foregroundSize.width, height: foregroundSize.height, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.54),
                        .init(color: .black.opacity(0.6), location: 0.72),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .offset(y: foregroundTopOffset)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }

    func markFullScreenAnimatedArtworkReady(_ url: URL) {
        if fullScreenAnimatedArtworkURL == url {
            fullScreenAnimatedArtworkReadyURL = url
        }
    }

    var fullScreenAnimatedArtworkScrim: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.08), location: 0.0),
                    .init(color: .black.opacity(0.08), location: 0.36),
                    .init(color: .black.opacity(0.48), location: 0.58),
                    .init(color: .black.opacity(0.88), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.32)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.34),
                            .init(color: .black.opacity(0.35), location: 0.58),
                            .init(color: .black, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

}
