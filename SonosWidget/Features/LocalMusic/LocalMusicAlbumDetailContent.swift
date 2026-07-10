import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit

extension LocalMusicAlbumDetailView {

    var albumScrollableContent: some View {
        VStack(spacing: 0) {
            actionBar
                .padding(.top, 16)
                .padding(.bottom, 8)
            editorialDescriptionSection(
                text: albumDescription,
                title: displayAlbum.title
            )
            trackList
            completeAlbumFooter
        }
        .padding(.bottom, 24)
        .background(alignment: .top) {
            if usesImmersiveAnimatedArtwork {
                immersiveScrollableContentBackdrop
                    .padding(
                        .top,
                        AlbumAnimatedArtworkPresentation.contentBackdropTopPadding(
                            isImmersive: usesImmersiveAnimatedArtwork
                        )
                    )
            }
        }
    }

    @ViewBuilder
    var immersiveScrollableContentBackdrop: some View {
        let topOpacity = AlbumAnimatedArtworkPresentation.contentBackdropTopOpacity(
            isImmersive: usesImmersiveAnimatedArtwork
        )
        let strongFadeLocation = AlbumAnimatedArtworkPresentation.contentBackdropStrongFadeLocation(
            isImmersive: usesImmersiveAnimatedArtwork
        )
        let minimumHeight = AlbumAnimatedArtworkPresentation.contentBackdropMinimumHeight(
            isImmersive: usesImmersiveAnimatedArtwork,
            viewportHeight: UIScreen.main.bounds.height
        )

        ZStack(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(topOpacity), location: 0),
                    .init(color: .black.opacity(0.14), location: 0.22),
                    .init(color: .black.opacity(0.62), location: strongFadeLocation),
                    .init(color: .black.opacity(0.94), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.42)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.24),
                            .init(color: .black.opacity(0.42), location: 0.52),
                            .init(color: .black, location: 0.88)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
        .ignoresSafeArea(edges: .horizontal)
        .allowsHitTesting(false)
    }

    var header: some View {
        VStack(spacing: 12) {
            if usesImmersiveAnimatedArtwork {
                immersiveAnimatedArtworkHeaderSpacer
            } else {
                headerArtwork
            }

            VStack(spacing: 5) {
                albumTitleLabel

                Text(displayAlbum.artistName)
                    .font(MusicDetailHeaderTypography.localAlbumArtistStyle.font)
                    .fontWeight(.regular)
                    .foregroundStyle(.white.opacity(MusicDetailHeaderTypography.artistOpacity))
                    .lineLimit(2)

                Text(albumMetadata)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)

            }
            .padding(.horizontal)
        }
        .padding(.top, usesImmersiveAnimatedArtwork ? 0 : 20)
    }

    var immersiveAnimatedArtworkHeaderSpacer: some View {
        Color.clear
            .frame(
                height: AlbumAnimatedArtworkPresentation.immersiveHeaderSpacerHeight(
                    containerWidth: UIScreen.main.bounds.width,
                    viewportHeight: UIScreen.main.bounds.height,
                    videoAspectRatio: animatedArtworkBackgroundAspectRatio
                )
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    var headerArtwork: some View {
        if AlbumHeaderAppleMusicLinkPolicy.shouldLinkArtwork(
            canResolveAppleMusicURL: canResolveAppleMusicTitleLink
        ) {
            Button {
                openAppleMusicFromTitle()
            } label: {
                headerArtworkImage
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(displayAlbum.title) in Apple Music")
        } else {
            headerArtworkImage
        }
    }

    @ViewBuilder
    var albumTitleLabel: some View {
        if AlbumHeaderAppleMusicLinkPolicy.shouldLinkTitle(
            canResolveAppleMusicURL: canResolveAppleMusicTitleLink
        ) {
            Button {
                openAppleMusicFromTitle()
            } label: {
                albumTitleText
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(displayAlbum.title) in Apple Music")
        } else {
            albumTitleText
        }
    }

    var albumTitleText: some View {
        Text(displayAlbum.title)
            .font(.title2.weight(.bold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
    }

    var headerArtworkImage: some View {
        ZStack {
            LocalMusicDetailArtwork(
                artwork: displayAlbum.artwork,
                artworkURL: coverURL,
                fallbackSystemImage: "square.stack",
                size: 280
            )

            if let url = animatedArtworkHeaderURL {
                AnimatedArtworkPlayerView(
                    url: url,
                    isPlaying: shouldPlayAnimatedArtworkVideo,
                    videoGravity: .resizeAspectFill
                ) {
                    if animatedArtworkHeaderURL == url {
                        animatedArtworkReadyURL = url
                    }
                }
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(animatedArtworkReadyURL == url ? 1 : 0)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: animatedArtworkReadyURL)
    }

    var albumDescription: String? {
        EditorialDescriptionPolicy.text(
            standard: completeCatalogAlbum?.editorialNotes?.standard ?? displayAlbum.editorialNotes?.standard,
            short: completeCatalogAlbum?.editorialNotes?.short ?? displayAlbum.editorialNotes?.short,
            tagline: completeCatalogAlbum?.editorialNotes?.tagline ?? displayAlbum.editorialNotes?.tagline)
    }

    var albumMetadata: String {
        var parts: [String] = []
        if let releaseDate = displayAlbum.releaseDate {
            parts.append(releaseDate.formatted(.dateTime.year()))
        }
        if !displayAlbum.genreNames.isEmpty {
            parts.append(displayAlbum.genreNames.prefix(2).joined(separator: ", "))
        }
        parts.append("\(displayAlbum.trackCount) tracks")
        return parts.joined(separator: " · ")
    }

    var actionBar: some View {
        AlbumPrimaryActionBar(
            favoriteKind: .appleMusic,
            tint: actionTint,
            isPlayActive: isActionActive(.play),
            isShuffleActive: isActionActive(.shuffle),
            isFavoriteActive: isAppleMusicFavorited,
            isFavoriteBusy: isAppleMusicFavoriteBusy,
            isFavoriteDisabled: albumFavoriteResource == nil,
            isPlaybackDisabled: actionInFlight != nil || store.isStartingPlayback,
            play: { performAction(.play) },
            shuffle: { performAction(.shuffle) },
            toggleFavorite: toggleAppleMusicFavorite
        )
    }

    var actionTint: Color {
        themeColor ?? manager.albumArtDominantColor ?? .white.opacity(0.15)
    }

    func isActionActive(_ action: LocalMusicDetailAction) -> Bool {
        actionInFlight == action ||
            (store.isStartingPlayback && store.activePlaybackItemID == displayID(for: action))
    }

    func displayID(for action: LocalMusicDetailAction) -> String {
        switch action {
        case .shuffle:
            return "\(playbackAlbumID):shuffle"
        case .play, .favorite, .playStation, .openAppleMusic:
            return playbackAlbumID
        }
    }

    func performAction(_ action: LocalMusicDetailAction) {
        switch action {
        case .play:
            playAlbum(shuffle: false, action: action)
        case .shuffle:
            playAlbum(shuffle: true, action: action)
        case .openAppleMusic:
            if let url = appleMusicURL {
                openLocalMusicAppleMusicURL(url, context: "album-action title='\(displayAlbum.title)'")
            }
        case .favorite:
            toggleAppleMusicFavorite()
        case .playStation:
            break
        }
    }

    var albumMenu: some View {
        Menu {
            LocalMusicContainerDetailMenuContent(
                actions: LocalMusicContainerDetailMenuPolicy.actions(
                    hasAppleMusicURL: appleMusicURL != nil
                ),
                perform: performAlbumMenuAction
            )
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
        }
    }

    func performAlbumMenuAction(_ action: LocalMusicContainerDetailMenuAction) {
        performLocalMusicContainerMenuAction(
            action,
            playable: albumPlayable,
            context: albumSonosActionContext,
            store: store,
            manager: manager,
            searchManager: searchManager,
            openAppleMusic: { performAction(.openAppleMusic) }
        )
    }

}
