import Observation
import SwiftUI
import UIKit

extension SearchView {

    // MARK: - Context Menu

    @ViewBuilder
    func itemContextMenu(_ item: BrowseItem) -> some View {
        let favorited = searchManager.isFavorited(item)
        let appleMusicResource = searchManager.appleMusicFavoriteResource(for: item)
        let kind = MusicResourceKind(cloudType: item.cloudType)

        if item.isArtist {
            Button {
                startStationForItem(item)
            } label: {
                Label("Start Station", systemImage: "antenna.radiowaves.left.and.right")
            }

            Divider()

            Button {
                handleFavoriteAction(item)
            } label: {
                Label(appleMusicResource == nil
                      ? (favorited ? "Remove from Sonos Favorites" : "Add to Sonos Favorites")
                      : "Favorites",
                      systemImage: favorited ? "heart.fill" : "heart")
            }
        } else if item.playbackDescriptor.hasActionSurface {
            MusicResourceContextMenu(
                actions: MusicResourceActionPolicy.actions(
                    kind: kind,
                    isQueueable: item.playbackDescriptor.isQueueable,
                    isSonosFavoriteActive: favorited,
                    isAppleMusicFavoriteActive: false,
                    isAppleMusicFavoriteAvailable: appleMusicResource != nil
                )
            ) { action in
                switch action {
                case .playNow:
                    playItem(item)
                case .playNext:
                    Task { await searchManager.playNext(item: item, manager: manager) }
                case .addToQueue:
                    Task { await searchManager.addToQueue(item: item, manager: manager) }
                case .startStation:
                    startStationForItem(item)
                case .favorite(.sonos, _, _):
                    Task { await toggleSonosFavorite(item) }
                case .favorite(.appleMusic, _, _):
                    Task { await toggleAppleMusicFavorite(item) }
                }
            }

            if item.playbackDescriptor.isPlayable, kind != .song {
                Divider()

                Button {
                    handleFavoriteAction(item)
                } label: {
                    Label(appleMusicResource == nil
                          ? (favorited ? "Remove from Sonos Favorites" : "Add to Sonos Favorites")
                          : "Favorites",
                          systemImage: favorited ? "heart.slash" : "heart")
                }
            }
        }
    }
}
