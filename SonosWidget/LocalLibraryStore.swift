import Foundation
import MusicKit
import Observation

@MainActor
@Observable
final class LocalLibraryStore {
    private let client: LocalMusicLibraryClient
    private let catalogArtworkCache: LocalMusicCatalogArtworkCache

    var authorizationStatus = MusicAuthorization.currentStatus
    var snapshot = LocalMusicLibrarySnapshot()
    var recentlyPlayed: [RecentlyPlayedMusicItem] = []
    var recommendations: [MusicPersonalRecommendation] = []
    var searchSnapshot: LocalMusicLibrarySnapshot?
    var isLoading = false
    var isSearching = false
    var isStartingPlayback = false
    var activePlaybackItemID: String?
    var errorMessage: String?
    var hasLoaded = false
    var catalogArtworkURLStrings: [String: String] = [:]

    @ObservationIgnored private var artworkLookupTask: Task<Void, Never>?
    @ObservationIgnored private var catalogArtworkMissIDs: Set<String> = []

    convenience init() {
        self.init(client: .shared)
    }

    init(
        client: LocalMusicLibraryClient,
        catalogArtworkCache: LocalMusicCatalogArtworkCache = .shared
    ) {
        self.client = client
        self.catalogArtworkCache = catalogArtworkCache
    }

    var displayedSnapshot: LocalMusicLibrarySnapshot {
        searchSnapshot ?? snapshot
    }

    var hasHomeContent: Bool {
        !snapshot.isEmpty || !recentlyPlayed.isEmpty || !recommendations.isEmpty
    }

    var summary: LocalLibrarySnapshotSummary {
        displayedSnapshot.summary
    }

