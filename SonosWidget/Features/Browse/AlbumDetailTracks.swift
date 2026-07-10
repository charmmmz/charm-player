import AVFoundation
import SwiftUI


extension AlbumDetailView {

    // MARK: - Action Bar (Play / Shuffle)

    var actionBar: some View {
        AlbumPrimaryActionBar(
            favoriteKind: .sonos,
            tint: themeColor,
            isPlayActive: playingItemId == "play-all",
            isShuffleActive: playingItemId == "shuffle",
            isFavoriteActive: isFavorited,
            isFavoriteBusy: false,
            isFavoriteDisabled: false,
            isPlaybackDisabled: playingItemId != nil,
            play: playAlbum,
            shuffle: playAlbumShuffled,
            toggleFavorite: toggleFavorite
        )
    }

    // MARK: - Track List

    @ViewBuilder
    var trackList: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 40)
        } else if let err = errorText {
            ContentUnavailableView("Failed to Load",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(err))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { idx, track in
                    trackRow(track, isLast: idx == tracks.count - 1)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    func trackRow(_ track: SonosCloudAPI.AlbumTrackItem, isLast: Bool) -> some View {
        let isPlaying = playingItemId == track.id
        let isDisabled = playingItemId != nil && !isPlaying
        let item = browseItemFromTrack(track)

        return AlbumTrackRow(
            number: "\(track.ordinal ?? 0)",
            title: track.title ?? "",
            subtitle: AlbumTrackSubtitlePolicy.subtitle(
                trackArtist: track.artists?.first?.name,
                albumArtist: artistName
            ),
            duration: formattedDuration(track.duration),
            isExplicit: track.isExplicit == true,
            isPlaying: isPlaying,
            isDisabled: isDisabled,
            isLast: isLast,
            action: { playTrack(track) }
        ) {
            trackContextMenu(track, item: item)
        }
    }

    @ViewBuilder
    func trackContextMenu(
        _ track: SonosCloudAPI.AlbumTrackItem,
        item: BrowseItem
    ) -> some View {
        let trackFavorited = searchManager.isFavorited(item)
        let appleMusicResource = searchManager.appleMusicFavoriteResource(for: item)

        MusicResourceContextMenu(
            actions: AlbumTrackMenuActionPolicy.songActions(
                isSonosFavoriteActive: trackFavorited,
                isAppleMusicFavoriteActive: false,
                isQueueable: item.playbackDescriptor.isQueueable,
                isAppleMusicFavoriteAvailable: appleMusicResource != nil
            )
        ) { action in
            performTrackMenuAction(action, track: track, item: item)
        }
    }

    func performTrackMenuAction(
        _ action: MusicResourceMenuAction,
        track: SonosCloudAPI.AlbumTrackItem,
        item: BrowseItem
    ) {
        switch action {
        case .playNow:
            playTrack(track)
        case .playNext:
            Task { await searchManager.playNext(item: item, manager: manager) }
            showToast("Playing next")
        case .addToQueue:
            Task { await searchManager.addToQueue(item: item, manager: manager) }
            showToast("Added to queue")
        case .favorite(.sonos, _, _):
            Task {
                let trackFavorited = searchManager.isFavorited(item)
                if trackFavorited {
                    let ok = await searchManager.removeFromFavorites(item: item, manager: manager)
                    showToast(ok ? "Removed from Favorites" : "Failed to remove")
                } else {
                    let ok = await searchManager.addToFavorites(item: item, manager: manager)
                    showToast(ok ? "Added to Favorites" : "Failed to add")
                }
            }
        case .favorite(.appleMusic, _, _):
            Task {
                let ok = await searchManager.toggleAppleMusicFavorites(for: item)
                showToast(ok ? "Updated Apple Music Favorites" : "Failed to update Apple Music")
            }
        case .startStation:
            break
        }
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        withAnimation(ToastModifier.fadeAnimation) { toastMessage = message }
    }

    // MARK: - Helpers

    func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    func formattedDuration(_ rawDuration: String?) -> String? {
        guard let rawDuration,
              let seconds = Int(rawDuration) else {
            return nil
        }
        return formatDuration(seconds)
    }

    func browseItemFromTrack(_ track: SonosCloudAPI.AlbumTrackItem) -> BrowseItem {
        searchManager.makeAlbumTrackItem(
            from: track,
            fallbackAlbumTitle: albumTitle,
            fallbackArtist: artistName,
            fallbackArtURL: coverURL
        )
    }

}
