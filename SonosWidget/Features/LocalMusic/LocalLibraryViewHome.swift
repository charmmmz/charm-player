import MusicKit
import Observation
import SwiftUI


extension LocalLibraryView {

    var isAccessDenied: Bool {
        store.authorizationStatus == .denied || store.authorizationStatus == .restricted
    }

    var backgroundLayer: some View {
        SonosArtworkBackground(
            image: manager.albumArtImage,
            fallbackColor: manager.albumArtDominantColor
        )
        .animation(.easeInOut(duration: 0.8), value: manager.trackInfo?.albumArtURL)
        .animation(.easeInOut(duration: 0.8), value: manager.albumArtDominantColor)
    }

    var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(.white.opacity(0.72))

            Text("Loading library")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 96)
    }

    var deniedContent: some View {
        ContentUnavailableView {
            Label("Apple Music Access Needed", systemImage: "music.note")
        } description: {
            Text("Allow access to load and play your Apple Music library.")
        } actions: {
            Button("Allow Access") {
                Task { await store.refresh(source: .recovery) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    var emptyLibraryContent: some View {
        ContentUnavailableView {
            Label("No Library Items", systemImage: "music.note.list")
        } description: {
            Text("Add music in Apple Music, then refresh this page.")
        } actions: {
            Button("Refresh") {
                Task { await store.refresh(source: .recovery) }
            }
            .buttonStyle(.bordered)
        }
    }

    var content: some View {
        ScrollView {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LocalLibraryPullDistancePreferenceKey.self,
                    value: max(0, Double(proxy.frame(in: .named(scrollCoordinateSpaceName)).minY)))
            }
            .frame(height: 0)

            LazyVStack(alignment: .leading, spacing: 22) {
                if let errorMessage = store.errorMessage {
                    statusBanner(errorMessage)
                }

                if isSearchingLibrary {
                    searchResultsContent
                } else {
                    serviceHomeContent
                }
            }
            .padding(.vertical, 12)
        }
        .coordinateSpace(name: scrollCoordinateSpaceName)
        .scrollDismissesKeyboard(.immediately)
        .onPreferenceChange(LocalLibraryPullDistancePreferenceKey.self) { distance in
            pullRefreshController.handle(
                distance: distance,
                isExternalRefreshActive: store.isLoading,
                hasLoaded: store.hasLoaded
            ) {
                await store.refresh(source: .pullToRefresh)
            }
        }
        .overlay(alignment: .top) {
            LocalLibraryPullRefreshIndicator(controller: pullRefreshController)
        }
    }

    @ViewBuilder
    var serviceHomeContent: some View {
        librarySection

        let recentlyAdded = recentlyAddedCards
        if !recentlyAdded.isEmpty {
            horizontalSection(
                kind: .recentlyAdded,
                items: recentlyAdded
            )
        }

        if !store.recentlyPlayed.isEmpty {
            horizontalSection(
                kind: .recentlyPlayed,
                items: store.recentlyPlayed.map {
                    LocalServiceCardPresentation(item: .recentlyPlayed($0))
                }
            )
        }

        recommendationsContent
    }

    @ViewBuilder
    var recommendationsContent: some View {
        ForEach(Array(store.recommendations.prefix(5))) { recommendation in
            let cards = recommendationCards(for: recommendation)
            if !cards.isEmpty {
                horizontalSection(
                    title: recommendation.title ?? LocalServiceSectionKind.recommendations.title,
                    subtitle: recommendation.reason,
                    systemImage: nil,
                    items: cards
                )
            }
        }
    }

    var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(kind: .library)
            libraryCategoryRows(showEmptyCategories: true)
        }
    }

    var searchResultsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasSubmittedSearch {
                switch searchScope {
                case .library:
                    if LocalServiceSearchPresentation.showsGenericSearchResultsHeading(
                        scope: searchScope,
                        hasSubmittedSearch: hasSubmittedSearch
                    ) {
                        searchResultsHeader
                    }
                    librarySearchResultsContent
                case .appleMusic:
                    catalogSearchResultsContent
                }
            }
        }
    }

    var searchResultsHeader: some View {
        HStack {
            Label("Search Results", systemImage: "magnifyingglass")
                .font(.title3.weight(.semibold))
            Spacer()
            if store.isSearching {
                ProgressView()
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    var librarySearchResultsContent: some View {
        if store.displayedSnapshot.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Try a different search term.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                librarySearchCategoryPicker
                librarySearchResultList(librarySearchCategory)
            }
        }
    }

    var librarySearchCategoryPicker: some View {
        categoryPicker(
            selection: Binding(
                get: { librarySearchCategory },
                set: { librarySearchCategory = $0 }
            ),
            namespace: librarySearchCategorySelectionNamespace,
            matchedGeometryID: "local-service-library-search-category"
        )
    }

    @ViewBuilder
    var catalogSearchResultsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            catalogCategoryPicker

            if store.isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.top, 40)
            } else if store.catalogSearchResults.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term.")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                let items = store.catalogSearchResults.items(for: catalogSearchCategory)
                if items.isEmpty {
                    ContentUnavailableView(
                        "No \(catalogSearchCategory.title)",
                        systemImage: catalogSearchCategory.systemImage,
                        description: Text("Try a different search term or category.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    catalogSearchItemList(items)
                }
            }
        }
    }

    var catalogCategoryPicker: some View {
        categoryPicker(
            selection: Binding(
                get: { catalogSearchCategory },
                set: { catalogSearchCategory = $0 }
            ),
            namespace: catalogCategorySelectionNamespace,
            matchedGeometryID: "local-service-catalog-category"
        )
    }

    func categoryPicker(
        selection: Binding<LocalLibraryCategory>,
        namespace: Namespace.ID,
        matchedGeometryID: String
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(LocalServiceSearchPresentation.catalogCategoryOrder) { category in
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            selection.wrappedValue = category
                        }
                    } label: {
                        Text(category.title)
                            .font(.subheadline.weight(selection.wrappedValue == category ? .semibold : .medium))
                            .foregroundStyle(selection.wrappedValue == category ? .white : .primary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background {
                                if selection.wrappedValue == category {
                                    Capsule()
                                        .fill(Color.pink)
                                        .matchedGeometryEffect(
                                            id: matchedGeometryID,
                                            in: namespace
                                        )
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    func librarySearchResultList(_ category: LocalLibraryCategory) -> some View {
        switch category {
        case .songs:
            songList(store.displayedSnapshot.songs)
        case .albums:
            albumList(store.displayedSnapshot.albums)
        case .artists:
            artistList(store.displayedSnapshot.artists)
        case .playlists:
            playlistList(store.displayedSnapshot.playlists)
        }
    }

    @ViewBuilder
    func catalogSearchItemList(_ items: [AppleMusicCatalogSearchItem]) -> some View {
        ForEach(items) { item in
            catalogSearchRow(item)
        }
    }

    @ViewBuilder
    func catalogSearchRow(_ item: AppleMusicCatalogSearchItem) -> some View {
        let playable = LocalServiceAppleMusicPlayable.make(catalogItem: item)
        let displayID = "catalog-\(item.sonosPlayableObjectID)"
        let isLoading = store.isStartingPlayback && store.activePlaybackItemID == displayID

        switch LocalServiceCatalogSearchInteraction.primaryAction(for: item.type) {
        case .navigate:
            NavigationLink {
                LocalMusicCatalogSearchDetailView(
                    item: item,
                    store: store,
                    manager: manager,
                    searchManager: searchManager)
            } label: {
                catalogSearchRowContent(item, accessory: .chevron)
            }
            .buttonStyle(.plain)
            .contextMenu {
                localResourceContextMenu(
                    playable: playable,
                    displayID: displayID,
                    kind: catalogResourceKind(for: item.type),
                    fallbackKind: catalogPlayableKind(for: item.type),
                    fallbackTitle: item.title,
                    fallbackArtist: item.artist,
                    fallbackAlbum: item.album
                )
            }
        case .play:
            Button {
                Task {
                    await store.playOnSonos(
                        playable: playable,
                        displayID: displayID,
                        fallbackKind: catalogPlayableKind(for: item.type),
                        fallbackTitle: item.title,
                        fallbackArtist: item.artist,
                        fallbackAlbum: item.album,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                catalogSearchRowContent(item, accessory: isLoading ? .progress : .play)
            }
            .buttonStyle(.plain)
            .disabled(store.isStartingPlayback)
            .contextMenu {
                localResourceContextMenu(
                    playable: playable,
                    displayID: displayID,
                    kind: catalogResourceKind(for: item.type),
                    fallbackKind: catalogPlayableKind(for: item.type),
                    fallbackTitle: item.title,
                    fallbackArtist: item.artist,
                    fallbackAlbum: item.album
                )
            }
        }
    }

    func catalogSearchRowContent(
        _ item: AppleMusicCatalogSearchItem,
        accessory: LocalServiceRowAccessory
    ) -> some View {
        let rowText = LocalServiceSearchPresentation.catalogRowText(for: item)
        return rowContent(
            artwork: nil,
            artworkURL: item.artworkURLString.flatMap(URL.init(string:)),
            title: item.title,
            subtitle: rowText.subtitle,
            detail: rowText.detail,
            fallbackSystemImage: catalogFallbackSystemImage(for: item.type),
            accessory: accessory,
            artworkStyle: item.type == .artist ? .artistAvatar : .square
        )
    }

    func catalogResourceKind(for type: AppleMusicCatalogItemType) -> MusicResourceKind {
        switch type {
        case .song:
            return .song
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        }
    }

    func catalogPlayableKind(for type: AppleMusicCatalogItemType) -> LocalServiceAppleMusicPlayable.Kind {
        switch type {
        case .song:
            return .song
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        }
    }

    func catalogFallbackSystemImage(for type: AppleMusicCatalogItemType) -> String {
        switch type {
        case .song:
            return "music.note"
        case .album:
            return "square.stack"
        case .artist:
            return "music.mic"
        case .playlist:
            return "music.note.list"
        }
    }

    func libraryCategoryRows(showEmptyCategories: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(visibleLibraryCategories(showEmptyCategories: showEmptyCategories)) { category in
                NavigationLink(value: category) {
                    libraryCategoryRow(category)
                }
                .buttonStyle(.plain)

                if category != visibleLibraryCategories(showEmptyCategories: showEmptyCategories).last {
                    Divider()
                        .background(.white.opacity(0.16))
                        .padding(.leading, 52)
                }
            }
        }
        .padding(.horizontal)
    }

    func visibleLibraryCategories(showEmptyCategories: Bool) -> [LocalLibraryCategory] {
        LocalLibraryCategory.homeOrder.filter { category in
            showEmptyCategories || store.summary.count(for: category) > 0
        }
    }

    func libraryCategoryRow(_ category: LocalLibraryCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.pink)
                .frame(width: 28, height: 38)

            Text(category.title)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }

    var recentlyAddedCards: [LocalServiceCardPresentation] {
        store.recentlyAddedContent.items.map { item in
            switch item {
            case .album(let album): return LocalServiceCardPresentation(item: .album(album))
            case .playlist(let playlist): return LocalServiceCardPresentation(item: .playlist(playlist))
            case .song(let song): return LocalServiceCardPresentation(item: .song(song))
            }
        }
    }

    func recommendationCards(for recommendation: MusicPersonalRecommendation) -> [LocalServiceCardPresentation] {
        let directItems = Array(recommendation.items)
            .map { LocalServiceCardPresentation(item: .recommendation($0)) }
        if !directItems.isEmpty {
            return Array(directItems.prefix(16))
        }

        var fallback: [LocalServiceCardPresentation] = []
        fallback.append(contentsOf: recommendation.albums.map { LocalServiceCardPresentation(item: .album($0)) })
        fallback.append(contentsOf: recommendation.playlists.map { LocalServiceCardPresentation(item: .playlist($0)) })
        fallback.append(contentsOf: recommendation.stations.map { LocalServiceCardPresentation(item: .station($0)) })
        return Array(fallback.prefix(16))
    }

    func horizontalSection(
        kind: LocalServiceSectionKind,
        items: [LocalServiceCardPresentation]
    ) -> some View {
        horizontalSection(
            title: kind.title,
            subtitle: nil,
            systemImage: kind.headerSystemImage,
            items: items
        )
    }

    func horizontalSection(
        title: String,
        subtitle: String?,
        systemImage: String?,
        items: [LocalServiceCardPresentation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title, subtitle: subtitle, systemImage: systemImage)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        card(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    func sectionHeader(kind: LocalServiceSectionKind) -> some View {
        sectionHeader(title: kind.title, subtitle: nil, systemImage: kind.headerSystemImage)
    }

    func sectionHeader(title: String, subtitle: String?, systemImage: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.title3.weight(.semibold))
            } else {
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal)
        .padding(.leading, 8)
    }

    func localResource(
        id: String,
        kind: MusicResourceKind,
        title: String,
        subtitle: String,
        detail: String?,
        fallbackSystemImage: String,
        accessory: MusicResourceAccessory,
        isQueueable: Bool
    ) -> MusicResourcePresentation {
        MusicResourcePresentation(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            detail: detail,
            fallbackSystemImage: fallbackSystemImage,
            accessory: accessory,
            isQueueable: isQueueable
        )
    }

    func resource(
        for item: LocalServiceCardItem,
        playable: LocalServiceAppleMusicPlayable?
    ) -> MusicResourcePresentation {
        localResource(
            id: item.id,
            kind: item.resourceKind,
            title: item.title,
            subtitle: item.subtitle,
            detail: nil,
            fallbackSystemImage: item.fallbackSystemImage,
            accessory: item.resourceKind == .song || item.resourceKind == .station ? .play : .chevron,
            isQueueable: playable != nil
        )
    }

    @ViewBuilder
    func localResourceContextMenu(
        playable: LocalServiceAppleMusicPlayable?,
        displayID: String,
        kind: MusicResourceKind,
        fallbackKind: LocalServiceAppleMusicPlayable.Kind?,
        fallbackTitle: String,
        fallbackArtist: String? = nil,
        fallbackAlbum: String? = nil
    ) -> some View {
        MusicResourceContextMenu(
            actions: MusicResourceActionPolicy.actions(
                kind: kind,
                isQueueable: playable != nil || fallbackKind != nil,
                supportsStation: kind == .artist,
                isAppleMusicFavoriteAvailable: kind != .song ||
                    AppleMusicFavoriteResource.fromLocalServicePlayable(playable) != nil
            )
        ) { action in
            Task {
                switch action {
                case .favorite(.sonos, _, _):
                    await store.toggleSonosFavorite(
                        playable: playable,
                        displayID: displayID,
                        fallbackKind: fallbackKind,
                        fallbackTitle: fallbackTitle,
                        fallbackArtist: fallbackArtist,
                        fallbackAlbum: fallbackAlbum,
                        manager: manager,
                        searchManager: searchManager)
                    return
                case .favorite(.appleMusic, _, _):
                    guard let resource = AppleMusicFavoriteResource.fromLocalServicePlayable(playable) else {
                        return
                    }
                    _ = await searchManager.toggleAppleMusicFavorites(resource: resource)
                    return
                case .playNow, .playNext, .addToQueue, .startStation:
                    break
                }

                await store.performSonosQueueAction(
                    action,
                    playable: playable,
                    displayID: displayID,
                    fallbackKind: fallbackKind,
                    fallbackTitle: fallbackTitle,
                    fallbackArtist: fallbackArtist,
                    fallbackAlbum: fallbackAlbum,
                    manager: manager,
                    searchManager: searchManager
                )
            }
        }
    }

    func playableWithPreferredPlaybackArtwork(
        _ playable: LocalServiceAppleMusicPlayable?,
        artworkURL: URL?
    ) -> LocalServiceAppleMusicPlayable? {
        guard let playable else { return nil }
        guard LocalServicePlaybackArtworkPolicy.shouldPreferCatalogArtwork(
            kind: playable.kind,
            existingArtworkURLString: playable.artworkURLString
        ) else {
            return playable
        }
        return playable.withPreferredArtworkURLString(artworkURL?.absoluteString)
    }
}
