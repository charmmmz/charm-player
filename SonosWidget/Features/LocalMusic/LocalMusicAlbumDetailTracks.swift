import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit

extension LocalMusicAlbumDetailView {

    @ViewBuilder
    var trackList: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 36)
        } else if let errorMessage {
            LocalMusicDetailStatusBanner(message: errorMessage)
                .padding(.top, 20)
        } else if tracks.isEmpty {
            ContentUnavailableView("No Tracks", systemImage: "music.note.list")
                .padding(.top, 48)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    let isPlaying = store.isStartingPlayback && store.activePlaybackItemID == track.id.rawValue
                    AlbumTrackRow(
                        number: LocalMusicTrackNumberLabel.text(
                            trackNumber: track.trackNumber,
                            index: index,
                            style: .albumTrackNumber
                        ),
                        title: track.title,
                        subtitle: AlbumTrackSubtitlePolicy.subtitle(
                            trackArtist: track.artistName,
                            albumArtist: displayAlbum.artistName
                        ),
                        duration: durationText(track.duration),
                        isExplicit: false,
                        isPlaying: isPlaying,
                        isDisabled: store.isStartingPlayback && !isPlaying,
                        isLast: index == tracks.count - 1,
                        verticalPadding: LocalMusicDetailSpacing.compactTrackRowVerticalPadding,
                        numberAlignment: .center,
                        action: {
                            Task {
                                await playTrack(track)
                            }
                        }
                    ) {
                        localAlbumTrackContextMenu(track)
                    }
                }
            }
            .padding(.top, LocalMusicDetailSpacing.trackListTopPadding)
            .padding(.horizontal)
        }
    }

    func localAlbumTrackContextMenu(_ track: Track) -> some View {
        let isFavoriteActive = appleMusicFavoritedTrackIDs.contains(track.id.rawValue)

        return MusicResourceContextMenu(
            actions: AlbumTrackMenuActionPolicy.songActions(
                isSonosFavoriteActive: false,
                isAppleMusicFavoriteActive: isFavoriteActive,
                isQueueable: true,
                isAppleMusicFavoriteAvailable: favoriteResource(for: track) != nil
            )
        ) { action in
            performLocalAlbumTrackMenuAction(action, track: track)
        }
    }

    func performLocalAlbumTrackMenuAction(
        _ action: MusicResourceMenuAction,
        track: Track
    ) {
        switch action {
        case .playNow:
            Task { await playTrack(track) }
        case .playNext, .addToQueue:
            Task {
                await store.performSonosQueueAction(
                    action,
                    playable: LocalServiceAppleMusicPlayable.make(track: track),
                    displayID: track.id.rawValue,
                    fallbackKind: .song,
                    fallbackTitle: track.title,
                    fallbackArtist: track.artistName,
                    fallbackAlbum: track.albumTitle,
                    manager: manager,
                    searchManager: searchManager)
            }
        case .favorite(.sonos, _, _):
            Task {
                await store.toggleSonosFavorite(
                    playable: LocalServiceAppleMusicPlayable.make(track: track),
                    displayID: track.id.rawValue,
                    fallbackKind: .song,
                    fallbackTitle: track.title,
                    fallbackArtist: track.artistName,
                    fallbackAlbum: track.albumTitle,
                    manager: manager,
                    searchManager: searchManager)
            }
        case .favorite(.appleMusic, _, _):
            toggleAppleMusicTrackFavorite(track)
        case .startStation:
            break
        }
    }

    func playTrack(_ track: Track) async {
        await store.playOnSonos(
            playable: LocalServiceAppleMusicPlayable.make(track: track),
            displayID: track.id.rawValue,
            fallbackKind: .song,
            fallbackTitle: track.title,
            fallbackArtist: track.artistName,
            fallbackAlbum: track.albumTitle,
            manager: manager,
            searchManager: searchManager)
    }

    @ViewBuilder
    var completeAlbumFooter: some View {
        if shouldShowCompleteAlbumButton,
           let completeCatalogAlbum {
            NavigationLink {
                LocalMusicAlbumDetailView(
                    album: completeCatalogAlbum,
                    store: store,
                    manager: manager,
                    searchManager: searchManager,
                    initialDetailedAlbum: completeCatalogAlbum)
            } label: {
                HStack(spacing: 8) {
                    Text("Show Complete Album")
                        .font(.body)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
    }

}
