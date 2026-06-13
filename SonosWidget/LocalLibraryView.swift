import MusicKit
import SwiftUI

struct LocalLibraryView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager
    @State private var store = LocalLibraryStore()
    @State private var selectedCategory: LocalLibraryCategory = .songs
    @State private var searchText = ""

    private var isSearchingLibrary: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isAccessDenied {
                    deniedContent
                } else if store.isLoading && !store.hasLoaded {
                    loadingContent
                } else if !store.hasHomeContent && searchText.isEmpty {
                    emptyLibraryContent
                } else {
                    content
                }
            }
            .navigationTitle("Local Service")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .background(backgroundLayer.ignoresSafeArea())
            .searchable(text: $searchText, prompt: "Search Library")
            .task {
                await store.loadIfNeeded()
            }
            .task(id: searchText) {
                await store.search(term: searchText)
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
            Text("Loading Library")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
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
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var serviceHomeContent: some View {
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

        librarySection
    }

    @ViewBuilder
    private var recommendationsContent: some View {
        ForEach(Array(store.recommendations.prefix(5))) { recommendation in
            let cards = recommendationCards(for: recommendation)
            if !cards.isEmpty {
                horizontalSection(
                    title: recommendation.title ?? LocalServiceSectionKind.recommendations.title,
                    subtitle: recommendation.reason,
                    systemImage: LocalServiceSectionKind.recommendations.systemImage,
                    items: cards
                )
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(kind: .library)
            categoryPicker
            selectedCategoryHeader
            selectedCategoryContent
        }
    }

    private var searchResultsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Search Results", systemImage: "magnifyingglass")
                    .font(.title3.weight(.semibold))
                Spacer()
                if store.isSearching {
                    ProgressView()
                }
            }
            .padding(.horizontal)

            categoryPicker
            selectedCategoryHeader
            selectedCategoryContent
        }
    }

    private var categoryPicker: some View {
        Picker("Library Category", selection: $selectedCategory) {
            ForEach(LocalLibraryCategory.allCases) { category in
                Text(category.title).tag(category)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private var selectedCategoryHeader: some View {
        HStack {
            Label(selectedCategory.title, systemImage: selectedCategory.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if store.isSearching {
                ProgressView()
            } else {
                Text("\(store.summary.count(for: selectedCategory))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var selectedCategoryContent: some View {
        switch selectedCategory {
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
            systemImage: kind.systemImage,
            items: items
        )
    }

    private func horizontalSection(
        title: String,
        subtitle: String?,
        systemImage: String,
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
        sectionHeader(title: kind.title, subtitle: nil, systemImage: kind.systemImage)
    }

    private func sectionHeader(title: String, subtitle: String?, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal)
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
        @unknown default:
            EmptyView()
        }
    }

    private func cardContent(_ item: LocalServiceCardItem) -> some View {
        let artworkSize = item.cardArtworkSize
        return VStack(alignment: .leading, spacing: 6) {
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
            .frame(width: artworkSize.width, height: artworkSize.height)

            Text(item.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(height: 34, alignment: .topLeading)

            Text(item.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: artworkSize.width, alignment: .leading)
        .opacity(store.isStartingPlayback && store.activePlaybackItemID != item.playbackID ? 0.55 : 1)
        .overlay {
            if store.isStartingPlayback && store.activePlaybackItemID == item.playbackID {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial.opacity(0.88))
                    .frame(width: artworkSize.width, height: artworkSize.height)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .top) {
                        ProgressView()
                            .padding(.top, max(24, artworkSize.height / 2 - 10))
                    }
            }
        }
    }

    @ViewBuilder
    private func songList(_ songs: [Song]) -> some View {
        if songs.isEmpty {
            emptyCategoryContent
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
            }
        }
    }

    @ViewBuilder
    private func albumList(_ albums: [Album]) -> some View {
        if albums.isEmpty {
            emptyCategoryContent
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
                        detail: "\(album.trackCount) tracks",
                        fallbackSystemImage: "square.stack",
                        accessory: .chevron
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func artistList(_ artists: [Artist]) -> some View {
        if artists.isEmpty {
            emptyCategoryContent
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
                            subtitle: "Artist",
                            detail: nil,
                            fallbackSystemImage: "music.mic",
                            accessory: .chevron,
                            artworkStyle: .artistAvatar
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    playRow(
                        id: artist.id.rawValue,
                        artwork: artist.artwork,
                        artworkURL: store.catalogArtworkURL(for: artist),
                        title: artist.name,
                        subtitle: "Artist",
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
                }
            }
        }
    }

    @ViewBuilder
    private func playlistList(_ playlists: [Playlist]) -> some View {
        if playlists.isEmpty {
            emptyCategoryContent
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
                        subtitle: playlist.curatorName ?? "Playlist",
                        detail: playlist.shortDescription,
                        fallbackSystemImage: "music.note.list",
                        accessory: .chevron,
                        diagnosticLabel: "playlist-row title='\(playlist.name)' id='\(playlist.id.rawValue)'"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyCategoryContent: some View {
        ContentUnavailableView(
            selectedCategory.emptyTitle,
            systemImage: selectedCategory.systemImage
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func playRow(
        id: String,
        artwork: Artwork?,
        artworkURL: URL? = nil,
        title: String,
        subtitle: String,
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
        subtitle: String,
        detail: String?,
        fallbackSystemImage: String,
        accessory: LocalServiceRowAccessory,
        diagnosticLabel: String? = nil,
        artworkStyle: LocalLibraryArtworkStyle = .square
    ) -> some View {
        HStack(spacing: 12) {
            rowArtwork(
                artwork: artwork,
                artworkURL: artworkURL,
                fallbackSystemImage: fallbackSystemImage,
                diagnosticLabel: diagnosticLabel,
                style: artworkStyle)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            switch accessory {
            case .play:
                Image(systemName: "play.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, height: 32)
            case .progress:
                ProgressView()
                    .frame(width: 32, height: 32)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
        guard isStationLike,
              let maximumWidth,
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

                if let artwork {
                    LocalMusicArtworkView(
                        artwork: artwork,
                        diagnosticLabel: diagnosticLabel,
                        contentMode: artworkContentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }

                if let artworkURL {
                    LocalLibraryRemoteArtworkView(
                        url: artworkURL,
                        diagnosticLabel: diagnosticLabel,
                        artworkContentMode: artworkContentMode)
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
