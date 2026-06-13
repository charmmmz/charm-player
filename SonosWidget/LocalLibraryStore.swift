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
                hasMusicKitArtwork: $0.artwork != nil,
                directArtworkURLString: Self.directArtworkURLString($0.artwork))
        })
        items.append(contentsOf: snapshot.albums.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .album,
                title: $0.title,
                artist: $0.artistName,
                album: $0.title,
                hasMusicKitArtwork: $0.artwork != nil,
                directArtworkURLString: Self.directArtworkURLString($0.artwork))
        })
        items.append(contentsOf: snapshot.artists.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .artist,
                title: $0.name,
                artist: $0.name,
                album: nil,
                hasMusicKitArtwork: $0.artwork != nil,
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
                hasMusicKitArtwork: $0.artwork != nil,
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
        return LocalMusicCatalogArtworkLookupItem(
            id: id ?? album.id.rawValue,
            kind: .album,
            title: album.title,
            artist: album.artistName,
            album: album.title,
            hasMusicKitArtwork: album.artwork != nil,
            directArtworkURLString: Self.directArtworkURLString(album.artwork))
    }

    private static func artworkLookupItem(for playlist: Playlist, id: String? = nil) -> LocalMusicCatalogArtworkLookupItem {
        let storageID = id ?? playlist.id.rawValue
        let urlString = playlist.url?.absoluteString
        let catalogID = LocalMusicCatalogIDExtractor.playlistCatalogID(
            rawID: storageID,
            urlString: urlString)
        let directArtworkURLString = Self.directArtworkURLString(playlist.artwork)

        SonosLog.debug(
            .localService,
            "Playlist artwork input title='\(playlist.name)' rawID='\(storageID)' " +
                "catalogID=\(Self.diagnosticValue(catalogID)) curator=\(Self.diagnosticValue(playlist.curatorName)) " +
                "url=\(Self.diagnosticValue(urlString)) directArtwork=\(Self.diagnosticURLStatus(directArtworkURLString))")

        return LocalMusicCatalogArtworkLookupItem(
            id: storageID,
            kind: .playlist,
            catalogID: catalogID,
            title: playlist.name,
            artist: playlist.curatorName,
            album: nil,
            hasMusicKitArtwork: playlist.artwork != nil,
            directArtworkURLString: directArtworkURLString)
    }

    private func scheduleCatalogArtworkLookup(for items: [LocalMusicCatalogArtworkLookupItem]) {
        let plan = LocalMusicCatalogArtworkPlan.make(
            items: items,
            inMemoryURLStrings: catalogArtworkURLStrings,
            inMemoryMissIDs: catalogArtworkMissIDs,
            cache: catalogArtworkCache)

        logPlaylistArtworkPlan(items: items, plan: plan)

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

    private func logPlaylistArtworkPlan(
        items: [LocalMusicCatalogArtworkLookupItem],
        plan: LocalMusicCatalogArtworkPlan
    ) {
        let playlistItems = items.filter { $0.kind == .playlist }
        guard !playlistItems.isEmpty else { return }

        let lookupKeys = Set(plan.lookupItems.map(\.key))
        SonosLog.debug(
            .localService,
            "Playlist artwork plan total=\(playlistItems.count) " +
                "immediate=\(plan.immediateURLStringsByKey.count) lookup=\(plan.lookupItems.count)")

        for item in playlistItems {
            let key = item.key
            let status: String
            if plan.immediateURLStringsByKey[key] != nil {
                status = "immediate"
            } else if lookupKeys.contains(key) {
                status = "scheduled"
            } else if catalogArtworkURLStrings[key.storageKey] != nil {
                status = "skip-in-memory"
            } else if catalogArtworkMissIDs.contains(key.storageKey) {
                status = "skip-miss"
            } else if catalogArtworkCache.urlString(for: key) != nil {
                status = "skip-cache"
            } else {
                status = "skip-unknown"
            }

            SonosLog.debug(
                .localService,
                "Playlist artwork plan status=\(status) title='\(item.title)' storageKey='\(key.storageKey)' " +
                    "catalogID=\(Self.diagnosticValue(item.catalogID)) " +
                    "directArtwork=\(Self.diagnosticURLStatus(item.directArtworkURLString))")
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
                if result.item.kind == .playlist {
                    SonosLog.debug(
                        .localService,
                        "Playlist artwork resolved title='\(result.item.title)' storageKey='\(key.storageKey)' " +
                            "url=\(Self.diagnosticURLStatus(urlString))")
                }
                catalogArtworkURLStrings[key.storageKey] = urlString
                catalogArtworkCache.storeURLString(urlString, for: key)
            } else {
                if result.item.kind == .playlist {
                    SonosLog.debug(
                        .localService,
                        "Playlist artwork unresolved title='\(result.item.title)' storageKey='\(key.storageKey)' " +
                            "catalogID=\(Self.diagnosticValue(result.item.catalogID))")
                }
                catalogArtworkMissIDs.insert(key.storageKey)
            }
        }
    }

    private static func catalogArtworkURLString(for item: LocalMusicCatalogArtworkLookupItem) async -> String? {
        if item.kind == .playlist {
            if let catalogID = item.catalogID {
                SonosLog.debug(
                    .localService,
                    "Playlist artwork direct catalog lookup start title='\(item.title)' catalogID='\(catalogID)'")

                do {
                    if let urlString = try await AppleMusicCatalogSearchClient.shared.playlistArtworkURLString(
                        catalogID: catalogID
                    ) {
                        SonosLog.debug(
                            .localService,
                            "Playlist artwork direct catalog lookup success title='\(item.title)' " +
                                "catalogID='\(catalogID)' url=\(diagnosticURLStatus(urlString))")
                        return urlString
                    }
                    SonosLog.debug(
                        .localService,
                        "Playlist artwork direct catalog lookup empty title='\(item.title)' catalogID='\(catalogID)'")
                } catch {
                    SonosLog.debug(
                        .localService,
                        "Playlist artwork direct catalog lookup failed title='\(item.title)' " +
                            "catalogID='\(catalogID)' error=\(error)")
                }
            } else {
                SonosLog.debug(
                    .localService,
                    "Playlist artwork direct catalog lookup skipped title='\(item.title)' reason=no-catalog-id")
            }
        }

        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: item.kind,
            title: item.title,
            artist: item.artist,
            album: item.album)
        guard !term.isEmpty else {
            if item.kind == .playlist {
                SonosLog.debug(.localService, "Playlist artwork fallback skipped title='\(item.title)' reason=empty-term")
            }
            return nil
        }

        do {
            if item.kind == .playlist {
                SonosLog.debug(
                    .localService,
                    "Playlist artwork fallback search start title='\(item.title)' term='\(term)' " +
                        "curator=\(diagnosticValue(item.artist))")
            }
            let items = try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: 8)
            let match = LocalMusicCatalogMatcher.bestItem(
                in: items,
                kind: item.kind,
                title: item.title,
                artist: item.artist,
                album: item.album)
            let urlString = LocalMusicCatalogArtworkFallback.artworkURLString(
                in: items,
                kind: item.kind,
                title: item.title,
                artist: item.artist,
                album: item.album)

            if item.kind == .playlist {
                SonosLog.debug(
                    .localService,
                    "Playlist artwork fallback search result title='\(item.title)' term='\(term)' " +
                        "candidateSummary=\(Self.catalogSearchSummary(items)) " +
                        "match=\(Self.catalogSearchMatchSummary(match)) url=\(diagnosticURLStatus(urlString))")
            }
            return urlString
        } catch {
            if item.kind == .playlist {
                SonosLog.debug(
                    .localService,
                    "Playlist artwork fallback search failed title='\(item.title)' term='\(term)' error=\(error)")
            } else {
                SonosLog.debug(.search, "LocalService catalog artwork fallback failed for '\(term)': \(error)")
            }
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

    private static func diagnosticValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        return "'\(value)'"
    }

    private static func diagnosticURLStatus(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        let status = LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(value) ? "loadable" : "not-loadable"
        return "\(status)('\(value)')"
    }

    private static func catalogSearchSummary(_ items: [AppleMusicCatalogSearchItem]) -> String {
        let playlists = items.filter { $0.type == .playlist }
        guard !playlists.isEmpty else { return "playlists=0 total=\(items.count)" }
        let preview = playlists.prefix(3).map {
            "\($0.id)|\($0.title)|\($0.artist)|art=\(diagnosticURLStatus($0.artworkURLString))"
        }.joined(separator: "; ")
        return "playlists=\(playlists.count) total=\(items.count) preview=[\(preview)]"
    }

    private static func catalogSearchMatchSummary(_ item: AppleMusicCatalogSearchItem?) -> String {
        guard let item else { return "nil" }
        return "'\(item.id)|\(item.title)|\(item.artist)'"
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
