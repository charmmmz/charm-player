import Observation
import SwiftUI
import UIKit

extension SearchView {

    // MARK: - Browse Content

    var browseContent: some View {
        ScrollView {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowsePullDistancePreferenceKey.self,
                    value: max(0, Double(proxy.frame(in: .named(browseScrollCoordinateSpaceName)).minY))
                )
            }
            .frame(height: 0)

            VStack(alignment: .leading, spacing: 24) {
                if searchManager.showsBlockingBrowseLoader {
                    HStack {
                        Spacer()
                        ProgressView("Loading…")
                        Spacer()
                    }
                    .padding(.top, 40)
                } else {
                    if !searchManager.recentlyPlayed.isEmpty {
                        recentlyPlayedSection
                    }

                    let grouped = searchManager.groupedFavorites
                    if !grouped.isEmpty {
                        Text("Sonos Favorites")
                            .font(.title.bold())
                            .padding(.horizontal)

                        ForEach(grouped, id: \.category) { group in
                            favoriteSection(category: group.category, items: group.items)
                        }
                    }

                    if !searchManager.playlists.isEmpty {
                        sonosPlaylistsSection
                    }

                    if !searchManager.radio.isEmpty {
                        browseSection(title: "Radio Stations", items: searchManager.radio, horizontal: true)
                    }

                    if searchManager.errorMessage?.isEmpty == false {
                        sonosCloudErrorContent
                            .padding(.top, 20)
                    } else if searchManager.favorites.isEmpty && searchManager.playlists.isEmpty && searchManager.radio.isEmpty {
                        ContentUnavailableView("No Content",
                                               systemImage: "music.note.list",
                                               description: Text("Add favorites, playlists, or radio stations in the Sonos app."))
                        .padding(.top, 20)
                    }
                }
            }
            .padding(.vertical)
        }
        .coordinateSpace(name: browseScrollCoordinateSpaceName)
        .scrollDismissesKeyboard(.immediately)
        .onPreferenceChange(BrowsePullDistancePreferenceKey.self) { distance in
            pullRefreshController.handle(
                distance: distance,
                isExternalRefreshActive: searchManager.isLoadingBrowse,
                hasLoaded: searchManager.hasLoadedBrowseContent
            ) {
                await loadBrowseForCurrentBackend(forceRefresh: true)
            }
        }
        .overlay(alignment: .top) {
            BrowsePullRefreshIndicator(controller: pullRefreshController)
        }
    }

    // MARK: - Recently Played Section

    @ViewBuilder
    var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played")
                .font(.title3.bold())
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(searchManager.recentlyPlayed) { item in
                        // Categorization uses the item's own metadata (cloudType
                        // / URI), same logic as favorites — so tapping "Daniel
                        // Caesar" opens the artist page, tapping an album opens
                        // its detail page, etc.
                        browseCard(item, category: item.favoriteCategory)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Favorite Grouped Section

    @ViewBuilder
    func favoriteSection(category: BrowseItem.FavoriteCategory, items: [BrowseItem]) -> some View {
        // Songs render as a vertical list (tall-thumbnail + title + artist
        // row), since a large favorites library tends to produce dozens of
        // song entries that are awkward in a horizontal scroll. Other
        // categories (Playlists, Albums, Artists, Stations, Collections)
        // keep the horizontal card layout.
        let useListLayout = category == .song
        let previewCount = useListLayout ? 4 : 5
        let hasMore = items.count > previewCount
        let displayItems = hasMore ? Array(items.prefix(previewCount)) : items

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(category.rawValue)
                    .font(.title3.bold())
                Spacer()
                if hasMore {
                    NavigationLink {
                        FavoriteCategoryDetailView(
                            category: category,
                            items: items,
                            searchManager: searchManager,
                            manager: manager
                        )
                    } label: {
                        Text("View All")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            if useListLayout {
                LazyVStack(spacing: 0) {
                    ForEach(displayItems) { item in
                        browseRow(item)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(displayItems) { item in
                            browseCard(item, category: category)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Generic Section (for Sonos Playlists / Radio)

    @ViewBuilder
    func browseSection(title: String, items: [BrowseItem], horizontal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal)

            if horizontal {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items) { item in
                            browseCard(item, category: nil)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        browseRow(item)
                    }
                }
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    func browseCard(_ item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> some View {
        let cat = category ?? item.favoriteCategory

        if cat == .album, let nav = albumNavItem(for: item) {
            NavigationLink {
                AlbumDetailView(albumItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                browseCardContent(item, category: category)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                logBrowseNavigation(surface: "BrowseCard", kind: "album", item: item, nav: nav)
            })
            .contextMenu { itemContextMenu(item) }
        } else if cat == .artist {
            let nav = artistNavItem(for: item) ?? item
            NavigationLink {
                ArtistDetailView(artistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                browseCardContent(item, category: category)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                logBrowseNavigation(surface: "BrowseCard", kind: "artist", item: item, nav: nav)
            })
            .contextMenu { itemContextMenu(item) }
        } else if cat == .playlist, let nav = playlistNavItem(for: item) {
            NavigationLink {
                PlaylistDetailView(playlistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                browseCardContent(item, category: category)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                logBrowseNavigation(surface: "BrowseCard", kind: "playlist", item: item, nav: nav)
            })
            .contextMenu { itemContextMenu(item) }
        } else if cat == .collection, let nav = collectionNavItem(for: item) {
            NavigationLink {
                PlaylistDetailView(playlistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                browseCardContent(item, category: category)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                logBrowseNavigation(surface: "BrowseCard", kind: "collection", item: item, nav: nav)
            })
            .contextMenu { itemContextMenu(item) }
        } else {
            let isLoading = playingItemId == item.id
            let isDisabled = playingItemId != nil && !isLoading

            Button { playItem(item) } label: {
                browseCardContent(item, category: category)
                    .opacity(isDisabled ? 0.4 : 1)
                    .overlay(alignment: .top) {
                        let cr: CGFloat = cat == .artist ? 70 : 10
                        if isLoading {
                            RoundedRectangle(cornerRadius: cr)
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
            .contextMenu { itemContextMenu(item) }
        }
    }

    func browseCardContent(_ item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> some View {
        let cat = category ?? item.favoriteCategory
        let cornerRadius: CGFloat = cat == .artist ? 70 : 10

        return VStack(alignment: .leading, spacing: 6) {
            browseCardArtwork(item, category: category)
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            Text(item.title)
                .font(.caption.weight(.medium))
                // Single-line with trailing ellipsis keeps the card heights
                // uniform across the horizontal scroll — two-line wrapping
                // looked ragged when some titles fit and others didn't.
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            categoryLabel(for: item, category: category)
        }
        .frame(width: 140)
    }

    @ViewBuilder
    func browseCardArtwork(
        _ item: BrowseItem,
        category: BrowseItem.FavoriteCategory?
    ) -> some View {
        if let urlString = item.thumbnailArtworkURL,
           let url = URL(string: urlString) {
            RemoteArtworkImageView(url: url, contentMode: .fill) { _ in
                browseCardArtworkPlaceholder(item, category: category)
            }
        } else {
            browseCardArtworkPlaceholder(item, category: category)
        }
    }

    func browseCardArtworkPlaceholder(
        _ item: BrowseItem,
        category: BrowseItem.FavoriteCategory?
    ) -> some View {
        Rectangle().fill(.quaternary)
            .overlay {
                Image(systemName: placeholderIcon(for: item, category: category))
                    .foregroundStyle(.tertiary)
            }
    }

    /// Build a BrowseItem suitable for AlbumDetailView from a Favorite.
    func albumNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ALBUM" {
            // Cloud `listFavorites` rows and shortcut favorites can omit a top-level
            // playable URI; resolve the same way as add-to-favorites.
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
        // Preserve the Sonos browse URI as a safety net (it's known to work for
        // this specific favorite); fall back to the factory-built URI if absent.
        if let original = item.uri { nav.uri = original }
        return nav
    }

    /// Build a BrowseItem suitable for ArtistDetailView from a Favorite.
    func artistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ARTIST" {
            return searchManager.browseItemWithResolvedFavoriteURI(
                item,
                preserveArtworkSize: true
            ) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else {
            SonosLog.debug(.navItem, "artistNavItem parseCloudIds failed for '\(item.title)' uri=\(item.uri ?? "nil") resMD=\(item.resMD?.prefix(200) ?? "nil")")
            return nil
        }
        return searchManager.makeArtistItem(
            objectId: ids.objectId, name: item.title, artURL: item.preferredDetailArtworkURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId,
            preserveArtworkSize: true)
    }

    func playlistNavItem(for item: BrowseItem) -> BrowseItem? {
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

    func collectionNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "COLLECTION" { return item }
        if let ids = searchManager.parseCloudIds(from: item) {
            // COLLECTION is a generic library folder; we don't have a dedicated
            // factory because there's no canonical URI scheme — preserve the
            // existing browse URI verbatim and just normalize the type fields.
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

    func logBrowseNavigation(surface: String, kind: String, item: BrowseItem, nav: BrowseItem) {
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

    @ViewBuilder
    func categoryLabel(for item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> some View {
        let cat = category ?? item.favoriteCategory
        // Keep the subtitle to just the category name ("Album" / "Playlist" /
        // "Artist" / …) — no artist prefix. Matches Apple Music's home grid
        // and avoids the redundancy of "Yoga Lin · Album" beneath an album
        // whose title already carries the artist context (e.g. in Recently
        // Played). The artist name is still visible on detail pages and in
        // the vertical track rows where it's actually informational.
        let subtitle: String = {
            switch cat {
            case .playlist:   return "Playlist"
            case .album:      return "Album"
            case .song:       return "Song"
            case .station:    return "Station"
            case .artist:     return "Artist"
            case .collection: return "Collection"
            }
        }()

        if !subtitle.isEmpty {
            HStack(spacing: 4) {
                if cat == .station || cat == .playlist || cat == .album
                    || cat == .collection || cat == .song || cat == .artist {
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
        }
    }

    func placeholderIcon(for item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> String {
        let cat = category ?? item.favoriteCategory
        switch cat {
        case .playlist: return "music.note.list"
        case .album: return "opticaldisc"
        case .song: return "music.note"
        case .station: return "antenna.radiowaves.left.and.right"
        case .artist: return "person.fill"
        case .collection: return "folder.fill"
        }
    }

    func browseRow(_ item: BrowseItem) -> some View {
        let isLoading = playingItemId == item.id
        let isDisabled = playingItemId != nil && !isLoading

        return Button {
            playItem(item)
        } label: {
            browseRowLabel(item, isLoading: isLoading, isDisabled: isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(.easeInOut(duration: 0.2), value: playingItemId)
        .contextMenu { itemContextMenu(item) }
    }

    /// The visual content of a browse row, factored out so it can sit inside
    /// either a `Button` (tap-to-play: songs) or a `NavigationLink`
    /// (tap-to-open: Sonos Playlists) without duplicating layout.
    ///
    /// Songs (non-containers) render an `ellipsis` menu on the right that
    /// surfaces Play Next / Add to Queue / Favorite from `itemContextMenu`;
    /// containers keep the simpler `chevron.right` affordance.
    @ViewBuilder
    func browseRowLabel(_ item: BrowseItem, isLoading: Bool, isDisabled: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                AsyncImage(url: URL(string: item.thumbnailArtworkURL ?? "")) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay {
                                Image(systemName: item.isContainer ? "music.note.list" : "music.note")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if isLoading {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.ultraThinMaterial.opacity(0.85))
                        .frame(width: 48, height: 48)
                        .overlay {
                            ProgressView()
                                .tint(.white)
                                .controlSize(.small)
                        }
                        .transition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if !item.artist.isEmpty {
                    Text(item.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(.secondary)
                    .controlSize(.small)
            } else if item.isContainer {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Menu {
                    itemContextMenu(item)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Without this, SwiftUI's default hit-test shape for an HStack with
        // a `Spacer()` skips the empty gap in the middle — so taps landing
        // between the thumbnail and the trailing chevron/ellipsis fall
        // through. Forcing a rect makes the whole row selectable the way
        // List rows behave.
        .contentShape(Rectangle())
        .opacity(isDisabled ? 0.4 : 1)
    }

    // MARK: - Sonos Playlists Section

    /// Sonos system playlists (`SQ:<n>`) are local to the household and have
    /// no Cloud API representation, so tapping them opens a dedicated UPnP
    /// detail view instead of going through `PlaylistDetailView` (which is
    /// cloud-only). Tap-to-play is replaced by tap-to-open-detail so users
    /// can preview and pick individual tracks, matching the rest of the app.
    @ViewBuilder
    var sonosPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sonos Playlists")
                .font(.title3.bold())
                .padding(.horizontal)

            LazyVStack(spacing: 0) {
                ForEach(searchManager.playlists) { item in
                    NavigationLink {
                        SonosLocalPlaylistDetailView(
                            playlistItem: item,
                            searchManager: searchManager,
                            manager: manager
                        )
                    } label: {
                        browseRowLabel(item, isLoading: false, isDisabled: false)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        logBrowseNavigation(surface: "SonosPlaylistsSection", kind: "localPlaylist", item: item, nav: item)
                    })
                    .contextMenu { itemContextMenu(item) }
                }
            }
        }
    }

}