    func itemsAreEmpty(for category: LocalLibraryCategory) -> Bool {
        summary.count(for: category) == 0
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        artworkLookupTask?.cancel()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            authorizationStatus = try await client.authorize()
            let content = try await client.loadHomeContent()
            snapshot = content.snapshot
            recentlyPlayed = content.recentlyPlayed
            recommendations = content.recommendations
            searchSnapshot = nil
            catalogArtworkURLStrings = [:]
            catalogArtworkMissIDs = []
            hasLoaded = true
            scheduleCatalogArtworkLookup(for: content)
        } catch {
            authorizationStatus = MusicAuthorization.currentStatus
            errorMessage = displayMessage(for: error)
        }
    }

    func search(term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchSnapshot = nil
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        do {
            authorizationStatus = try await client.authorize()
            let snapshot = try await client.search(term: trimmed)
            searchSnapshot = snapshot
            scheduleCatalogArtworkLookup(for: snapshot)
        } catch {
            guard !Task.isCancelled else { return }
            searchSnapshot = nil
            authorizationStatus = MusicAuthorization.currentStatus
            errorMessage = displayMessage(for: error)
        }

        isSearching = false
    }

    func catalogArtworkURL(for song: Song) -> URL? {
        catalogArtworkURL(kind: .song, id: song.id.rawValue)
    }

    func catalogArtworkURL(for album: Album) -> URL? {
        catalogArtworkURL(kind: .album, id: album.id.rawValue)
    }

    func catalogArtworkURL(for artist: Artist) -> URL? {
        catalogArtworkURL(kind: .artist, id: artist.id.rawValue)
    }

    func catalogArtworkURL(for playlist: Playlist) -> URL? {
        catalogArtworkURL(kind: .playlist, id: playlist.id.rawValue)
    }

    func catalogArtworkURL(for recentlyPlayed: RecentlyPlayedMusicItem) -> URL? {
        switch recentlyPlayed {
        case .album:
            return catalogArtworkURL(kind: .album, id: recentlyPlayed.id.rawValue)
        case .playlist:
            return catalogArtworkURL(kind: .playlist, id: recentlyPlayed.id.rawValue)
        case .station:
            return nil
        @unknown default:
            return nil
        }
    }

    func catalogArtworkURL(for recommendation: MusicPersonalRecommendation.Item) -> URL? {
        switch recommendation {
        case .album:
            return catalogArtworkURL(kind: .album, id: recommendation.id.rawValue)
        case .playlist:
            return catalogArtworkURL(kind: .playlist, id: recommendation.id.rawValue)
        case .station:
            return nil
        @unknown default:
            return nil
        }
    }

    func play(song: Song) async {
        await runPlayback(id: song.id.rawValue) {
            try await client.play(song: song)
        }
    }

    func play(track: Track) async {
        await runPlayback(id: track.id.rawValue) {
            try await client.play(track: track)
        }
    }

    func play(album: Album) async {
        await runPlayback(id: album.id.rawValue) {
            try await client.play(album: album)
        }
    }

    func play(recentlyPlayed item: RecentlyPlayedMusicItem) async {
        await runPlayback(id: item.id.rawValue) {
            try await client.play(recentlyPlayed: item)
        }
    }

    func play(recommendation item: MusicPersonalRecommendation.Item) async {
        await runPlayback(id: item.id.rawValue) {
            try await client.play(recommendation: item)
        }
    }

    func play(artist: Artist) async {
        await runPlayback(id: artist.id.rawValue) {
            try await client.play(artist: artist)
        }
    }

    func play(playlist: Playlist) async {
        await runPlayback(id: playlist.id.rawValue) {
            try await client.play(playlist: playlist)
        }
    }

    func play(station: Station) async {
        await runPlayback(id: station.id.rawValue) {
            try await client.play(station: station)
        }
    }

    func playOnSonos(
        playable: LocalServiceAppleMusicPlayable?,
        displayID: String,
        fallbackKind: LocalServiceAppleMusicPlayable.Kind? = nil,
        fallbackTitle: String? = nil,
        fallbackArtist: String? = nil,
        fallbackAlbum: String? = nil,
        manager: SonosManager,
        searchManager: SearchManager
    ) async {
        await runPlayback(id: displayID) {
            var didAttemptPlayback = false
            if let playable {
                didAttemptPlayback = true
                let didStart = await searchManager.playLocalAppleMusic(playable, manager: manager)
                if didStart { return }
            }

            if let fallbackKind,
               let fallbackTitle,
               let catalogPlayable = await catalogFallbackPlayable(
                kind: fallbackKind,
                title: fallbackTitle,
                artist: fallbackArtist,
                album: fallbackAlbum
               ),
               catalogPlayable.id != playable?.id {
                didAttemptPlayback = true
                let didStart = await searchManager.playLocalAppleMusic(catalogPlayable, manager: manager)
                if didStart { return }
            }

            if !didAttemptPlayback {
                throw LocalServiceSonosPlaybackError.noPlayableCatalogID
            }
            throw LocalServiceSonosPlaybackError.playbackFailed(searchManager.errorMessage)
        }
    }

    private func catalogFallbackPlayable(
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) async -> LocalServiceAppleMusicPlayable? {
        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: kind,
            title: title,
            artist: artist,
            album: album)
        guard !term.isEmpty else { return nil }

        do {
            let items = try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: 12)
            guard let item = LocalMusicCatalogMatcher.bestItem(
                in: items,
                kind: kind,
                title: title,
                artist: artist,
                album: album
            ) else {
                SonosLog.info(.playback, "LocalService catalog fallback found no \(kind) match for '\(term)'")
                return nil
            }

            SonosLog.info(
                .playback,
                "LocalService catalog fallback kind=\(kind) term='\(term)' matched \(item.sonosPlayableObjectID)")
            return LocalServiceAppleMusicPlayable.make(catalogItem: item)
        } catch {
            SonosLog.info(.playback, "LocalService catalog fallback failed for '\(term)': \(error)")
            return nil
        }
    }

    func songs(for artist: Artist, limit: Int = 100) async throws -> [Song] {
        try await client.songs(for: artist, limit: limit)
    }

    private func catalogArtworkURL(kind: LocalServiceAppleMusicPlayable.Kind, id: String) -> URL? {
        catalogArtworkURLStrings[Self.catalogArtworkKey(kind: kind, id: id)]
            .flatMap(URL.init(string:))
    }

    private func scheduleCatalogArtworkLookup(for content: LocalMusicHomeContent) {
        var items = Self.artworkLookupItems(for: content.snapshot)
        items.append(contentsOf: content.recentlyPlayed.compactMap(Self.artworkLookupItem(for:)))
        for recommendation in content.recommendations {
            items.append(contentsOf: recommendation.items.compactMap(Self.artworkLookupItem(for:)))
            items.append(contentsOf: recommendation.albums.map { Self.artworkLookupItem(for: $0) })
            items.append(contentsOf: recommendation.playlists.map { Self.artworkLookupItem(for: $0) })
        }
        scheduleCatalogArtworkLookup(for: items)
    }

    private func scheduleCatalogArtworkLookup(for snapshot: LocalMusicLibrarySnapshot) {
        scheduleCatalogArtworkLookup(for: Self.artworkLookupItems(for: snapshot))
    }

    private static func artworkLookupItems(for snapshot: LocalMusicLibrarySnapshot) -> [LocalMusicCatalogArtworkLookupItem] {
        var items: [LocalMusicCatalogArtworkLookupItem] = []
        items.append(contentsOf: snapshot.songs.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .song,
                title: $0.title,
                artist: $0.artistName,
                album: $0.albumTitle,
                directArtworkURLString: Self.directArtworkURLString($0.artwork))
        })
        items.append(contentsOf: snapshot.albums.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .album,
                title: $0.title,
                artist: $0.artistName,
                album: $0.title,
                directArtworkURLString: Self.directArtworkURLString($0.artwork))
        })
        items.append(contentsOf: snapshot.artists.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .artist,
                title: $0.name,
                artist: $0.name,
                album: nil,
                directArtworkURLString: Self.directArtworkURLString($0.artwork))
        })
        items.append(contentsOf: snapshot.playlists.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .playlist,
                catalogID: LocalMusicCatalogIDExtractor.playlistCatalogID(
                    rawID: $0.id.rawValue,
                    urlString: $0.url?.absoluteString),
                title: $0.name,
                artist: $0.curatorName,
                album: nil,
                directArtworkURLString: Self.directArtworkURLString($0.artwork))
        })
        return items
    }

    private static func artworkLookupItem(for item: RecentlyPlayedMusicItem) -> LocalMusicCatalogArtworkLookupItem? {
        switch item {
        case .album(let album):
            return artworkLookupItem(for: album, id: item.id.rawValue)
        case .playlist(let playlist):
            return artworkLookupItem(for: playlist, id: item.id.rawValue)
        case .station:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func artworkLookupItem(
        for item: MusicPersonalRecommendation.Item
    ) -> LocalMusicCatalogArtworkLookupItem? {
        switch item {
        case .album(let album):
            return artworkLookupItem(for: album, id: item.id.rawValue)
        case .playlist(let playlist):
            return artworkLookupItem(for: playlist, id: item.id.rawValue)
        case .station:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func artworkLookupItem(for album: Album, id: String? = nil) -> LocalMusicCatalogArtworkLookupItem {
        LocalMusicCatalogArtworkLookupItem(
            id: id ?? album.id.rawValue,
            kind: .album,
            title: album.title,
            artist: album.artistName,
            album: album.title,
            directArtworkURLString: Self.directArtworkURLString(album.artwork))
    }

    private static func artworkLookupItem(for playlist: Playlist, id: String? = nil) -> LocalMusicCatalogArtworkLookupItem {
        LocalMusicCatalogArtworkLookupItem(
            id: id ?? playlist.id.rawValue,
            kind: .playlist,
            catalogID: LocalMusicCatalogIDExtractor.playlistCatalogID(
                rawID: id ?? playlist.id.rawValue,
                urlString: playlist.url?.absoluteString),
            title: playlist.name,
            artist: playlist.curatorName,
            album: nil,
            directArtworkURLString: Self.directArtworkURLString(playlist.artwork))
    }

    private func scheduleCatalogArtworkLookup(for items: [LocalMusicCatalogArtworkLookupItem]) {
        let plan = LocalMusicCatalogArtworkPlan.make(
            items: items,
            inMemoryURLStrings: catalogArtworkURLStrings,
            inMemoryMissIDs: catalogArtworkMissIDs,
            cache: catalogArtworkCache)

        for (key, urlString) in plan.immediateURLStringsByKey {
            catalogArtworkURLStrings[key.storageKey] = urlString
            catalogArtworkCache.storeURLString(urlString, for: key)
        }

        let candidates = plan.lookupItems
        guard !candidates.isEmpty else { return }

        artworkLookupTask?.cancel()
        artworkLookupTask = Task { [weak self] in
            await self?.resolveCatalogArtwork(for: candidates)
        }
    }

    private func resolveCatalogArtwork(for items: [LocalMusicCatalogArtworkLookupItem]) async {
        SonosLog.debug(
            .search,
            "LocalService resolving catalog artwork for \(items.count) library items " +
                "with concurrency=\(LocalMusicCatalogArtworkResolver.defaultMaxConcurrentLookups)")

        let results = await LocalMusicCatalogArtworkResolver.resolve(items: items) { item in
            await Self.catalogArtworkURLString(for: item)
        }

        guard !Task.isCancelled else { return }
        for result in results {
            let key = result.item.key
            if let urlString = result.urlString {
                catalogArtworkURLStrings[key.storageKey] = urlString
                catalogArtworkCache.storeURLString(urlString, for: key)
            } else {
                catalogArtworkMissIDs.insert(key.storageKey)
            }
        }
    }

    private static func catalogArtworkURLString(for item: LocalMusicCatalogArtworkLookupItem) async -> String? {
        if item.kind == .playlist,
           let catalogID = item.catalogID {
            do {
                if let urlString = try await AppleMusicCatalogSearchClient.shared.playlistArtworkURLString(
                    catalogID: catalogID
                ) {
                    return urlString
                }
            } catch {
                SonosLog.debug(
                    .search,
                    "LocalService catalog playlist artwork direct lookup failed for '\(catalogID)': \(error)")
            }
        }

        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: item.kind,
            title: item.title,
            artist: item.artist,
            album: item.album)
        guard !term.isEmpty else { return nil }

        do {
            let items = try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: 8)
            return LocalMusicCatalogArtworkFallback.artworkURLString(
                in: items,
                kind: item.kind,
                title: item.title,
                artist: item.artist,
                album: item.album)
        } catch {
            SonosLog.debug(.search, "LocalService catalog artwork fallback failed for '\(term)': \(error)")
            return nil
        }
    }

    private static func catalogArtworkKey(kind: LocalServiceAppleMusicPlayable.Kind, id: String) -> String {
        LocalMusicCatalogArtworkKey(kind: kind, id: id).storageKey
    }

    private static func directArtworkURLString(_ artwork: Artwork?) -> String? {
        guard let artwork else { return nil }
        return LocalMusicArtworkURL.url(for: artwork, shortSidePixels: 400)?.absoluteString
    }

    private func runPlayback(id: String, action: () async throws -> Void) async {
        isStartingPlayback = true
        activePlaybackItemID = id
        errorMessage = nil
        defer { isStartingPlayback = false }

        do {
            try await action()
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    private func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
