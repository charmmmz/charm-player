import MusicKit
import Observation
import SwiftUI


extension LocalLibraryView {

    @ViewBuilder
    func card(_ presentation: LocalServiceCardPresentation) -> some View {
        let item = presentation.item
        let playable = presentation.playable
        let playbackPlayable = playableWithPreferredPlaybackArtwork(
            playable,
            artworkURL: item.catalogArtworkURL(using: store)
        )

        switch item {
        case .album(let album):
            NavigationLink {
                LocalMusicAlbumDetailView(
                    album: album,
                    store: store,
                    manager: manager,
                    searchManager: searchManager)
            } label: {
                cardContent(item, playable: playbackPlayable)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playbackPlayable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playbackPlayable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .playlist(let playlist):
            NavigationLink {
                LocalMusicPlaylistDetailView(
                    playlist: playlist,
                    store: store,
                    manager: manager,
                    searchManager: searchManager)
            } label: {
                cardContent(item, playable: playbackPlayable)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playbackPlayable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playbackPlayable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .recentlyPlayed(let recentlyPlayed):
            recentlyPlayedCard(recentlyPlayed, item: item, playable: playbackPlayable)
        case .recommendation(let recommendation):
            recommendationCard(recommendation, item: item, playable: playbackPlayable)
        case .song(let song):
            Button {
                Task {
                    await store.playOnSonos(
                        playable: playbackPlayable,
                        displayID: song.id.rawValue,
                        fallbackKind: .song,
                        fallbackTitle: song.title,
                        fallbackArtist: song.artistName,
                        fallbackAlbum: song.albumTitle,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                cardContent(item, playable: playbackPlayable)
            }
            .buttonStyle(.plain)
            .disabled(store.isStartingPlayback)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playbackPlayable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playbackPlayable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .artist(let artist):
            if LocalServiceLibraryInteraction.primaryAction(for: .artist) == .navigate {
                NavigationLink {
                    LocalMusicArtistDetailView(
                        artist: artist,
                        store: store,
                        manager: manager,
                        searchManager: searchManager)
                } label: {
                    cardContent(item, playable: playbackPlayable)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .contextMenu {
                    localResourceContextMenu(
                        playable: playbackPlayable,
                        displayID: item.playbackID,
                        kind: item.resourceKind,
                        fallbackKind: playbackPlayable?.kind,
                        fallbackTitle: item.title,
                        fallbackArtist: item.subtitle,
                        fallbackAlbum: item.title
                    )
                }
            } else {
                Button {
                    Task {
                        await store.playOnSonos(
                            playable: playbackPlayable,
                            displayID: artist.id.rawValue,
                            fallbackKind: .artist,
                            fallbackTitle: artist.name,
                            fallbackArtist: artist.name,
                            manager: manager,
                            searchManager: searchManager)
                    }
                } label: {
                    cardContent(item, playable: playbackPlayable)
                }
                .buttonStyle(.plain)
                .disabled(store.isStartingPlayback)
                .contentShape(Rectangle())
                .contextMenu {
                    localResourceContextMenu(
                        playable: playbackPlayable,
                        displayID: item.playbackID,
                        kind: item.resourceKind,
                        fallbackKind: playbackPlayable?.kind,
                        fallbackTitle: item.title,
                        fallbackArtist: item.subtitle,
                        fallbackAlbum: item.title
                    )
                }
            }
        case .station(let station):
            Button {
                Task {
                    await store.playOnSonos(
                        playable: playbackPlayable,
                        displayID: station.id.rawValue,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                cardContent(item, playable: playbackPlayable)
            }
            .buttonStyle(.plain)
            .disabled(store.isStartingPlayback)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playbackPlayable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playbackPlayable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        }
    }

    @ViewBuilder
    func recentlyPlayedCard(
        _ recentlyPlayed: RecentlyPlayedMusicItem,
        item: LocalServiceCardItem,
        playable: LocalServiceAppleMusicPlayable?
    ) -> some View {
        switch recentlyPlayed {
        case .album(let album):
            NavigationLink {
                LocalMusicAlbumDetailView(
                    album: album,
                    store: store,
                    manager: manager,
                    searchManager: searchManager)
            } label: {
                cardContent(item, playable: playable)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .playlist(let playlist):
            NavigationLink {
                LocalMusicPlaylistDetailView(
                    playlist: playlist,
                    store: store,
                    manager: manager,
                    searchManager: searchManager)
            } label: {
                cardContent(item, playable: playable)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .station:
            Button {
                Task {
                    await store.playOnSonos(
                        playable: playable,
                        displayID: recentlyPlayed.id.rawValue,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                cardContent(item, playable: playable)
            }
            .buttonStyle(.plain)
            .disabled(store.isStartingPlayback)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        @unknown default:
            EmptyView()
        }
    }

    @ViewBuilder
    func recommendationCard(
        _ recommendation: MusicPersonalRecommendation.Item,
        item: LocalServiceCardItem,
        playable: LocalServiceAppleMusicPlayable?
    ) -> some View {
        switch recommendation {
        case .album(let album):
            NavigationLink {
                LocalMusicAlbumDetailView(
                    album: album,
                    store: store,
                    manager: manager,
                    searchManager: searchManager)
            } label: {
                cardContent(item, playable: playable)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .playlist(let playlist):
            NavigationLink {
                LocalMusicPlaylistDetailView(
                    playlist: playlist,
                    store: store,
                    manager: manager,
                    searchManager: searchManager)
            } label: {
                cardContent(item, playable: playable)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .station:
            Button {
                Task {
                    await store.playOnSonos(
                        playable: playable,
                        displayID: recommendation.id.rawValue,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                cardContent(item, playable: playable)
            }
            .buttonStyle(.plain)
            .disabled(store.isStartingPlayback)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        @unknown default:
            EmptyView()
        }
    }

    func cardContent(
        _ item: LocalServiceCardItem,
        playable: LocalServiceAppleMusicPlayable?
    ) -> some View {
        let artworkSize = item.cardArtworkSize
        let resource = resource(for: item, playable: playable)
        let isLoading = store.isStartingPlayback && store.activePlaybackItemID == item.playbackID
        let isDimmed = store.isStartingPlayback && store.activePlaybackItemID != item.playbackID

        return MusicResourceCardLabel(
            resource: resource,
            width: artworkSize.width,
            height: artworkSize.height,
            cornerRadius: 8,
            isDimmed: isDimmed,
            isLoading: isLoading
        ) {
            LocalLibraryArtworkTile(
                artwork: item.artwork,
                artworkURL: item.catalogArtworkURL(using: store),
                fallbackSystemImage: item.fallbackSystemImage,
                diagnosticLabel: item.artworkDiagnosticLabel,
                artworkContentMode: LocalServiceCardArtworkMetrics.contentMode(
                    isStationLike: item.isStationLike,
                    maximumWidth: item.artwork?.maximumWidth,
                    maximumHeight: item.artwork?.maximumHeight)
            )
            .id(resource.artworkTapID)
        }
        .id(resource.titleTapID)
    }

}
