import MusicKit
import Observation
import SwiftUI


extension LocalLibraryView {

    func libraryCategoryDetail(_ category: LocalLibraryCategory) -> some View {
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
            Task { await store.loadCategoryIfNeeded(category) }
        }
    }

    func prepareCategoryDetail(_ category: LocalLibraryCategory) {
        categoryDetailSearchText = ""
        if categorySortSelections[category] == nil {
            categorySortSelections[category] = LocalLibraryCategorySortOption.defaultOption(for: category)
        }
    }

    func categorySortSelection(for category: LocalLibraryCategory) -> LocalLibraryCategorySortOption {
        categorySortSelections[category] ?? LocalLibraryCategorySortOption.defaultOption(for: category)
    }

    func setCategorySortSelection(
        _ option: LocalLibraryCategorySortOption,
        for category: LocalLibraryCategory
    ) {
        categorySortSelections[category] = option
    }

    func categoryDetailControls(_ category: LocalLibraryCategory) -> some View {
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

                if store.isLoadingCategory(category) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.72))
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    func libraryCategoryDetailContent(_ category: LocalLibraryCategory) -> some View {
        switch category {
        case .songs:
            indexedSongList(songDetailPresentation(for: category), category: category)
        case .albums:
            indexedAlbumList(albumDetailPresentation(for: category), category: category)
        case .artists:
            indexedArtistList(displayedArtists(for: category), category: category)
        case .playlists:
            playlistList(displayedPlaylists(for: category))
        }
    }

    func songDetailPresentation(
        for category: LocalLibraryCategory
    ) -> LocalLibraryCategoryDetailPresentation<Song> {
        let sortOption = categorySortSelection(for: category)
        return songDetailPresentationCache.presentation(
            key: categoryDetailPresentationCacheKey(for: category, sortOption: sortOption),
            items: store.displayedSnapshot.songs,
            isIncluded: { matchesCategorySearch([$0.title, $0.artistName, $0.albumTitle]) },
            areInIncreasingOrder: songSortComparator(for: sortOption),
            title: \.title)
    }

    func songSortComparator(
        for option: LocalLibraryCategorySortOption
    ) -> (Song, Song) -> Bool {
        switch option {
        case .artist:
            return { lhs, rhs in
                compareStrings(lhs.artistName, rhs.artistName)
                    || (lhs.artistName.localizedCaseInsensitiveCompare(rhs.artistName) == .orderedSame
                        && compareStrings(lhs.title, rhs.title))
            }
        case .album:
            return { lhs, rhs in
                let lhsAlbum = lhs.albumTitle ?? ""
                let rhsAlbum = rhs.albumTitle ?? ""
                return compareStrings(lhsAlbum, rhsAlbum)
                    || (lhsAlbum.localizedCaseInsensitiveCompare(rhsAlbum) == .orderedSame
                        && compareStrings(lhs.title, rhs.title))
            }
        case .recentlyAdded:
            return { lhs, rhs in
                compareDatesDescending(lhs.libraryAddedDate, rhs.libraryAddedDate, fallback: {
                    compareStrings(lhs.title, rhs.title)
                })
            }
        case .title, .curator:
            return { compareStrings($0.title, $1.title) }
        }
    }

    func albumDetailPresentation(
        for category: LocalLibraryCategory
    ) -> LocalLibraryCategoryDetailPresentation<Album> {
        let sortOption = categorySortSelection(for: category)
        return albumDetailPresentationCache.presentation(
            key: categoryDetailPresentationCacheKey(for: category, sortOption: sortOption),
            items: store.displayedSnapshot.albums,
            isIncluded: { matchesCategorySearch([$0.title, $0.artistName]) },
            areInIncreasingOrder: albumSortComparator(for: sortOption),
            title: \.title)
    }

    func albumSortComparator(
        for option: LocalLibraryCategorySortOption
    ) -> (Album, Album) -> Bool {
        switch option {
        case .artist:
            return { lhs, rhs in
                compareStrings(lhs.artistName, rhs.artistName)
                    || (lhs.artistName.localizedCaseInsensitiveCompare(rhs.artistName) == .orderedSame
                        && compareStrings(lhs.title, rhs.title))
            }
        case .recentlyAdded:
            return { lhs, rhs in
                compareDatesDescending(lhs.libraryAddedDate, rhs.libraryAddedDate, fallback: {
                    compareStrings(lhs.title, rhs.title)
                })
            }
        case .title, .album, .curator:
            return { compareStrings($0.title, $1.title) }
        }
    }

    func categoryDetailPresentationCacheKey(
        for category: LocalLibraryCategory,
        sortOption: LocalLibraryCategorySortOption
    ) -> LocalLibraryCategoryDetailPresentationCacheKey {
        LocalLibraryCategoryDetailPresentationCacheKey(
            category: category,
            contentToken: store.displayedSnapshotToken,
            searchText: trimmedCategoryDetailSearchText,
            sortOption: sortOption)
    }

    func displayedArtists(for category: LocalLibraryCategory) -> [Artist] {
        store.displayedSnapshot.artists
            .filter { matchesCategorySearch([$0.name]) }
            .sorted { compareStrings($0.name, $1.name) }
    }

    func displayedPlaylists(for category: LocalLibraryCategory) -> [Playlist] {
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

    func matchesCategorySearch(_ fields: [String?]) -> Bool {
        let term = trimmedCategoryDetailSearchText
        guard !term.isEmpty else { return true }
        return fields.contains { field in
            field?.localizedCaseInsensitiveContains(term) == true
        }
    }

    func compareStrings(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    func compareDatesDescending(
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
    func indexedSongList(
        _ presentation: LocalLibraryCategoryDetailPresentation<Song>,
        category: LocalLibraryCategory
    ) -> some View {
        if presentation.sections.isEmpty {
            emptyCategoryContent(category)
        } else {
            ForEach(presentation.sections) { section in
                indexedSectionHeader(section.title, category: category)
                songList(section.items)
            }
        }
    }

    @ViewBuilder
    func indexedAlbumList(
        _ presentation: LocalLibraryCategoryDetailPresentation<Album>,
        category: LocalLibraryCategory
    ) -> some View {
        if presentation.sections.isEmpty {
            emptyCategoryContent(category)
        } else {
            ForEach(presentation.sections) { section in
                indexedSectionHeader(section.title, category: category)
                albumList(section.items)
            }
        }
    }

    @ViewBuilder
    func indexedArtistList(_ artists: [Artist], category: LocalLibraryCategory) -> some View {
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

    func indexedSectionHeader(_ title: String, category: LocalLibraryCategory) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal)
            .padding(.top, 6)
            .id(sectionID(category: category, title: title))
    }

    func categoryIndexTitles(_ category: LocalLibraryCategory) -> [String] {
        switch category {
        case .songs:
            return songDetailPresentation(for: category).indexTitles
        case .albums:
            return albumDetailPresentation(for: category).indexTitles
        case .artists:
            return LocalLibrarySectionIndex.indexTitles(for: displayedArtists(for: category).map(\.name))
        case .playlists:
            return []
        }
    }

    func sectionedItems<Item>(
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

    func sectionID(category: LocalLibraryCategory, title: String) -> String {
        "\(category.rawValue)-section-\(title)"
    }

    @ViewBuilder
    func songList(_ songs: [Song]) -> some View {
        if songs.isEmpty {
            emptyCategoryContent(.songs)
        } else {
            ForEach(songs) { song in
                let artworkURL = store.catalogArtworkURL(for: song)
                let playable = playableWithPreferredPlaybackArtwork(
                    LocalServiceAppleMusicPlayable.make(song: song),
                    artworkURL: artworkURL
                )
                playRow(
                    id: song.id.rawValue,
                    artwork: song.artwork,
                    artworkURL: artworkURL,
                    title: song.title,
                    subtitle: song.artistName,
                    detail: song.albumTitle,
                    fallbackSystemImage: "music.note"
                ) {
                    await store.playOnSonos(
                        playable: playable,
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
                        playable: playable,
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
    func albumList(_ albums: [Album]) -> some View {
        if albums.isEmpty {
            emptyCategoryContent(.albums)
        } else {
            ForEach(albums) { album in
                let artworkURL = store.catalogArtworkURL(for: album)
                let playable = playableWithPreferredPlaybackArtwork(
                    LocalServiceAppleMusicPlayable.make(album: album),
                    artworkURL: artworkURL
                )
                NavigationLink {
                    LocalMusicAlbumDetailView(
                        album: album,
                        store: store,
                        manager: manager,
                        searchManager: searchManager)
                } label: {
                    rowContent(
                        artwork: album.artwork,
                        artworkURL: artworkURL,
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
                        playable: playable,
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
    func artistList(_ artists: [Artist]) -> some View {
        if artists.isEmpty {
            emptyCategoryContent(.artists)
        } else {
            ForEach(artists) { artist in
                let artworkURL = store.catalogArtworkURL(for: artist)
                let playable = playableWithPreferredPlaybackArtwork(
                    LocalServiceAppleMusicPlayable.make(artist: artist),
                    artworkURL: artworkURL
                )
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
                            artworkURL: artworkURL,
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
                            playable: playable,
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
                        artworkURL: artworkURL,
                        title: artist.name,
                        subtitle: nil,
                        detail: nil,
                        fallbackSystemImage: "music.mic",
                        artworkStyle: .artistAvatar
                    ) {
                        await store.playOnSonos(
                            playable: playable,
                            displayID: artist.id.rawValue,
                            fallbackKind: .artist,
                            fallbackTitle: artist.name,
                            fallbackArtist: artist.name,
                            manager: manager,
                            searchManager: searchManager)
                    }
                    .contextMenu {
                        localResourceContextMenu(
                            playable: playable,
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
    func playlistList(_ playlists: [Playlist]) -> some View {
        if playlists.isEmpty {
            emptyCategoryContent(.playlists)
        } else {
            ForEach(playlists) { playlist in
                let artworkURL = store.catalogArtworkURL(for: playlist)
                let playable = playableWithPreferredPlaybackArtwork(
                    LocalServiceAppleMusicPlayable.make(playlist: playlist),
                    artworkURL: artworkURL
                )
                NavigationLink {
                    LocalMusicPlaylistDetailView(
                        playlist: playlist,
                        store: store,
                        manager: manager,
                        searchManager: searchManager)
                } label: {
                    rowContent(
                        artwork: playlist.artwork,
                        artworkURL: artworkURL,
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
                        playable: playable,
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

    func emptyCategoryContent(_ category: LocalLibraryCategory) -> some View {
        ContentUnavailableView(
            category.emptyTitle,
            systemImage: category.systemImage
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    func playRow(
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

    func rowContent(
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
    func rowArtwork(
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

    func statusBanner(_ message: String) -> some View {
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
