import Observation
import SwiftUI
import UIKit
// MARK: - Favorite Category Detail (pushed via NavigationLink)

struct FavoriteCategoryDetailView: View {
    let category: BrowseItem.FavoriteCategory
    let items: [BrowseItem]
    @Bindable var searchManager: SearchManager
    @Bindable var manager: SonosManager

    @State private var filterText = ""
    @State private var playingItemId: String?
    @State private var favoriteSheetItem: BrowseItem?

    private var filteredItems: [BrowseItem] {
        guard !filterText.isEmpty else { return items }
        let query = filterText.lowercased()
        return items.filter {
            $0.title.lowercased().contains(query)
            || $0.artist.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                searchBar
                    .padding(.horizontal)
                    .padding(.bottom, 12)

                if filteredItems.isEmpty && !filterText.isEmpty {
                    ContentUnavailableView.search(text: filterText)
                        .padding(.top, 20)
                } else {
                    // Shared cover loading no longer needs the `HStack` workaround
                    // that replaced the old LazyVGrid workaround; bring the grid back so
                    // columns space evenly (the manual row + leading `HStack` hugged the
                    // left edge and broke margins).
                    let columns = [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16),
                    ]
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredItems) { item in
                            cardView(item)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(category.rawValue)
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        .background {
            ZStack {
                if let image = manager.albumArtImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 80)
                        .scaleEffect(1.5)
                    Color.black.opacity(0.6)
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(item: $favoriteSheetItem) { item in
            FavoriteControlSheet(item: item, searchManager: searchManager, manager: manager)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Local Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Search \(category.rawValue.lowercased())…", text: $filterText)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Card

    @ViewBuilder
    private func cardView(_ item: BrowseItem) -> some View {
        let cat = category

        if cat == .album, let nav = albumNavItem(for: item) {
            NavigationLink {
                AlbumDetailView(albumItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                logBrowseNavigation(surface: "FavoriteCategoryCard", kind: "album", item: item, nav: nav)
            })
            .contextMenu { contextMenu(item) }
        } else if cat == .artist {
            let nav = artistNavItem(for: item) ?? item
            NavigationLink {
                ArtistDetailView(artistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                logBrowseNavigation(surface: "FavoriteCategoryCard", kind: "artist", item: item, nav: nav)
            })
            .contextMenu { contextMenu(item) }
        } else if cat == .playlist, let nav = playlistNavItem(for: item) {
            NavigationLink {
                PlaylistDetailView(playlistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                logBrowseNavigation(surface: "FavoriteCategoryCard", kind: "playlist", item: item, nav: nav)
            })
            .contextMenu { contextMenu(item) }
        } else if cat == .collection, let nav = collectionNavItem(for: item) {
            NavigationLink {
                PlaylistDetailView(playlistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                logBrowseNavigation(surface: "FavoriteCategoryCard", kind: "collection", item: item, nav: nav)
            })
            .contextMenu { contextMenu(item) }
        } else {
            let isLoading = playingItemId == item.id
            let isDisabled = playingItemId != nil && !isLoading

            Button { playItem(item) } label: {
                cardContent(item)
                    .opacity(isDisabled ? 0.4 : 1)
                    .overlay(alignment: .top) {
                        if isLoading {
                            RoundedRectangle(cornerRadius: cat == .artist ? 70 : 10)
                                .fill(.ultraThinMaterial.opacity(0.85))
                                .frame(width: 140, height: 140)
                                .overlay {
                                    ProgressView()
                                        .tint(.white)
                                        .controlSize(.regular)
                                }
                                .transition(.opacity)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .animation(.easeInOut(duration: 0.2), value: playingItemId)
            .contextMenu { contextMenu(item) }
        }
    }

    private func cardContent(_ item: BrowseItem) -> some View {
        let cornerRadius: CGFloat = category == .artist ? 70 : 10
        let centerInCard = (category == .artist)
        let hAlign: HorizontalAlignment = centerInCard ? .center : .leading

        return VStack(alignment: hAlign, spacing: 0) {
            FavoriteCoverImageView(
                itemId: item.id,
                imageURLString: item.thumbnailArtworkURL,
                placeholderIcon: placeholderIcon(for: item)
            )
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            VStack(alignment: hAlign, spacing: 4) {
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(centerInCard ? .center : .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)

                subtitleLabel(for: item, centerInCard: centerInCard)
            }
            .padding(.top, 6)
        }
        .frame(width: 140)
    }

    // MARK: - Helpers

    private func albumNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ALBUM" {
            return searchManager.browseItemWithResolvedFavoriteURI(
                item,
                preserveArtworkSize: true
            ) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        var nav = searchManager.makeAlbumItem(
            objectId: ids.objectId, title: item.title, artist: item.artist,
            artURL: item.preferredDetailArtworkURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId,
            preserveArtworkSize: true)
        if let original = item.uri { nav.uri = original }
        return nav
    }

    private func artistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ARTIST" {
            return searchManager.browseItemWithResolvedFavoriteURI(
                item,
                preserveArtworkSize: true
            ) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        return searchManager.makeArtistItem(
            objectId: ids.objectId, name: item.title, artURL: item.preferredDetailArtworkURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId,
            preserveArtworkSize: true)
    }

    private func playlistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "PLAYLIST" {
            return searchManager.browseItemWithResolvedFavoriteURI(item) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        var nav = searchManager.makePlaylistItem(
            objectId: ids.objectId, title: item.title, artist: item.artist,
            artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
        if let original = item.uri { nav.uri = original }
        return nav
    }

    private func collectionNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "COLLECTION" { return item }
        if let ids = searchManager.parseCloudIds(from: item) {
            return BrowseItem(
                id: ids.objectId, title: item.title, artist: item.artist,
                album: "", albumArtURL: item.albumArtURL,
                detailArtworkURL: item.detailArtworkURL,
                uri: item.uri, isContainer: true,
                serviceId: searchManager.localSid(forCloudServiceId: ids.cloudServiceId),
                cloudType: "COLLECTION")
        }
        let sources = [item.playbackDescriptor.directURI, item.resMD, item.metaXML].compactMap { $0 }
        for src in sources where src.contains("libraryfolder") {
            if let range = src.range(of: "libraryfolder[^\"&<\\s]*", options: .regularExpression) {
                let objectId = String(src[range])
                return BrowseItem(
                    id: objectId, title: item.title, artist: item.artist,
                    album: "", albumArtURL: item.albumArtURL,
                    detailArtworkURL: item.detailArtworkURL,
                    uri: item.uri, isContainer: true,
                    serviceId: item.serviceId,
                    cloudType: "COLLECTION")
            }
        }
        return nil
    }

    private func logBrowseNavigation(surface: String, kind: String, item: BrowseItem, nav: BrowseItem) {
        SonosLog.debug(
            .navItem,
            "\(surface) navigation tapped kind=\(kind) title='\(item.title)' " +
            "favoriteCategory='\(item.favoriteCategory.rawValue)' " +
            "favoriteId=\(SonosLog.playbackLinkValue(item.cloudFavoriteId, maxLength: 240)) " +
            "itemId=\(SonosLog.playbackLinkValue(item.id, maxLength: 640)) " +
            "navId=\(SonosLog.playbackLinkValue(nav.id, maxLength: 640)) " +
            "itemCloudType='\(item.cloudType ?? "nil")' navCloudType='\(nav.cloudType ?? "nil")' " +
            "itemArt=\(SonosLog.playbackLinkValue(item.albumArtURL, maxLength: 640)) " +
            "navArt=\(SonosLog.playbackLinkValue(nav.albumArtURL, maxLength: 640)) " +
            "itemDetail=\(SonosLog.playbackLinkValue(item.detailArtworkURL, maxLength: 640)) " +
            "navDetail=\(SonosLog.playbackLinkValue(nav.detailArtworkURL, maxLength: 640)) " +
            "itemURI=\(SonosLog.playbackLinkValue(item.uri, maxLength: 640)) " +
            "navURI=\(SonosLog.playbackLinkValue(nav.uri, maxLength: 640))")
    }

    private func placeholderIcon(for item: BrowseItem) -> String {
        switch category {
        case .playlist: return "music.note.list"
        case .album: return "opticaldisc"
        case .song: return "music.note"
        case .station: return "antenna.radiowaves.left.and.right"
        case .artist: return "person.fill"
        case .collection: return "folder.fill"
        }
    }

    @ViewBuilder
    private func subtitleLabel(
        for item: BrowseItem,
        centerInCard: Bool
    ) -> some View {
        let subtitle: String = {
            switch category {
            case .playlist: return item.artist.isEmpty ? "Playlist" : item.artist
            case .album: return item.artist.isEmpty ? "Album" : "\(item.artist) · Album"
            case .song: return item.artist.isEmpty ? "Song" : "\(item.artist) · Song"
            case .station: return "Station"
            case .artist: return "Artist"
            case .collection: return item.artist.isEmpty ? "Collection" : item.artist
            }
        }()

        if !subtitle.isEmpty {
            HStack(spacing: 4) {
                if category == .station || category == .playlist || category == .album
                    || category == .song || category == .artist || category == .collection {
                    FavoritesStreamingGlyph(
                        cloudServiceId: searchManager.cloudServiceId(forFavorite: item),
                        displayNameHint: searchManager.serviceDisplayHint(forFavorite: item),
                        size: 10
                    )
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: centerInCard ? .center : .leading)
        }
    }

    private func playItem(_ item: BrowseItem) {
        guard playingItemId == nil else { return }
        playingItemId = item.id
        Task {
            await searchManager.playNow(item: item, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func handleFavoriteAction(_ item: BrowseItem) {
        if searchManager.appleMusicFavoriteResource(for: item) != nil {
            favoriteSheetItem = item
            return
        }

        Task { await toggleSonosFavorite(item) }
    }

    private func toggleSonosFavorite(_ item: BrowseItem) async {
        if searchManager.isFavorited(item) {
            _ = await searchManager.removeFromFavorites(item: item, manager: manager)
        } else {
            _ = await searchManager.addToFavorites(item: item, manager: manager)
        }
    }

    private func toggleAppleMusicFavorite(_ item: BrowseItem) async {
        _ = await searchManager.toggleAppleMusicFavorites(for: item)
    }

    @ViewBuilder
    private func contextMenu(_ item: BrowseItem) -> some View {
        let favorited = searchManager.isFavorited(item)
        let appleMusicResource = searchManager.appleMusicFavoriteResource(for: item)
        let kind = MusicResourceKind(cloudType: item.cloudType)

        if item.isArtist {
            Button {
                guard playingItemId == nil else { return }
                playingItemId = item.id
                Task {
                    await searchManager.startStation(item: item, manager: manager)
                    withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
                }
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
                    guard playingItemId == nil else { return }
                    playingItemId = item.id
                    Task {
                        await searchManager.startStation(item: item, manager: manager)
                        withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
                    }
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
