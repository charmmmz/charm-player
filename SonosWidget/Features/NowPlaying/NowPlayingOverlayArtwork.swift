import AVFoundation
import SwiftUI
import UIKit

extension NowPlayingOverlay {

    // MARK: - Album Art

    @ViewBuilder
    func albumArtView(size: CGFloat) -> some View {
        let isTV = manager.trackInfo?.source == .tv
        let tvFormat = manager.trackInfo?.tvFormat
        let tvHasSignal = tvFormat?.hasSignal ?? false
        let transitionID = manager.albumArtTransitionID(
            hasDisplayedArtwork: !isTV && manager.albumArtImage != nil
        )
        let placeholderIconName = AlbumArtPlaceholderIcon.systemName(
            source: manager.trackInfo?.source,
            hasDisplayedArtwork: !isTV && manager.albumArtImage != nil
        )
        // Atmos streams glow blue (matches the BadgeDolbyAtmos accent
        // family); everything else falls back to a neutral white sheen so
        // the TV slot doesn't blend into the dark background.
        let tvGlowColor: Color = (tvFormat?.isAtmos == true)
            ? Color(red: 0.36, green: 0.55, blue: 1.0)
            : .white
        let content = ZStack {
            // Edge-to-edge placeholder; no rounding now that the cover
            // pins to the screen edges. The TV-mode breathing halo and
            // glyph render on top of this backdrop unchanged.
            Rectangle().fill(.quaternary)
                .overlay {
                    // Subtle "audio is flowing" breathing halo behind the
                    // TV glyph — only when the bar reports a live stream.
                    // Driven by `TimelineView` so it survives navigation +
                    // backgrounding without us hand-managing a state var.
                    if isTV && tvHasSignal {
                        TimelineView(.animation(minimumInterval: 0.03, paused: false)) { ctx in
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            // ~3s breathing cycle, eased so the peaks feel
                            // like inhale/exhale rather than a metronome.
                            let phase = (sin(t * (.pi * 2 / 3.0)) + 1) / 2
                            RadialGradient(
                                colors: [
                                    tvGlowColor.opacity(0.18 + 0.10 * phase),
                                    tvGlowColor.opacity(0.04),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: size * 0.55
                            )
                            .blur(radius: 30)
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                        }
                    }
                    // For TV input there's no album art — swap the music-note
                    // placeholder for a TV glyph so the now-playing screen
                    // immediately reads as "watching" instead of "buffering".
                    if let placeholderIconName {
                        Image(systemName: placeholderIconName)
                            .font(.system(size: isTV ? 96 : 60, weight: isTV ? .light : .regular))
                            .foregroundStyle(.tertiary)
                    }
                }

            if !isTV, let image = manager.albumArtImage {
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: image)
                        .resizable().aspectRatio(1, contentMode: .fit)

                    if shouldPlayAnimatedArtworkVideo,
                       let animatedURL = animatedArtworkState.currentURL,
                       AnimatedArtworkFeature.canRenderVideo(source: manager.trackInfo?.source) {
                        AnimatedArtworkPlayerView(
                            url: animatedURL,
                            isPlaying: true,
                            onReadyForDisplay: {
                                if animatedArtworkState.currentURL == animatedURL {
                                    animatedArtworkReadyURL = animatedURL
                                }
                            }
                        )
                        .opacity(animatedArtworkReadyURL == animatedURL ? 1 : 0)
                        .accessibilityHidden(true)
                    }

                    if verticalSizeClass != .compact,
                       let source = manager.trackInfo?.source, source != .unknown {
                        sourceBadge(source)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 14)
                    }
                }
                .id(transitionID)
                .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        // For TV input, reuse the streaming-source badge slot to show LIVE/IDLE.
        .overlay(alignment: .bottomLeading) {
            if isTV && verticalSizeClass != .compact {
                tvSignalBadge(hasSignal: tvHasSignal)
                    .padding(10)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: transitionID)

        content
    }

    func sourceBadge(_ source: PlaybackSource) -> some View {
        SourceBadgeView(source: source, tintColor: manager.albumArtDominantColor)
    }

    @ViewBuilder
    var fullScreenAnimatedArtworkSourceBadge: some View {
        if verticalSizeClass != .compact,
           let source = manager.trackInfo?.source,
           source != .unknown {
            sourceBadge(source)
        }
    }

    func openCurrentAppleMusicTrack() {
        guard !isOpeningAppleMusicLink,
              canOpenCurrentAppleMusicTrack,
              let info = manager.trackInfo else { return }
        let cachedURL = currentAppleMusicTrackURL
        let resource = currentAppleMusicTrackResource
        let lookupID = currentAppleMusicLinkLookupID
        isOpeningAppleMusicLink = true

        Task { @MainActor in
            defer { isOpeningAppleMusicLink = false }
            do {
                let resolvedURL: URL?
                if let cachedURL {
                    resolvedURL = cachedURL
                } else {
                    resolvedURL = try await AppleMusicExternalLinkFallbackResolver().songURL(
                        directResource: resource,
                        title: info.title,
                        artist: info.artist,
                        album: info.album
                    )
                    if currentAppleMusicLinkLookupID == lookupID {
                        currentAppleMusicTrackURL = resolvedURL
                    }
                }

                guard let url = resolvedURL else {
                    SonosLog.debug(
                        .nowPlaying,
                        "Apple Music current title lookup produced no URL " +
                            "title='\(info.title)' artist='\(info.artist)' album='\(info.album)' " +
                            "directID='\(resource?.id ?? "nil")'"
                    )
                    return
                }
                AppleMusicExternalLinkOpener.open(
                    url,
                    context: "now-playing-title title='\(info.title)' directID='\(resource?.id ?? "nil")'"
                )
            } catch {
                SonosLog.error(
                    .nowPlaying,
                    "Apple Music current title lookup failed " +
                        "title='\(info.title)' artist='\(info.artist)' album='\(info.album)' " +
                        "directID='\(resource?.id ?? "nil")' error=\(error)"
                )
            }
        }
    }

    func addCurrentTrackToSonosFavorites() {
        guard !isAddingCurrentTrackToSonosFavorites,
              let item = currentTrackBrowseItemForSonosFavorite else { return }
        isAddingCurrentTrackToSonosFavorites = true

        Task { @MainActor in
            defer { isAddingCurrentTrackToSonosFavorites = false }
            if searchManager.isFavorited(item) {
                SonosLog.info(
                    .favorites,
                    "Current track already in Sonos Favorites title='\(item.title)' id='\(item.id)'")
                return
            }
            _ = await searchManager.addToFavorites(item: item, manager: manager)
        }
    }

    func addCurrentTrackToAppleMusicFavorites() {
        guard !isAddingCurrentTrackToAppleMusicFavorites,
              let resource = currentAppleMusicTrackResource else { return }
        isAddingCurrentTrackToAppleMusicFavorites = true

        Task { @MainActor in
            defer { isAddingCurrentTrackToAppleMusicFavorites = false }
            do {
                let alreadyFavorited = (try? await searchManager.appleMusicFavoriteStatus(for: resource)) ?? false
                if !alreadyFavorited {
                    try await searchManager.addToAppleMusicFavorites(resource: resource)
                }
                SonosLog.info(
                    .favorites,
                    "Current track added to Apple Music Favorites resource='\(resource.id)' alreadyFavorited=\(alreadyFavorited)")
            } catch {
                SonosLog.error(.favorites, "Current track Apple Music Favorites add failed: \(error)")
                searchManager.errorMessage = error.localizedDescription
            }
        }
    }

    /// Pill that mirrors `SourceBadgeView` proportions — kept here rather
    /// than in `SourceBadgeView` itself because the LIVE/IDLE state is
    /// strictly TV-specific and shouldn't pollute the music badge enum.
    @ViewBuilder
    func tvSignalBadge(hasSignal: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(hasSignal ? Color.red : Color.white.opacity(0.4))
                .frame(width: 6, height: 6)
                .opacity(hasSignal ? 1.0 : 0.6)
            Text(hasSignal ? "LIVE" : "IDLE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hasSignal ? .white : .white.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(
            Capsule().stroke(
                hasSignal ? Color.red.opacity(0.6) : Color.white.opacity(0.25),
                lineWidth: 1)
        )
    }

}
