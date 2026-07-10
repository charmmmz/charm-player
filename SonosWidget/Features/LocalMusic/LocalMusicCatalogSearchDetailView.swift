import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit
struct LocalMusicCatalogSearchDetailView: View {
    let item: AppleMusicCatalogSearchItem
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var resource: LocalMusicCatalogSearchDetailResource?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let resource {
                switch resource {
                case .album(let album):
                    LocalMusicAlbumDetailView(
                        album: album,
                        store: store,
                        manager: manager,
                        searchManager: searchManager,
                        initialDetailedAlbum: album)
                case .artist(let artist):
                    LocalMusicCatalogArtistDetailView(
                        artist: artist,
                        store: store,
                        manager: manager,
                        searchManager: searchManager)
                case .playlist(let playlist):
                    LocalMusicPlaylistDetailView(
                        playlist: playlist,
                        store: store,
                        manager: manager,
                        searchManager: searchManager)
                }
            } else if isLoading {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Loading \(item.title)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    SonosArtworkBackground(
                        image: manager.albumArtImage,
                        fallbackColor: manager.albumArtDominantColor
                    )
                    .ignoresSafeArea()
                )
            } else {
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: catalogFallbackSystemImage,
                    description: Text(errorMessage ?? "Try again later.")
                )
                .background(
                    SonosArtworkBackground(
                        image: manager.albumArtImage,
                        fallbackColor: manager.albumArtDominantColor
                    )
                    .ignoresSafeArea()
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.id) { await loadResource() }
    }

    private var catalogFallbackSystemImage: String {
        switch item.type {
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

    private func loadResource() async {
        guard resource == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = AppleMusicCatalogSearchClient()
        do {
            switch item.type {
            case .album:
                resource = .album(try await client.album(catalogID: item.id))
            case .artist:
                resource = .artist(try await client.artist(catalogID: item.id))
            case .playlist:
                resource = .playlist(try await client.playlist(catalogID: item.id))
            case .song:
                errorMessage = "Songs play directly from search results."
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            SonosLog.error(
                .localService,
                "Catalog search detail load failed type=\(item.type) id='\(item.id)' title='\(item.title)' error=\(error)")
        }
    }
}

private enum LocalMusicCatalogSearchDetailResource {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

private struct LocalMusicCatalogArtistDetailView: View {
    let artist: Artist
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var coverImage: UIImage?
    @State private var themeColor: Color?
    @State private var actionInFlight: LocalMusicDetailAction?

    private var coverURL: URL? {
        artist.artwork.flatMap {
            LocalMusicArtworkURL.imageDownloadURL(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: artist)
    }
    private var artistPlayable: LocalServiceAppleMusicPlayable? {
        LocalServiceAppleMusicPlayable.make(artist: artist)?
            .withPreferredArtworkURLString(coverURL?.absoluteString)
    }
    private var albums: [Album] {
        LocalMusicCatalogArtistContent.albums(for: artist)
    }
    private var topSongs: [Song] {
        Array(artist.topSongs ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                topSongsSection
                albumOverview
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: coverURL) { await loadCoverImage(from: coverURL) }
    }

    private var detailBackground: some View {
        SonosArtworkBackground(
            image: coverImage ?? manager.albumArtImage,
            fallbackColor: themeColor ?? manager.albumArtDominantColor
        )
        .animation(.easeInOut(duration: 0.8), value: coverURL)
        .animation(.easeInOut(duration: 0.8), value: themeColor)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Button {
                    openAppleMusicFromArtwork()
                } label: {
                    LocalMusicArtistArtwork(
                        artwork: artist.artwork,
                        artworkURL: store.catalogArtworkURL(for: artist)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(artist.name) in Apple Music")

                stationBadge
                    .offset(x: 6, y: 6)
            }

            VStack(spacing: 5) {
                Text(artist.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Text("Artist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SourceBadgeView(source: .appleMusic, tintColor: nil)
                    .padding(.top, 2)

                Text("\(albums.count) albums · \(topSongs.count) songs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let description = artistDescription {
                    ExpandableText(
                        text: description,
                        title: artist.name,
                        collapsedLineLimit: 3,
                        font: .caption,
                        uiTextStyle: .caption1,
                        textColor: Color.secondary.opacity(0.72),
                        toggleColor: .white.opacity(0.92),
                        multilineTextAlignment: .center
                    )
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private var artistDescription: String? {
        EditorialDescriptionPolicy.text(
            standard: artist.editorialNotes?.standard,
            short: artist.editorialNotes?.short,
            tagline: artist.editorialNotes?.tagline)
    }

    private var stationBadge: some View {
        Button {
            playArtistStation()
        } label: {
            ZStack {
                Circle()
                    .fill(actionTint)
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

                if isActionActive(.playStation) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: LocalMusicDetailAction.playStation.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isActionDisabled(.playStation))
        .opacity(isActionDisabled(.playStation) ? 0.45 : 1)
        .accessibilityLabel(LocalMusicDetailAction.playStation.title)
    }

    private var albumOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Albums")
                .font(.headline)
                .padding(.horizontal)

            if albums.isEmpty {
                ContentUnavailableView("No Albums", systemImage: "square.stack")
                    .padding(.top, 24)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 16
                ) {
                    ForEach(albums) { album in
                        NavigationLink {
                            LocalMusicAlbumDetailView(
                                album: album,
                                store: store,
                                manager: manager,
                                searchManager: searchManager)
                        } label: {
                            LocalMusicArtistLibraryAlbumCard(
                                album: album,
                                artworkURL: albumArtworkURL(for: album))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.top, 22)
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private var topSongsSection: some View {
        if !topSongs.isEmpty {
            LocalMusicArtistTopSongsSection(
                artistName: artist.name,
                songs: topSongs,
                store: store,
                manager: manager,
                searchManager: searchManager
            )
            .padding(.top, 22)
            .padding(.bottom, 22)
        }
    }

    private var actionTint: Color {
        themeColor ?? manager.albumArtDominantColor ?? .white.opacity(0.15)
    }

    private func isActionActive(_ action: LocalMusicDetailAction) -> Bool {
        actionInFlight == action ||
            (store.isStartingPlayback && store.activePlaybackItemID == displayID(for: action))
    }

    private func isActionDisabled(_ action: LocalMusicDetailAction) -> Bool {
        (actionInFlight != nil && actionInFlight != action) ||
            (store.isStartingPlayback && !isActionActive(action))
    }

    private func displayID(for action: LocalMusicDetailAction) -> String {
        switch action {
        case .playStation:
            return "\(artist.id.rawValue):station"
        case .play, .shuffle, .favorite, .openAppleMusic:
            return artist.id.rawValue
        }
    }

    private func albumArtworkURL(for album: Album) -> URL? {
        album.artwork.flatMap {
            LocalMusicArtworkURL.url(for: $0, shortSidePixels: 420)
        } ?? store.catalogArtworkURL(for: album)
    }

    private func openAppleMusicFromArtwork() {
        guard let url = LocalMusicAppleMusicURL.externalURL(
            existingURL: artist.url,
            catalogURL: nil,
            kind: .artist,
            requiresCatalogURL: true
        ) else { return }
        openLocalMusicAppleMusicURL(url, context: "catalog-artist-artwork title='\(artist.name)'")
    }

    private func playArtistStation() {
        guard actionInFlight == nil, !store.isStartingPlayback else { return }
        actionInFlight = .playStation

        Task {
            await store.playOnSonos(
                playable: artistPlayable,
                displayID: displayID(for: .playStation),
                fallbackKind: .artist,
                fallbackTitle: artist.name,
                fallbackArtist: artist.name,
                manager: manager,
                searchManager: searchManager)
            withAnimation(.easeOut(duration: 0.2)) {
                actionInFlight = nil
            }
        }
    }

    private func loadCoverImage(from url: URL?) async {
        guard let url else {
            coverImage = nil
            themeColor = nil
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            let image = UIImage(data: data)
            coverImage = image
            themeColor = image?.dominantColor()
        } catch {
            guard !Task.isCancelled else { return }
            SonosLog.error(.artistDetail, "Catalog artist image load failed: \(error)")
            coverImage = nil
            themeColor = nil
        }
    }
}

struct LocalMusicArtistTopSongsSection: View {
    let artistName: String
    let songs: [Song]
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    private var previewSongs: [Song] {
        Array(songs.prefix(LocalMusicArtistTopSongsPolicy.previewCount(totalCount: songs.count)))
    }

    private var showsFullListLink: Bool {
        LocalMusicArtistTopSongsPolicy.shouldShowFullListLink(totalCount: songs.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader

            LocalMusicArtistTopSongsRows(
                songs: previewSongs,
                store: store,
                manager: manager,
                searchManager: searchManager
            )
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        if showsFullListLink {
            NavigationLink {
                LocalMusicArtistTopSongsListView(
                    artistName: artistName,
                    songs: songs,
                    store: store,
                    manager: manager,
                    searchManager: searchManager
                )
            } label: {
                titleLabel(showChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            titleLabel(showChevron: false)
        }
    }

    private func titleLabel(showChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Text("Top Songs")
                .font(.headline)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal)
        .contentShape(Rectangle())
    }
}

private struct LocalMusicArtistTopSongsListView: View {
    let artistName: String
    let songs: [Song]
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Songs")
                        .font(.largeTitle.weight(.bold))
                    Text(artistName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 24)

                LocalMusicArtistTopSongsRows(
                    songs: songs,
                    store: store,
                    manager: manager,
                    searchManager: searchManager
                )
            }
            .padding(.bottom, 24)
        }
        .background(
            SonosArtworkBackground(
                image: manager.albumArtImage,
                fallbackColor: manager.albumArtDominantColor
            )
            .ignoresSafeArea()
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalMusicArtistTopSongsRows: View {
    let songs: [Song]
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                let playable = LocalServiceAppleMusicPlayable.make(song: song)
                LocalMusicSongRow(
                    song: song,
                    index: index,
                    subtitle: subtitle(for: song),
                    artwork: song.artwork,
                    artworkURL: store.catalogArtworkURL(for: song),
                    showsArtwork: true,
                    isPlaying: store.isStartingPlayback && store.activePlaybackItemID == song.id.rawValue,
                    contextMenuActions: MusicResourceActionPolicy.actions(
                        kind: .song,
                        isQueueable: true,
                        isAppleMusicFavoriteAvailable: AppleMusicFavoriteResource.fromLocalServicePlayable(playable) != nil
                    ),
                    menuAction: { action in
                        performMenuAction(action, song: song)
                    }
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
            }
        }
    }

    private func subtitle(for song: Song) -> String {
        if let albumTitle = song.albumTitle, !albumTitle.isEmpty {
            return albumTitle
        }
        return song.artistName
    }

    private func performMenuAction(_ action: MusicResourceMenuAction, song: Song) {
        switch action {
        case .playNow:
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
        case .playNext, .addToQueue:
            Task {
                await store.performSonosQueueAction(
                    action,
                    playable: LocalServiceAppleMusicPlayable.make(song: song),
                    displayID: song.id.rawValue,
                    fallbackKind: .song,
                    fallbackTitle: song.title,
                    fallbackArtist: song.artistName,
                    fallbackAlbum: song.albumTitle,
                    manager: manager,
                    searchManager: searchManager)
            }
        case .favorite(.sonos, _, _):
            Task { await toggleSongSonosFavorite(song) }
        case .favorite(.appleMusic, _, _):
            Task { await toggleSongAppleMusicFavorite(song) }
        case .startStation:
            break
        }
    }

    private func toggleSongSonosFavorite(_ song: Song) async {
        await store.toggleSonosFavorite(
            playable: LocalServiceAppleMusicPlayable.make(song: song),
            displayID: song.id.rawValue,
            fallbackKind: .song,
            fallbackTitle: song.title,
            fallbackArtist: song.artistName,
            fallbackAlbum: song.albumTitle,
            manager: manager,
            searchManager: searchManager)
    }

    private func toggleSongAppleMusicFavorite(_ song: Song) async {
        guard let resource = AppleMusicFavoriteResource.fromLocalServicePlayable(
            LocalServiceAppleMusicPlayable.make(song: song)
        ) else { return }
        _ = await searchManager.toggleAppleMusicFavorites(resource: resource)
    }
}

enum LocalMusicCatalogArtistContent {
    static func albums(for artist: Artist) -> [Album] {
        var seen = Set<String>()
        var result: [Album] = []

        func append(_ album: Album?) {
            guard let album else { return }
            let id = album.id.rawValue
            guard !seen.contains(id) else { return }
            seen.insert(id)
            result.append(album)
        }

        func append(_ albums: MusicItemCollection<Album>?) {
            guard let albums else { return }
            for album in albums {
                append(album)
            }
        }

        append(artist.latestRelease)
        append(artist.fullAlbums)
        append(artist.singles)
        append(artist.albums)

        return result
    }
}

struct LocalMusicArtistAlbumSongsView: View {
    let summary: LocalMusicArtistAlbumSummary
    let songs: [Song]
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var coverImage: UIImage?
    @State private var themeColor: Color?

    private var coverURL: URL? {
        summary.artworkURL ?? store.catalogArtworkURL(forArtistAlbum: summary)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                songList
                    .padding(.top, 18)
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: coverURL) { await loadCoverImage(from: coverURL) }
    }

    private var detailBackground: some View {
        SonosArtworkBackground(
            image: coverImage ?? manager.albumArtImage,
            fallbackColor: themeColor ?? manager.albumArtDominantColor
        )
        .animation(.easeInOut(duration: 0.8), value: coverURL)
        .animation(.easeInOut(duration: 0.8), value: themeColor)
    }

    private var header: some View {
        VStack(spacing: 12) {
            LocalMusicDetailArtwork(
                artwork: nil,
                artworkURL: coverURL,
                fallbackSystemImage: "square.stack"
            )

            VStack(spacing: 5) {
                Text(summary.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Text(summary.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text("\(songs.count) songs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private var songList: some View {
        if songs.isEmpty {
            ContentUnavailableView("No Songs", systemImage: "music.note.list")
                .padding(.top, 48)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    let playable = LocalServiceAppleMusicPlayable.make(song: song)
                    LocalMusicSongRow(
                        song: song,
                        index: index,
                        isPlaying: store.isStartingPlayback && store.activePlaybackItemID == song.id.rawValue,
                        contextMenuActions: MusicResourceActionPolicy.actions(
                            kind: .song,
                            isQueueable: true,
                            isAppleMusicFavoriteAvailable: AppleMusicFavoriteResource.fromLocalServicePlayable(playable) != nil
                        ),
                        menuAction: { action in
                            performMenuAction(action, song: song)
                        }
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
                }
            }
        }
    }

    private func performMenuAction(_ action: MusicResourceMenuAction, song: Song) {
        switch action {
        case .playNow, .playNext, .addToQueue:
            Task {
                await store.performSonosQueueAction(
                    action,
                    playable: LocalServiceAppleMusicPlayable.make(song: song),
                    displayID: song.id.rawValue,
                    fallbackKind: .song,
                    fallbackTitle: song.title,
                    fallbackArtist: song.artistName,
                    fallbackAlbum: song.albumTitle,
                    manager: manager,
                    searchManager: searchManager)
            }
        case .favorite(.sonos, _, _):
            Task {
                await store.toggleSonosFavorite(
                    playable: LocalServiceAppleMusicPlayable.make(song: song),
                    displayID: song.id.rawValue,
                    fallbackKind: .song,
                    fallbackTitle: song.title,
                    fallbackArtist: song.artistName,
                    fallbackAlbum: song.albumTitle,
                    manager: manager,
                    searchManager: searchManager)
            }
        case .favorite(.appleMusic, _, _):
            Task {
                guard let resource = AppleMusicFavoriteResource.fromLocalServicePlayable(
                    LocalServiceAppleMusicPlayable.make(song: song)
                ) else { return }
                _ = await searchManager.toggleAppleMusicFavorites(resource: resource)
            }
        case .startStation:
            break
        }
    }

    private func loadCoverImage(from url: URL?) async {
        guard let url else {
            coverImage = nil
            themeColor = nil
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            let image = UIImage(data: data)
            coverImage = image
            themeColor = image?.dominantColor()
        } catch {
            guard !Task.isCancelled else { return }
            SonosLog.error(.albumDetail, "Local Music artist album image load failed: \(error)")
            coverImage = nil
            themeColor = nil
        }
    }
}
