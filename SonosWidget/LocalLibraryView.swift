import MusicKit
import SwiftUI

struct LocalLibraryView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager
    @State private var store = LocalLibraryStore()
    @State private var searchText = ""
    @State private var searchScope: LocalServiceSearchScope = .library
    @State private var submittedSearchText = ""
    @State private var searchSubmissionID = 0
    @State private var hasSubmittedSearch = false
    @State private var catalogSearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
    @State private var librarySearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
    @State private var categoryDetailSearchText = ""
    @State private var categorySortSelections: [LocalLibraryCategory: LocalLibraryCategorySortOption] = [:]
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isCategorySearchFieldFocused: Bool
    @Namespace private var searchScopeSelectionNamespace
    @Namespace private var catalogCategorySelectionNamespace
    @Namespace private var librarySearchCategorySelectionNamespace

    private var isSearchingLibrary: Bool {
        !trimmedSearchText.isEmpty
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCategoryDetailSearchText: String {
        categoryDetailSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowSearchScopeTabs: Bool {
        isSearchFieldFocused || (isSearchingLibrary && !hasSubmittedSearch)
    }

    private var shouldShowSubmittedSearchOverlay: Bool {
        hasSubmittedSearch
            && !isSearchFieldFocused
            && trimmedSearchText == submittedSearchText
            && !submittedSearchText.isEmpty
    }

    private var shouldUseExpandedSearchFieldStyle: Bool {
        isSearchFieldFocused || isSearchingLibrary || hasSubmittedSearch
    }

    var body: some View {
        NavigationStack {
            Group {
                if isAccessDenied {
                    deniedContent
                } else if store.isLoading && !store.hasLoaded {
                    loadingContent
                } else if !store.hasHomeContent && trimmedSearchText.isEmpty {
                    emptyLibraryContent
                } else {
                    content
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: LocalLibraryCategory.self) { category in
                libraryCategoryDetail(category)
                    .background(backgroundLayer.ignoresSafeArea())
                    .preferredColorScheme(.dark)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .background(backgroundLayer.ignoresSafeArea())
            .onChange(of: searchText) { _, newValue in
                handleSearchTextChanged(newValue)
            }
            .onChange(of: searchScope) { _, _ in
                handleSearchScopeChanged()
            }
            .onChange(of: store.catalogSearchResults.items) { _, _ in
                selectCatalogCategoryForAvailableResults()
            }
            .onChange(of: store.summary) { _, _ in
                selectLibrarySearchCategoryForAvailableResults()
            }
            .task {
                await store.loadIfNeeded()
            }
            .task(id: "\(searchScope.rawValue):\(submittedSearchText):\(searchSubmissionID)") {
                await store.search(term: submittedSearchText, scope: searchScope)
            }
            .refreshable {
                await store.reload()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                    .accessibilityLabel("Refresh Local Service")
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func submitSearch() {
        let trimmed = trimmedSearchText
        guard !trimmed.isEmpty else {
            resetSubmittedSearch()
            return
        }

        if searchText != trimmed {
            searchText = trimmed
        }

        submittedSearchText = trimmed
        hasSubmittedSearch = true
        searchSubmissionID += 1
        isSearchFieldFocused = false

        if searchScope == .appleMusic {
            catalogSearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        } else {
            librarySearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        }
    }

    private func handleSearchTextChanged(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetSubmittedSearch()
            return
        }

        if !submittedSearchText.isEmpty && trimmed != submittedSearchText {
            resetSubmittedSearch()
        }
    }

    private func handleSearchScopeChanged() {
        if searchScope == .appleMusic {
            catalogSearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        } else {
            librarySearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        }

        if hasSubmittedSearch && !submittedSearchText.isEmpty {
            searchSubmissionID += 1
        }
    }

    private func clearSearch() {
        searchText = ""
        resetSubmittedSearch()
        isSearchFieldFocused = true
    }

    private func resetSubmittedSearch() {
        let hadSubmittedSearch = hasSubmittedSearch || !submittedSearchText.isEmpty
        hasSubmittedSearch = false
        submittedSearchText = ""
        catalogSearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        librarySearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists

        if hadSubmittedSearch {
            searchSubmissionID += 1
        }
    }

    private func selectCatalogCategoryForAvailableResults() {
        guard searchScope == .appleMusic, hasSubmittedSearch else { return }
        guard store.catalogSearchResults.count(for: catalogSearchCategory) == 0 else { return }
        guard let firstCategoryWithResults = LocalServiceSearchPresentation.catalogCategoryOrder.first(
            where: { store.catalogSearchResults.count(for: $0) > 0 }
        ) else {
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            catalogSearchCategory = firstCategoryWithResults
        }
    }

    private func selectLibrarySearchCategoryForAvailableResults() {
        guard searchScope == .library, hasSubmittedSearch else { return }
        guard store.displayedSnapshot.summary.count(for: librarySearchCategory) == 0 else { return }
        guard let firstCategoryWithResults = LocalServiceSearchPresentation.catalogCategoryOrder.first(
            where: { store.displayedSnapshot.summary.count(for: $0) > 0 }
        ) else {
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            librarySearchCategory = firstCategoryWithResults
        }
    }

    private var isAccessDenied: Bool {
        store.authorizationStatus == .denied || store.authorizationStatus == .restricted
    }

    private var backgroundLayer: some View {
        SonosArtworkBackground(
            image: manager.albumArtImage,
            fallbackColor: manager.albumArtDominantColor
        )
        .animation(.easeInOut(duration: 0.8), value: manager.trackInfo?.albumArtURL)
        .animation(.easeInOut(duration: 0.8), value: manager.albumArtDominantColor)
    }

    private var loadingContent: some View {
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

    private var deniedContent: some View {
        ContentUnavailableView {
            Label("Apple Music Access Needed", systemImage: "music.note")
        } description: {
            Text("Allow access to load and play your Apple Music library.")
        } actions: {
            Button("Allow Access") {
                Task { await store.reload() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyLibraryContent: some View {
        ContentUnavailableView {
            Label("No Library Items", systemImage: "music.note.list")
        } description: {
            Text("Add music in Apple Music, then refresh this page.")
        } actions: {
            Button("Refresh") {
                Task { await store.reload() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                localSearchControls

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
        .scrollDismissesKeyboard(.immediately)
    }

    private var localSearchControls: some View {
        VStack(spacing: 10) {
            localSearchField

            if shouldShowSearchScopeTabs {
                searchScopePicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
        .padding(.bottom, shouldShowSearchScopeTabs ? 10 : 6)
        .animation(
            .spring(response: 0.32, dampingFraction: 0.86),
            value: shouldShowSearchScopeTabs
        )
    }

    private var localSearchField: some View {
        let isExpandedStyle = shouldUseExpandedSearchFieldStyle

        return HStack(spacing: isExpandedStyle ? 10 : 8) {
            Image(systemName: "magnifyingglass")
                .font(isExpandedStyle ? .title3.weight(.semibold) : .subheadline)
                .foregroundStyle(.secondary)
                .frame(width: isExpandedStyle ? 24 : 20)

            ZStack(alignment: .leading) {
                submittedSearchFieldOverlay

                TextField(
                    "",
                    text: $searchText,
                    prompt: Text(LocalServiceSearchPresentation.prompt(for: searchScope))
                )
                .focused($isSearchFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    submitSearch()
                }
                .opacity(shouldShowSubmittedSearchOverlay ? 0.01 : 1)
            }
            .font(isExpandedStyle ? .title3 : .subheadline)
            .frame(minHeight: isExpandedStyle ? 30 : 22)

            if !searchText.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(isExpandedStyle ? .title3.weight(.semibold) : .subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, isExpandedStyle ? 16 : 12)
        .padding(.vertical, isExpandedStyle ? 12 : 10)
        .background(
            .white.opacity(isSearchFieldFocused ? 0.16 : 0.10),
            in: RoundedRectangle(
                cornerRadius: isExpandedStyle ? 999 : 12,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: isExpandedStyle ? 999 : 12,
                style: .continuous
            )
                .stroke(.white.opacity(isSearchFieldFocused ? 0.22 : 0.08), lineWidth: 1)
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: isExpandedStyle ? 999 : 12,
                style: .continuous
            )
        )
        .onTapGesture {
            isSearchFieldFocused = true
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var submittedSearchFieldOverlay: some View {
        if shouldShowSubmittedSearchOverlay,
           let display = LocalServiceSearchPresentation.submittedFieldDisplay(
            for: submittedSearchText,
            scope: searchScope
           ) {
            HStack(spacing: 0) {
                Text(display.term)
                    .foregroundStyle(.primary)
                Text(display.scopeHint)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var serviceHomeContent: some View {
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
                items: store.recentlyPlayed.map(LocalServiceCardItem.recentlyPlayed)
            )
        }

        recommendationsContent
    }

    @ViewBuilder
    private var recommendationsContent: some View {
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

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(kind: .library)
            libraryCategoryRows(showEmptyCategories: true)
        }
    }

    private var searchResultsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasSubmittedSearch {
                switch searchScope {
                case .library:
                    searchResultsHeader
                    librarySearchResultsContent
                case .appleMusic:
                    catalogSearchResultsContent
                }
            }
        }
    }

    private var searchResultsHeader: some View {
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

    private var searchScopePicker: some View {
        HStack(spacing: 0) {
            ForEach(LocalServiceSearchScope.allCases) { scope in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                        searchScope = scope
                    }
                } label: {
                    Text(scope.title)
                        .font(.headline.weight(searchScope == scope ? .semibold : .medium))
                        .foregroundStyle(searchScope == scope ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if searchScope == scope {
                                Capsule()
                                    .fill(.white.opacity(0.22))
                                    .matchedGeometryEffect(
                                        id: "local-service-search-scope",
                                        in: searchScopeSelectionNamespace
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.white.opacity(0.09), in: Capsule())
        .padding(.horizontal)
    }

    @ViewBuilder
    private var librarySearchResultsContent: some View {
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

    private var librarySearchCategoryPicker: some View {
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
    private var catalogSearchResultsContent: some View {
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

    private var catalogCategoryPicker: some View {
        categoryPicker(
            selection: Binding(
                get: { catalogSearchCategory },
                set: { catalogSearchCategory = $0 }
            ),
            namespace: catalogCategorySelectionNamespace,
            matchedGeometryID: "local-service-catalog-category"
        )
    }

    private func categoryPicker(
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
    private func librarySearchResultList(_ category: LocalLibraryCategory) -> some View {
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
    private func catalogSearchItemList(_ items: [AppleMusicCatalogSearchItem]) -> some View {
        ForEach(items) { item in
            catalogSearchRow(item)
        }
    }

    @ViewBuilder
    private func catalogSearchRow(_ item: AppleMusicCatalogSearchItem) -> some View {
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

    private func catalogSearchRowContent(
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

    private func catalogResourceKind(for type: AppleMusicCatalogItemType) -> MusicResourceKind {
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

    private func catalogPlayableKind(for type: AppleMusicCatalogItemType) -> LocalServiceAppleMusicPlayable.Kind {
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

    private func catalogFallbackSystemImage(for type: AppleMusicCatalogItemType) -> String {
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

    private func libraryCategoryRows(showEmptyCategories: Bool) -> some View {
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

    private func visibleLibraryCategories(showEmptyCategories: Bool) -> [LocalLibraryCategory] {
        LocalLibraryCategory.homeOrder.filter { category in
            showEmptyCategories || store.summary.count(for: category) > 0
        }
    }

    private func libraryCategoryRow(_ category: LocalLibraryCategory) -> some View {
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

    private var recentlyAddedCards: [LocalServiceCardItem] {
        var datedItems: [(Date?, LocalServiceCardItem)] = []
        datedItems.append(contentsOf: store.snapshot.albums.map { ($0.libraryAddedDate, .album($0)) })
        datedItems.append(contentsOf: store.snapshot.playlists.map { ($0.libraryAddedDate, .playlist($0)) })
        datedItems.append(contentsOf: store.snapshot.songs.map { ($0.libraryAddedDate, .song($0)) })

        return Array(
            datedItems
                .sorted { lhs, rhs in
                    switch (lhs.0, rhs.0) {
                    case let (left?, right?):
                        return left > right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        return lhs.1.title < rhs.1.title
                    }
                }
                .map(\.1)
                .prefix(16)
        )
    }

    private func recommendationCards(for recommendation: MusicPersonalRecommendation) -> [LocalServiceCardItem] {
        let directItems = Array(recommendation.items).map(LocalServiceCardItem.recommendation)
        if !directItems.isEmpty {
            return Array(directItems.prefix(16))
        }

        var fallback: [LocalServiceCardItem] = []
        fallback.append(contentsOf: recommendation.albums.map(LocalServiceCardItem.album))
        fallback.append(contentsOf: recommendation.playlists.map(LocalServiceCardItem.playlist))
        fallback.append(contentsOf: recommendation.stations.map(LocalServiceCardItem.station))
        return Array(fallback.prefix(16))
    }

    private func horizontalSection(
        kind: LocalServiceSectionKind,
        items: [LocalServiceCardItem]
    ) -> some View {
        horizontalSection(
            title: kind.title,
            subtitle: nil,
            systemImage: kind.headerSystemImage,
            items: items
        )
    }

    private func horizontalSection(
        title: String,
        subtitle: String?,
        systemImage: String?,
        items: [LocalServiceCardItem]
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

    private func sectionHeader(kind: LocalServiceSectionKind) -> some View {
        sectionHeader(title: kind.title, subtitle: nil, systemImage: kind.headerSystemImage)
    }

    private func sectionHeader(title: String, subtitle: String?, systemImage: String?) -> some View {
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

    private func localResource(
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

    private func resource(for item: LocalServiceCardItem) -> MusicResourcePresentation {
        localResource(
            id: item.id,
            kind: item.resourceKind,
            title: item.title,
            subtitle: item.subtitle,
            detail: nil,
            fallbackSystemImage: item.fallbackSystemImage,
            accessory: item.resourceKind == .song || item.resourceKind == .station ? .play : .chevron,
            isQueueable: item.playable != nil
        )
    }

    @ViewBuilder
    private func localResourceContextMenu(
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
                supportsStation: kind == .artist
            )
        ) { action in
            Task {
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

    @ViewBuilder
    private func card(_ item: LocalServiceCardItem) -> some View {
        switch item {
        case .album(let album):
            NavigationLink {
                LocalMusicAlbumDetailView(
                    album: album,
                    store: store,
                    manager: manager,
                    searchManager: searchManager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
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
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .recentlyPlayed(let recentlyPlayed):
            recentlyPlayedCard(recentlyPlayed, item: item)
        case .recommendation(let recommendation):
            recommendationCard(recommendation, item: item)
        case .song(let song):
            Button {
                Task {
                    await store.playOnSonos(
                        playable: LocalServiceAppleMusicPlayable.make(song: song),
                        displayID: song.id.rawValue,
                        fallbackKind: .song,
                        fallbackTitle: song.title,
                        fallbackArtist: song.artistName,
                        fallbackAlbum: song.albumTitle,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .disabled(store.isStartingPlayback)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
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
                    cardContent(item)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .contextMenu {
                    localResourceContextMenu(
                        playable: item.playable,
                        displayID: item.playbackID,
                        kind: item.resourceKind,
                        fallbackKind: item.playable?.kind,
                        fallbackTitle: item.title,
                        fallbackArtist: item.subtitle,
                        fallbackAlbum: item.title
                    )
                }
            } else {
                Button {
                    Task {
                        await store.playOnSonos(
                            playable: LocalServiceAppleMusicPlayable.make(artist: artist),
                            displayID: artist.id.rawValue,
                            fallbackKind: .artist,
                            fallbackTitle: artist.name,
                            fallbackArtist: artist.name,
                            manager: manager,
                            searchManager: searchManager)
                    }
                } label: {
                    cardContent(item)
                }
                .buttonStyle(.plain)
                .disabled(store.isStartingPlayback)
                .contentShape(Rectangle())
                .contextMenu {
                    localResourceContextMenu(
                        playable: item.playable,
                        displayID: item.playbackID,
                        kind: item.resourceKind,
                        fallbackKind: item.playable?.kind,
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
                        playable: LocalServiceAppleMusicPlayable.make(station: station),
                        displayID: station.id.rawValue,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .disabled(store.isStartingPlayback)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        }
    }

    @ViewBuilder
    private func recentlyPlayedCard(_ recentlyPlayed: RecentlyPlayedMusicItem, item: LocalServiceCardItem) -> some View {
        switch recentlyPlayed {
        case .album(let album):
            NavigationLink {
                LocalMusicAlbumDetailView(
                    album: album,
                    store: store,
                    manager: manager,
                    searchManager: searchManager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
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
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .station:
            Button {
                Task {
                    await store.playOnSonos(
                        playable: LocalServiceAppleMusicPlayable.make(recentlyPlayed: recentlyPlayed),
                        displayID: recentlyPlayed.id.rawValue,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .disabled(store.isStartingPlayback)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
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
    private func recommendationCard(
        _ recommendation: MusicPersonalRecommendation.Item,
        item: LocalServiceCardItem
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
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
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
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        case .station:
            Button {
                Task {
                    await store.playOnSonos(
                        playable: LocalServiceAppleMusicPlayable.make(recommendation: recommendation),
                        displayID: recommendation.id.rawValue,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .disabled(store.isStartingPlayback)
            .contentShape(Rectangle())
            .contextMenu {
                localResourceContextMenu(
                    playable: item.playable,
                    displayID: item.playbackID,
                    kind: item.resourceKind,
                    fallbackKind: item.playable?.kind,
                    fallbackTitle: item.title,
                    fallbackArtist: item.subtitle,
                    fallbackAlbum: item.title
                )
            }
        @unknown default:
            EmptyView()
        }
    }

    private func cardContent(_ item: LocalServiceCardItem) -> some View {
        let artworkSize = item.cardArtworkSize
        let resource = resource(for: item)
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

    private func libraryCategoryDetail(_ category: LocalLibraryCategory) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        categoryDetailControls(category)
                        libraryCategoryDetailContent(category)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                    .padding(.trailing, category.showsAlphabetIndex ? 26 : 0)
                }
                .scrollDismissesKeyboard(.immediately)

                if category.showsAlphabetIndex {
                    let titles = categoryIndexTitles(category)
                    if !titles.isEmpty {
                        LocalLibraryAlphabetIndexBar(titles: titles) { title in
                            withAnimation(.snappy(duration: 0.22)) {
                                proxy.scrollTo(sectionID(category: category, title: title), anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            prepareCategoryDetail(category)
        }
    }

    private func prepareCategoryDetail(_ category: LocalLibraryCategory) {
        categoryDetailSearchText = ""
        if categorySortSelections[category] == nil {
            categorySortSelections[category] = LocalLibraryCategorySortOption.defaultOption(for: category)
        }
    }

    private func categorySortSelection(for category: LocalLibraryCategory) -> LocalLibraryCategorySortOption {
        categorySortSelections[category] ?? LocalLibraryCategorySortOption.defaultOption(for: category)
    }

    private func setCategorySortSelection(
        _ option: LocalLibraryCategorySortOption,
        for category: LocalLibraryCategory
    ) {
        categorySortSelections[category] = option
    }

    private func categoryDetailControls(_ category: LocalLibraryCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    TextField(
                        "",
                        text: $categoryDetailSearchText,
                        prompt: Text("Search \(category.title)")
                    )
                    .focused($isCategorySearchFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit {
                        isCategorySearchFieldFocused = false
                    }

                    if !categoryDetailSearchText.isEmpty {
                        Button {
                            categoryDetailSearchText = ""
                            isCategorySearchFieldFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear Category Search")
                    }
                }
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(isCategorySearchFieldFocused ? 0.16 : 0.10), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(isCategorySearchFieldFocused ? 0.22 : 0.08), lineWidth: 1)
                }

                let options = LocalLibraryCategorySortOption.options(for: category)
                if options.count > 1 {
                    Menu {
                        Picker(
                            "Sort",
                            selection: Binding(
                                get: { categorySortSelection(for: category) },
                                set: { setCategorySortSelection($0, for: category) }
                            )
                        ) {
                            ForEach(options) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.10), in: Circle())
                            .overlay {
                                Circle().stroke(.white.opacity(0.10), lineWidth: 1)
                            }
                    }
                    .accessibilityLabel("Sort \(category.title)")
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func libraryCategoryDetailContent(_ category: LocalLibraryCategory) -> some View {
        switch category {
        case .songs:
            indexedSongList(displayedSongs(for: category), category: category)
        case .albums:
            indexedAlbumList(displayedAlbums(for: category), category: category)
        case .artists:
            indexedArtistList(displayedArtists(for: category), category: category)
        case .playlists:
            playlistList(displayedPlaylists(for: category))
        }
    }

    private func displayedSongs(for category: LocalLibraryCategory) -> [Song] {
        let filtered = store.displayedSnapshot.songs.filter {
            matchesCategorySearch([$0.title, $0.artistName, $0.albumTitle])
        }

        switch categorySortSelection(for: category) {
        case .artist:
            return filtered.sorted { lhs, rhs in
                compareStrings(lhs.artistName, rhs.artistName)
                    || (lhs.artistName.localizedCaseInsensitiveCompare(rhs.artistName) == .orderedSame
                        && compareStrings(lhs.title, rhs.title))
            }
        case .album:
            return filtered.sorted { lhs, rhs in
                let lhsAlbum = lhs.albumTitle ?? ""
                let rhsAlbum = rhs.albumTitle ?? ""
                return compareStrings(lhsAlbum, rhsAlbum)
                    || (lhsAlbum.localizedCaseInsensitiveCompare(rhsAlbum) == .orderedSame
                        && compareStrings(lhs.title, rhs.title))
            }
        case .recentlyAdded:
            return filtered.sorted { lhs, rhs in
                compareDatesDescending(lhs.libraryAddedDate, rhs.libraryAddedDate, fallback: {
                    compareStrings(lhs.title, rhs.title)
                })
            }
        case .title, .curator:
            return filtered.sorted { compareStrings($0.title, $1.title) }
        }
    }

    private func displayedAlbums(for category: LocalLibraryCategory) -> [Album] {
        let filtered = store.displayedSnapshot.albums.filter {
            matchesCategorySearch([$0.title, $0.artistName])
        }

        switch categorySortSelection(for: category) {
        case .artist:
            return filtered.sorted { lhs, rhs in
                compareStrings(lhs.artistName, rhs.artistName)
                    || (lhs.artistName.localizedCaseInsensitiveCompare(rhs.artistName) == .orderedSame
                        && compareStrings(lhs.title, rhs.title))
            }
        case .recentlyAdded:
            return filtered.sorted { lhs, rhs in
                compareDatesDescending(lhs.libraryAddedDate, rhs.libraryAddedDate, fallback: {
                    compareStrings(lhs.title, rhs.title)
                })
            }
        case .title, .album, .curator:
            return filtered.sorted { compareStrings($0.title, $1.title) }
        }
    }

    private func displayedArtists(for category: LocalLibraryCategory) -> [Artist] {
        store.displayedSnapshot.artists
            .filter { matchesCategorySearch([$0.name]) }
            .sorted { compareStrings($0.name, $1.name) }
    }

    private func displayedPlaylists(for category: LocalLibraryCategory) -> [Playlist] {
        let filtered = store.displayedSnapshot.playlists.filter {
            matchesCategorySearch([$0.name, $0.curatorName, $0.shortDescription])
        }

        switch categorySortSelection(for: category) {
        case .curator:
            return filtered.sorted { lhs, rhs in
                let lhsCurator = lhs.curatorName ?? ""
                let rhsCurator = rhs.curatorName ?? ""
                return compareStrings(lhsCurator, rhsCurator)
                    || (lhsCurator.localizedCaseInsensitiveCompare(rhsCurator) == .orderedSame
                        && compareStrings(lhs.name, rhs.name))
            }
        case .recentlyAdded:
            return filtered.sorted { lhs, rhs in
                compareDatesDescending(lhs.libraryAddedDate, rhs.libraryAddedDate, fallback: {
                    compareStrings(lhs.name, rhs.name)
                })
            }
        case .title, .artist, .album:
            return filtered.sorted { compareStrings($0.name, $1.name) }
        }
    }

    private func matchesCategorySearch(_ fields: [String?]) -> Bool {
        let term = trimmedCategoryDetailSearchText
        guard !term.isEmpty else { return true }
        return fields.contains { field in
            field?.localizedCaseInsensitiveContains(term) == true
        }
    }

    private func compareStrings(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private func compareDatesDescending(
        _ lhs: Date?,
        _ rhs: Date?,
        fallback: () -> Bool
    ) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left == right {
                return fallback()
            }
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return fallback()
        }
    }

    @ViewBuilder
    private func indexedSongList(_ songs: [Song], category: LocalLibraryCategory) -> some View {
        let sections = sectionedItems(songs, title: \.title)
        if sections.isEmpty {
            emptyCategoryContent(category)
        } else {
            ForEach(sections) { section in
                indexedSectionHeader(section.title, category: category)
                songList(section.items)
            }
        }
    }

    @ViewBuilder
    private func indexedAlbumList(_ albums: [Album], category: LocalLibraryCategory) -> some View {
        let sections = sectionedItems(albums, title: \.title)
        if sections.isEmpty {
            emptyCategoryContent(category)
        } else {
            ForEach(sections) { section in
                indexedSectionHeader(section.title, category: category)
                albumList(section.items)
            }
        }
    }

    @ViewBuilder
    private func indexedArtistList(_ artists: [Artist], category: LocalLibraryCategory) -> some View {
        let sections = sectionedItems(artists, title: \.name)
        if sections.isEmpty {
            emptyCategoryContent(category)
        } else {
            ForEach(sections) { section in
                indexedSectionHeader(section.title, category: category)
                artistList(section.items)
            }
        }
    }

    private func indexedSectionHeader(_ title: String, category: LocalLibraryCategory) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal)
            .padding(.top, 6)
            .id(sectionID(category: category, title: title))
    }

    private func categoryIndexTitles(_ category: LocalLibraryCategory) -> [String] {
        switch category {
        case .songs:
            return LocalLibrarySectionIndex.indexTitles(for: displayedSongs(for: category).map(\.title))
        case .albums:
            return LocalLibrarySectionIndex.indexTitles(for: displayedAlbums(for: category).map(\.title))
        case .artists:
            return LocalLibrarySectionIndex.indexTitles(for: displayedArtists(for: category).map(\.name))
        case .playlists:
            return []
        }
    }

    private func sectionedItems<Item>(
        _ items: [Item],
        title: KeyPath<Item, String>
    ) -> [LocalLibraryIndexedSection<Item>] {
        let grouped = Dictionary(grouping: items) {
            LocalLibrarySectionIndex.indexTitle(for: $0[keyPath: title])
        }

        return LocalLibrarySectionIndex.indexTitles(for: items.map { $0[keyPath: title] })
            .map { sectionTitle in
                LocalLibraryIndexedSection(
                    title: sectionTitle,
                    items: grouped[sectionTitle] ?? []
                )
            }
    }

    private func sectionID(category: LocalLibraryCategory, title: String) -> String {
        "\(category.rawValue)-section-\(title)"
    }

    @ViewBuilder
    private func songList(_ songs: [Song]) -> some View {
        if songs.isEmpty {
            emptyCategoryContent(.songs)
        } else {
            ForEach(songs) { song in
                playRow(
                    id: song.id.rawValue,
                    artwork: song.artwork,
                    artworkURL: store.catalogArtworkURL(for: song),
                    title: song.title,
                    subtitle: song.artistName,
                    detail: song.albumTitle,
                    fallbackSystemImage: "music.note"
                ) {
                    await store.playOnSonos(
                        playable: LocalServiceAppleMusicPlayable.make(song: song),
                        displayID: song.id.rawValue,
                        fallbackKind: .song,
                        fallbackTitle: song.title,
                        fallbackArtist: song.artistName,
                        fallbackAlbum: song.albumTitle,
                        manager: manager,
                        searchManager: searchManager)
                }
                .contextMenu {
                    localResourceContextMenu(
                        playable: LocalServiceAppleMusicPlayable.make(song: song),
                        displayID: song.id.rawValue,
                        kind: .song,
                        fallbackKind: .song,
                        fallbackTitle: song.title,
                        fallbackArtist: song.artistName,
                        fallbackAlbum: song.albumTitle
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func albumList(_ albums: [Album]) -> some View {
        if albums.isEmpty {
            emptyCategoryContent(.albums)
        } else {
            ForEach(albums) { album in
                NavigationLink {
                    LocalMusicAlbumDetailView(
                        album: album,
                        store: store,
                        manager: manager,
                        searchManager: searchManager)
                } label: {
                    rowContent(
                        artwork: album.artwork,
                        artworkURL: store.catalogArtworkURL(for: album),
                        title: album.title,
                        subtitle: album.artistName,
                        detail: nil,
                        fallbackSystemImage: "square.stack",
                        accessory: .chevron
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    localResourceContextMenu(
                        playable: LocalServiceAppleMusicPlayable.make(album: album),
                        displayID: album.id.rawValue,
                        kind: .album,
                        fallbackKind: .album,
                        fallbackTitle: album.title,
                        fallbackArtist: album.artistName,
                        fallbackAlbum: album.title
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func artistList(_ artists: [Artist]) -> some View {
        if artists.isEmpty {
            emptyCategoryContent(.artists)
        } else {
            ForEach(artists) { artist in
                if LocalServiceLibraryInteraction.primaryAction(for: .artist) == .navigate {
                    NavigationLink {
                        LocalMusicArtistDetailView(
                            artist: artist,
                            store: store,
                            manager: manager,
                            searchManager: searchManager)
                    } label: {
                        rowContent(
                            artwork: artist.artwork,
                            artworkURL: store.catalogArtworkURL(for: artist),
                            title: artist.name,
                            subtitle: nil,
                            detail: nil,
                            fallbackSystemImage: "music.mic",
                            accessory: .chevron,
                            artworkStyle: .artistAvatar
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        localResourceContextMenu(
                            playable: LocalServiceAppleMusicPlayable.make(artist: artist),
                            displayID: artist.id.rawValue,
                            kind: .artist,
                            fallbackKind: .artist,
                            fallbackTitle: artist.name,
                            fallbackArtist: artist.name
                        )
                    }
                } else {
                    playRow(
                        id: artist.id.rawValue,
                        artwork: artist.artwork,
                        artworkURL: store.catalogArtworkURL(for: artist),
                        title: artist.name,
                        subtitle: nil,
                        detail: nil,
                        fallbackSystemImage: "music.mic",
                        artworkStyle: .artistAvatar
                    ) {
                        await store.playOnSonos(
                            playable: LocalServiceAppleMusicPlayable.make(artist: artist),
                            displayID: artist.id.rawValue,
                            fallbackKind: .artist,
                            fallbackTitle: artist.name,
                            fallbackArtist: artist.name,
                            manager: manager,
                            searchManager: searchManager)
                    }
                    .contextMenu {
                        localResourceContextMenu(
                            playable: LocalServiceAppleMusicPlayable.make(artist: artist),
                            displayID: artist.id.rawValue,
                            kind: .artist,
                            fallbackKind: .artist,
                            fallbackTitle: artist.name,
                            fallbackArtist: artist.name
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func playlistList(_ playlists: [Playlist]) -> some View {
        if playlists.isEmpty {
            emptyCategoryContent(.playlists)
        } else {
            ForEach(playlists) { playlist in
                NavigationLink {
                    LocalMusicPlaylistDetailView(
                        playlist: playlist,
                        store: store,
                        manager: manager,
                        searchManager: searchManager)
                } label: {
                    rowContent(
                        artwork: playlist.artwork,
                        artworkURL: store.catalogArtworkURL(for: playlist),
                        title: playlist.name,
                        subtitle: playlist.curatorName,
                        detail: playlist.shortDescription,
                        fallbackSystemImage: "music.note.list",
                        accessory: .chevron,
                        diagnosticLabel: "playlist-row title='\(playlist.name)' id='\(playlist.id.rawValue)'"
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    localResourceContextMenu(
                        playable: LocalServiceAppleMusicPlayable.make(playlist: playlist),
                        displayID: playlist.id.rawValue,
                        kind: .playlist,
                        fallbackKind: .playlist,
                        fallbackTitle: playlist.name,
                        fallbackArtist: playlist.curatorName
                    )
                }
            }
        }
    }

    private func emptyCategoryContent(_ category: LocalLibraryCategory) -> some View {
        ContentUnavailableView(
            category.emptyTitle,
            systemImage: category.systemImage
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func playRow(
        id: String,
        artwork: Artwork?,
        artworkURL: URL? = nil,
        title: String,
        subtitle: String?,
        detail: String?,
        fallbackSystemImage: String,
        artworkStyle: LocalLibraryArtworkStyle = .square,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            rowContent(
                artwork: artwork,
                artworkURL: artworkURL,
                title: title,
                subtitle: subtitle,
                detail: detail,
                fallbackSystemImage: fallbackSystemImage,
                accessory: store.isStartingPlayback && store.activePlaybackItemID == id ? .progress : .play,
                artworkStyle: artworkStyle
            )
        }
        .buttonStyle(.plain)
        .disabled(store.isStartingPlayback)
    }

    private func rowContent(
        artwork: Artwork?,
        artworkURL: URL? = nil,
        title: String,
        subtitle: String?,
        detail: String?,
        fallbackSystemImage: String,
        accessory: LocalServiceRowAccessory,
        diagnosticLabel: String? = nil,
        artworkStyle: LocalLibraryArtworkStyle = .square
    ) -> some View {
        let resource = MusicResourcePresentation(
            id: "\(title)|\(subtitle ?? "")|\(detail ?? "")",
            kind: .unknown,
            title: title,
            subtitle: subtitle ?? "",
            detail: detail,
            fallbackSystemImage: fallbackSystemImage,
            accessory: accessory.musicResourceAccessory,
            isQueueable: false
        )

        return MusicResourceRowLabel(resource: resource) {
            rowArtwork(
                artwork: artwork,
                artworkURL: artworkURL,
                fallbackSystemImage: fallbackSystemImage,
                diagnosticLabel: diagnosticLabel,
                style: artworkStyle
            )
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func rowArtwork(
        artwork: Artwork?,
        artworkURL: URL?,
        fallbackSystemImage: String,
        diagnosticLabel: String?,
        style: LocalLibraryArtworkStyle
    ) -> some View {
        switch style {
        case .square:
            LocalLibraryArtworkTile(
                artwork: artwork,
                artworkURL: artworkURL,
                fallbackSystemImage: fallbackSystemImage,
                diagnosticLabel: diagnosticLabel
            )
            .frame(width: 56, height: 56)
        case .artistAvatar:
            LocalMusicArtistArtwork(
                artwork: artwork,
                artworkURL: artworkURL,
                size: 56,
                shadow: false
            )
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }
}

private enum LocalServiceRowAccessory {
    case play
    case chevron
    case progress
}

private extension LocalServiceRowAccessory {
    var musicResourceAccessory: MusicResourceAccessory {
        switch self {
        case .play:
            return .play
        case .chevron:
            return .chevron
        case .progress:
            return .progress
        }
    }
}

private struct LocalLibraryIndexedSection<Item>: Identifiable {
    let title: String
    let items: [Item]

    var id: String { title }
}

private struct LocalLibraryAlphabetIndexBar: View {
    let titles: [String]
    let onSelect: (String) -> Void

    @State private var lastSelectedTitle: String?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 1) {
                ForEach(titles, id: \.self) { title in
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.pink)
                        .frame(width: 24, height: itemHeight(in: proxy.size.height))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            select(title)
                        }
                }
            }
            .frame(width: 28, height: proxy.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectTitle(at: value.location.y, height: proxy.size.height)
                    }
                    .onEnded { _ in
                        lastSelectedTitle = nil
                    }
            )
        }
        .frame(width: 28)
        .padding(.trailing, 2)
    }

    private func itemHeight(in height: CGFloat) -> CGFloat {
        guard !titles.isEmpty else { return 14 }
        return min(18, max(12, height / CGFloat(titles.count)))
    }

    private func selectTitle(at yPosition: CGFloat, height: CGFloat) {
        guard !titles.isEmpty else { return }
        let itemHeight = max(1, height / CGFloat(titles.count))
        let index = min(max(Int(yPosition / itemHeight), 0), titles.count - 1)
        select(titles[index])
    }

    private func select(_ title: String) {
        guard lastSelectedTitle != title else { return }
        lastSelectedTitle = title
        onSelect(title)
    }
}

private enum LocalLibraryArtworkStyle {
    case square
    case artistAvatar
}

struct LocalServiceCardArtworkSize: Equatable {
    let width: CGFloat
    let height: CGFloat
}

enum LocalServiceCardArtworkMetrics {
    static func size(isStationLike: Bool) -> LocalServiceCardArtworkSize {
        LocalServiceCardArtworkSize(width: 138, height: 138)
    }

    static func contentMode(
        isStationLike: Bool,
        maximumWidth: Int? = nil,
        maximumHeight: Int? = nil
    ) -> LocalMusicArtworkURL.ContentMode {
        guard let maximumWidth,
              let maximumHeight,
              maximumWidth > 1,
              maximumHeight > 1 else {
            return .fit
        }

        let aspectRatio = Double(maximumWidth) / Double(maximumHeight)
        if aspectRatio > 1.2 {
            return .fill
        }

        return .fit
    }
}

enum LocalServiceLibraryItemKind: Equatable {
    case song
    case album
    case artist
    case playlist
    case station
}

enum LocalServiceLibraryPrimaryAction: Equatable {
    case play
    case navigate
}

enum LocalServiceLibraryInteraction {
    static func primaryAction(
        for kind: LocalServiceLibraryItemKind
    ) -> LocalServiceLibraryPrimaryAction {
        switch kind {
        case .song, .station:
            return .play
        case .album, .artist, .playlist:
            return .navigate
        }
    }
}

private enum LocalServiceCardItem: Identifiable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case station(Station)
    case recentlyPlayed(RecentlyPlayedMusicItem)
    case recommendation(MusicPersonalRecommendation.Item)

    var id: String {
        switch self {
        case .song(let song): return "song-\(song.id.rawValue)"
        case .album(let album): return "album-\(album.id.rawValue)"
        case .artist(let artist): return "artist-\(artist.id.rawValue)"
        case .playlist(let playlist): return "playlist-\(playlist.id.rawValue)"
        case .station(let station): return "station-\(station.id.rawValue)"
        case .recentlyPlayed(let item): return "recent-\(item.id.rawValue)"
        case .recommendation(let item): return "recommendation-\(item.id.rawValue)"
        }
    }

    var playbackID: String {
        switch self {
        case .song(let song): return song.id.rawValue
        case .album(let album): return album.id.rawValue
        case .artist(let artist): return artist.id.rawValue
        case .playlist(let playlist): return playlist.id.rawValue
        case .station(let station): return station.id.rawValue
        case .recentlyPlayed(let item): return item.id.rawValue
        case .recommendation(let item): return item.id.rawValue
        }
    }

    var resourceKind: MusicResourceKind {
        switch self {
        case .song:
            return .song
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        case .station:
            return .station
        case .recentlyPlayed(let item):
            switch item {
            case .album: return .album
            case .playlist: return .playlist
            case .station: return .station
            @unknown default: return .unknown
            }
        case .recommendation(let item):
            switch item {
            case .album: return .album
            case .playlist: return .playlist
            case .station: return .station
            @unknown default: return .unknown
            }
        }
    }

    var playable: LocalServiceAppleMusicPlayable? {
        switch self {
        case .song(let song):
            return LocalServiceAppleMusicPlayable.make(song: song)
        case .album(let album):
            return LocalServiceAppleMusicPlayable.make(album: album)
        case .artist(let artist):
            return LocalServiceAppleMusicPlayable.make(artist: artist)
        case .playlist(let playlist):
            return LocalServiceAppleMusicPlayable.make(playlist: playlist)
        case .station(let station):
            return LocalServiceAppleMusicPlayable.make(station: station)
        case .recentlyPlayed(let item):
            return LocalServiceAppleMusicPlayable.make(recentlyPlayed: item)
        case .recommendation(let item):
            return LocalServiceAppleMusicPlayable.make(recommendation: item)
        }
    }

    var title: String {
        switch self {
        case .song(let song): return song.title
        case .album(let album): return album.title
        case .artist(let artist): return artist.name
        case .playlist(let playlist): return playlist.name
        case .station(let station): return station.name
        case .recentlyPlayed(let item): return item.title
        case .recommendation(let item): return item.title
        }
    }

    var subtitle: String {
        switch self {
        case .song(let song): return song.artistName
        case .album(let album): return album.artistName
        case .artist: return "Artist"
        case .playlist(let playlist): return playlist.curatorName ?? "Playlist"
        case .station: return "Station"
        case .recentlyPlayed(let item): return item.subtitle ?? recentlyPlayedFallbackTitle(item)
        case .recommendation(let item): return item.subtitle ?? recommendationFallbackTitle(item)
        }
    }

    var artwork: Artwork? {
        switch self {
        case .song(let song): return song.artwork
        case .album(let album): return album.artwork
        case .artist(let artist): return artist.artwork
        case .playlist(let playlist): return playlist.artwork
        case .station(let station): return station.artwork
        case .recentlyPlayed(let item): return item.artwork
        case .recommendation(let item): return item.artwork
        }
    }

    var fallbackSystemImage: String {
        switch self {
        case .song: return "music.note"
        case .album: return "square.stack"
        case .artist: return "music.mic"
        case .playlist: return "music.note.list"
        case .station: return "dot.radiowaves.left.and.right"
        case .recentlyPlayed(let item): return recentlyPlayedFallbackIcon(item)
        case .recommendation(let item): return recommendationFallbackIcon(item)
        }
    }

    var isStationLike: Bool {
        switch self {
        case .station:
            return true
        case .recentlyPlayed(let item):
            if case .station = item { return true }
            return false
        case .recommendation(let item):
            if case .station = item { return true }
            return false
        case .song, .album, .artist, .playlist:
            return false
        }
    }

    var cardArtworkSize: LocalServiceCardArtworkSize {
        LocalServiceCardArtworkMetrics.size(isStationLike: isStationLike)
    }

    func catalogArtworkURL(using store: LocalLibraryStore) -> URL? {
        switch self {
        case .song(let song):
            return store.catalogArtworkURL(for: song)
        case .album, .artist, .playlist, .station, .recentlyPlayed, .recommendation:
            switch self {
            case .album(let album):
                return store.catalogArtworkURL(for: album)
            case .artist(let artist):
                return store.catalogArtworkURL(for: artist)
            case .playlist(let playlist):
                return store.catalogArtworkURL(for: playlist)
            case .recentlyPlayed(let item):
                return store.catalogArtworkURL(for: item)
            case .recommendation(let item):
                return store.catalogArtworkURL(for: item)
            case .song, .station:
                return nil
            }
        }
    }

    var artworkDiagnosticLabel: String? {
        switch self {
        case .station(let station):
            return "station-card title='\(station.name)' id='\(station.id.rawValue)'"
        case .playlist(let playlist):
            return "playlist-card title='\(playlist.name)' id='\(playlist.id.rawValue)'"
        case .recentlyPlayed(let item):
            switch item {
            case .playlist:
                return "recent-playlist-card title='\(item.title)' id='\(item.id.rawValue)'"
            case .station:
                return "recent-station-card title='\(item.title)' id='\(item.id.rawValue)'"
            case .album:
                return nil
            @unknown default:
                return nil
            }
        case .recommendation(let item):
            switch item {
            case .playlist:
                return "recommendation-playlist-card title='\(item.title)' id='\(item.id.rawValue)'"
            case .station:
                return "recommendation-station-card title='\(item.title)' id='\(item.id.rawValue)'"
            case .album:
                return nil
            @unknown default:
                return nil
            }
        case .song, .album, .artist:
            return nil
        }
    }

    private func recentlyPlayedFallbackTitle(_ item: RecentlyPlayedMusicItem) -> String {
        switch item {
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .station: return "Station"
        @unknown default: return "Apple Music"
        }
    }

    private func recommendationFallbackTitle(_ item: MusicPersonalRecommendation.Item) -> String {
        switch item {
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .station: return "Station"
        @unknown default: return "Apple Music"
        }
    }

    private func recentlyPlayedFallbackIcon(_ item: RecentlyPlayedMusicItem) -> String {
        switch item {
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .station: return "dot.radiowaves.left.and.right"
        @unknown default: return "music.note"
        }
    }

    private func recommendationFallbackIcon(_ item: MusicPersonalRecommendation.Item) -> String {
        switch item {
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .station: return "dot.radiowaves.left.and.right"
        @unknown default: return "music.note"
        }
    }
}

private struct LocalLibraryArtworkTile: View {
    let artwork: Artwork?
    let artworkURL: URL?
    let fallbackSystemImage: String
    let diagnosticLabel: String?
    let artworkContentMode: LocalMusicArtworkURL.ContentMode

    init(
        artwork: Artwork?,
        artworkURL: URL?,
        fallbackSystemImage: String,
        diagnosticLabel: String?,
        artworkContentMode: LocalMusicArtworkURL.ContentMode = .fit
    ) {
        self.artwork = artwork
        self.artworkURL = artworkURL
        self.fallbackSystemImage = fallbackSystemImage
        self.diagnosticLabel = diagnosticLabel
        self.artworkContentMode = artworkContentMode
    }

    @State private var didLogMissingSources = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))

                fallbackIcon

                switch LocalMusicArtworkSource.preferred(artwork: artwork, remoteURL: artworkURL) {
                case .musicKit(let artwork):
                    LocalMusicArtworkView(
                        artwork: artwork,
                        diagnosticLabel: diagnosticLabel,
                        contentMode: artworkContentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                case .remote(let artworkURL):
                    LocalLibraryRemoteArtworkView(
                        url: artworkURL,
                        diagnosticLabel: diagnosticLabel,
                        artworkContentMode: artworkContentMode)
                case .placeholder:
                    EmptyView()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            logMissingSourcesIfNeeded()
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSystemImage)
            .font(.title3)
            .foregroundStyle(.secondary)
    }

    private func logMissingSourcesIfNeeded() {
        guard !didLogMissingSources,
              artwork == nil,
              artworkURL == nil,
              let diagnosticLabel else {
            return
        }
        didLogMissingSources = true
        SonosLog.debug(
            .localService,
            "Artwork tile placeholder no-sources \(diagnosticLabel)")
    }
}

private struct LocalLibraryRemoteArtworkView: View {
    let url: URL
    let diagnosticLabel: String?
    let artworkContentMode: LocalMusicArtworkURL.ContentMode

    @State private var didLogSuccess = false
    @State private var didLogFailure = false

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: artworkContentMode.swiftUIContentMode)
                    .onAppear { logSuccessIfNeeded() }
            } else if case .failure(let error) = phase {
                Color.clear
                    .onAppear { logFailureIfNeeded(error) }
            } else {
                Color.clear
            }
        }
    }

    private func logSuccessIfNeeded() {
        guard !didLogSuccess,
              let diagnosticLabel else {
            return
        }
        didLogSuccess = true
        SonosLog.debug(
            .localService,
            "Remote artwork image loaded \(diagnosticLabel) url='\(url.absoluteString)'")
    }

    private func logFailureIfNeeded(_ error: Error) {
        guard !didLogFailure,
              let diagnosticLabel else {
            return
        }
        didLogFailure = true
        SonosLog.error(
            .localService,
            "Remote artwork image failed \(diagnosticLabel) url='\(url.absoluteString)' error=\(error)")
    }
}

private extension LocalMusicArtworkURL.ContentMode {
    var swiftUIContentMode: ContentMode {
        switch self {
        case .fit: return .fit
        case .fill: return .fill
        }
    }
}

#Preview {
    LocalLibraryView(manager: SonosManager(), searchManager: SearchManager())
}
