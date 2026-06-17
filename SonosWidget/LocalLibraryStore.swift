import Foundation
import MusicKit
import Observation

enum LocalLibraryRecommendationRefreshPolicy {
    static func shouldReplace(existingCount: Int, didLoadRecommendations: Bool) -> Bool {
        didLoadRecommendations || existingCount == 0
    }
}

enum LocalLibraryRefreshSource: String {
    case initial
    case pullToRefresh = "pull"
    case button
    case recovery
}

enum LocalLibraryRefreshExecutionPolicy {
    static func shouldDetachFromCallerCancellation(source: LocalLibraryRefreshSource) -> Bool {
        source == .pullToRefresh
    }
}

enum LocalLibraryPullRefreshPolicy {
    static let triggerDistance = 128.0
    static let resetDistance = 18.0

    static func shouldTrigger(
        pullDistance: Double,
        isRefreshing: Bool,
        hasLoaded: Bool,
        hasTriggeredInCurrentPull: Bool = false
    ) -> Bool {
        hasLoaded && !isRefreshing && !hasTriggeredInCurrentPull && pullDistance >= triggerDistance
    }

    static func shouldResetGesture(pullDistance: Double) -> Bool {
        pullDistance < resetDistance
    }

    static func indicatorOpacity(
        pullDistance: Double,
        isRefreshing: Bool
    ) -> Double {
        guard !isRefreshing else { return 1 }
        guard triggerDistance > 0 else { return 0 }
        return min(max(pullDistance / triggerDistance, 0), 1)
    }
}

@MainActor
@Observable
final class LocalLibraryStore {
    private let client: LocalMusicLibraryClient
    private let catalogSearchClient: AppleMusicCatalogSearchClient
    private let catalogArtworkCache: LocalMusicCatalogArtworkCache

    var authorizationStatus = MusicAuthorization.currentStatus
    var snapshot = LocalMusicLibrarySnapshot()
    var recentlyAddedContent = LocalMusicRecentlyAddedContent()
    var recentlyPlayed: [RecentlyPlayedMusicItem] = []
    var recommendations: [MusicPersonalRecommendation] = []
    var searchSnapshot: LocalMusicLibrarySnapshot?
    var catalogSearchResults = LocalServiceCatalogSearchResults()
    var isLoading = false
    var isSearching = false
    var isStartingPlayback = false
    var activePlaybackItemID: String?
    var errorMessage: String?
    var hasLoaded = false
    var catalogArtworkURLStrings: [String: String] = [:]

    @ObservationIgnored private var artworkLookupTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var catalogArtworkMissIDs: Set<String> = []
    @ObservationIgnored private var catalogArtworkInFlightIDs: Set<String> = []

    convenience init() {
        self.init(
            client: .shared,
            catalogSearchClient: AppleMusicCatalogSearchClient()
        )
    }

    init(
        client: LocalMusicLibraryClient,
        catalogSearchClient: AppleMusicCatalogSearchClient,
        catalogArtworkCache: LocalMusicCatalogArtworkCache = .shared
    ) {
        self.client = client
        self.catalogSearchClient = catalogSearchClient
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
        await refresh(source: .initial)
    }

    func reload() async {
        await refresh(source: .button)
    }

    func refresh(source: LocalLibraryRefreshSource) async {
        if LocalLibraryRefreshExecutionPolicy.shouldDetachFromCallerCancellation(source: source) {
            let task = Task { [weak self] in
                await self?.performReload(source: source)
            }
            await task.value
            return
        }

        await performReload(source: source)
    }

    private func performReload(source: LocalLibraryRefreshSource) async {
        cancelCatalogArtworkLookupTasks()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let previousRecommendationCount = recommendations.count
            SonosLog.info(
                .localService,
                "Local library refresh start source=\(source.rawValue) existingRecommendations=\(previousRecommendationCount)")

            authorizationStatus = try await client.authorize()
            let content = try await client.loadHomeContent()
            let shouldReplaceRecommendations = LocalLibraryRecommendationRefreshPolicy.shouldReplace(
                existingCount: recommendations.count,
                didLoadRecommendations: content.recommendationsLoaded)
            let nextRecommendations = shouldReplaceRecommendations
                ? content.recommendations
                : recommendations
            var artworkContent = content
            artworkContent.recommendations = nextRecommendations

            if !shouldReplaceRecommendations {
                SonosLog.info(
                    .localService,
                    "Keeping \(recommendations.count) existing recommendation sections after refresh skipped recommendations " +
                        "source=\(source.rawValue) status=\(content.recommendationsLoadStatus.diagnosticDescription)")
            }

            snapshot = content.snapshot
            recentlyAddedContent = LocalMusicRecentlyAddedContent(snapshot: content.snapshot)
            recentlyPlayed = content.recentlyPlayed
            recommendations = nextRecommendations
            searchSnapshot = nil
            catalogSearchResults = LocalServiceCatalogSearchResults()
            catalogArtworkURLStrings = [:]
            catalogArtworkMissIDs = []
            catalogArtworkInFlightIDs = []
            hasLoaded = true
            scheduleCatalogArtworkLookup(for: artworkContent)
            SonosLog.info(
                .localService,
                "Local library refresh resolved source=\(source.rawValue) " +
                    "songs=\(snapshot.songs.count) albums=\(snapshot.albums.count) " +
                    "artists=\(snapshot.artists.count) playlists=\(snapshot.playlists.count) " +
                    "recentlyPlayed=\(recentlyPlayed.count) " +
                    "recommendationsStatus=\(content.recommendationsLoadStatus.diagnosticDescription) " +
                    "recommendations=\(recommendations.count)")
        } catch {
            authorizationStatus = MusicAuthorization.currentStatus
            errorMessage = displayMessage(for: error)
            SonosLog.error(
                .localService,
                "Local library refresh failed source=\(source.rawValue) error=\(type(of: error)): \(error)")
        }
    }

    func search(term: String, scope: LocalServiceSearchScope) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchSnapshot = nil
            catalogSearchResults = LocalServiceCatalogSearchResults()
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        do {
            switch scope {
            case .library:
                catalogSearchResults = LocalServiceCatalogSearchResults()
                authorizationStatus = try await client.authorize()
                let snapshot = try await client.search(term: trimmed)
                guard !Task.isCancelled else { return }
                searchSnapshot = snapshot
                scheduleCatalogArtworkLookup(for: snapshot)
            case .appleMusic:
                searchSnapshot = nil
                let items = try await catalogSearchClient.search(
                    term: trimmed,
                    limit: AppleMusicCatalogSearchClient.maximumSearchLimit
                )
                guard !Task.isCancelled else { return }
                catalogSearchResults = LocalServiceCatalogSearchResults(items: items)
            }
        } catch {
            guard !Task.isCancelled else { return }
            if scope == .library {
                searchSnapshot = nil
            } else {
                catalogSearchResults = LocalServiceCatalogSearchResults()
            }
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

    func catalogArtworkURL(forArtistAlbum summary: LocalMusicArtistAlbumSummary) -> URL? {
        catalogArtworkURL(kind: .album, id: summary.id)
    }

    func catalogArtworkURL(forPlaylistTrack track: Track) -> URL? {
        catalogArtworkURL(
            kind: .song,
            id: Self.playlistTrackArtworkStorageID(for: track))
    }

    func ensureCatalogArtwork(forArtistAlbumSummaries summaries: [LocalMusicArtistAlbumSummary]) {
        scheduleCatalogArtworkLookup(
            for: LocalMusicArtistAlbumSummaryBuilder.artworkLookupItems(from: summaries))
    }

    func ensureCatalogArtwork(forArtistAlbums albums: [Album]) {
        scheduleCatalogArtworkLookup(for: albums.map { Self.artworkLookupItem(for: $0) })
    }

    func ensureCatalogArtwork(forPlaylistTracks tracks: [Track]) {
        scheduleCatalogArtworkLookup(for: tracks.map { Self.artworkLookupItem(forPlaylistTrack: $0) })
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
            try await startOnSonos(
                playable: playable,
                fallbackKind: fallbackKind,
                fallbackTitle: fallbackTitle,
                fallbackArtist: fallbackArtist,
                fallbackAlbum: fallbackAlbum,
                manager: manager,
            searchManager: searchManager)
        }
    }

    func playDisplayedTracksOnSonos(
        tracks: [Track],
        displayID: String,
        albumTitle: String,
        manager: SonosManager,
        searchManager: SearchManager
    ) async {
        await runPlayback(id: displayID) {
            let items = try await resolveQueueBrowseItems(
                tracks: tracks,
                manager: manager,
                searchManager: searchManager)
            let didStart = await searchManager.playNow(
                items: items,
                manager: manager,
                displayTitle: albumTitle)
            guard didStart else {
                throw LocalServiceSonosPlaybackError.playbackFailed(
                    searchManager.errorMessage ?? manager.errorMessage)
            }
        }
    }

    func performSonosQueueAction(
        _ action: MusicResourceMenuAction,
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
            switch action {
            case .playNow, .startStation:
                try await startOnSonos(
                    playable: playable,
                    fallbackKind: fallbackKind,
                    fallbackTitle: fallbackTitle,
                    fallbackArtist: fallbackArtist,
                    fallbackAlbum: fallbackAlbum,
                    manager: manager,
                    searchManager: searchManager)
            case .favorite:
                return
            case .playNext, .addToQueue:
                let playableKind = playable?.kind.cloudType ?? "nil"
                let playableID = SonosLog.playbackLinkValue(playable?.catalogID, maxLength: 640)
                let fallbackKindValue = fallbackKind?.cloudType ?? "nil"
                let fallbackTitleValue = fallbackTitle ?? "nil"
                let queueActionMessage = "LocalService queue action=\(action.id) displayID=\(displayID) " +
                    "playableKind=\(playableKind) playableID=\(playableID) " +
                    "fallbackKind=\(fallbackKindValue) fallbackTitle='\(fallbackTitleValue)'"
                SonosLog.debug(
                    .playbackLink,
                    queueActionMessage)
                let item = try await resolveQueueBrowseItem(
                    playable: playable,
                    fallbackKind: fallbackKind,
                    fallbackTitle: fallbackTitle,
                    fallbackArtist: fallbackArtist,
                    fallbackAlbum: fallbackAlbum,
                    manager: manager,
                    searchManager: searchManager)

                searchManager.errorMessage = nil
                manager.errorMessage = nil
                let didQueue: Bool
                switch action {
                case .playNext:
                    didQueue = await searchManager.playNext(item: item, manager: manager)
                case .addToQueue:
                    didQueue = await searchManager.addToQueue(item: item, manager: manager)
                case .playNow, .startStation, .favorite:
                    didQueue = false
                }

                guard didQueue else {
                    throw LocalServiceSonosPlaybackError.playbackFailed(
                        searchManager.errorMessage ?? manager.errorMessage)
                }
            }
        }
    }

    private func startOnSonos(
        playable: LocalServiceAppleMusicPlayable?,
        fallbackKind: LocalServiceAppleMusicPlayable.Kind?,
        fallbackTitle: String?,
        fallbackArtist: String?,
        fallbackAlbum: String?,
        manager: SonosManager,
        searchManager: SearchManager
    ) async throws {
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

    private func resolveQueueBrowseItems(
        tracks: [Track],
        manager: SonosManager,
        searchManager: SearchManager
    ) async throws -> [BrowseItem] {
        var items: [BrowseItem] = []
        for track in tracks {
            do {
                let item = try await resolveQueueBrowseItem(
                    playable: LocalServiceAppleMusicPlayable.make(track: track),
                    fallbackKind: .song,
                    fallbackTitle: track.title,
                    fallbackArtist: track.artistName,
                    fallbackAlbum: track.albumTitle,
                    manager: manager,
                    searchManager: searchManager)
                items.append(item)
            } catch {
                SonosLog.info(
                    .playback,
                    "LocalService displayed track queue skipped title='\(track.title)' " +
                        "artist='\(track.artistName)' error=\(error)")
            }
        }

        guard !items.isEmpty else {
            throw LocalServiceSonosPlaybackError.noPlayableCatalogID
        }
        return items
    }

    private func resolveQueueBrowseItem(
        playable: LocalServiceAppleMusicPlayable?,
        fallbackKind: LocalServiceAppleMusicPlayable.Kind?,
        fallbackTitle: String?,
        fallbackArtist: String?,
        fallbackAlbum: String?,
        manager: SonosManager,
        searchManager: SearchManager
    ) async throws -> BrowseItem {
        var didAttemptResolution = false
        if let playable {
            didAttemptResolution = true
            let primaryCatalogID = SonosLog.playbackLinkValue(playable.catalogID, maxLength: 640)
            let primaryResolveMessage = "LocalService queue resolve primary kind=\(playable.kind.cloudType) " +
                "title='\(playable.title)' catalogID=\(primaryCatalogID)"
            SonosLog.debug(
                .playbackLink,
                primaryResolveMessage)
            if let item = await searchManager.resolveLocalAppleMusicBrowseItem(
                playable,
                manager: manager
            ) {
                let itemID = SonosLog.playbackLinkValue(item.id, maxLength: 640)
                let itemURI = SonosLog.playbackLinkValue(item.uri)
                let primaryResolvedMessage = "LocalService queue resolved primary title='\(item.title)' " +
                    "itemId=\(itemID) uri=\(itemURI)"
                SonosLog.debug(
                    .playbackLink,
                    primaryResolvedMessage)
                return item
            }
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
            didAttemptResolution = true
            let fallbackCatalogID = SonosLog.playbackLinkValue(catalogPlayable.catalogID, maxLength: 640)
            let fallbackResolveMessage = "LocalService queue resolve fallback kind=\(catalogPlayable.kind.cloudType) " +
                "title='\(catalogPlayable.title)' catalogID=\(fallbackCatalogID)"
            SonosLog.debug(
                .playbackLink,
                fallbackResolveMessage)
            if let item = await searchManager.resolveLocalAppleMusicBrowseItem(
                catalogPlayable,
                manager: manager
            ) {
                let itemID = SonosLog.playbackLinkValue(item.id, maxLength: 640)
                let itemURI = SonosLog.playbackLinkValue(item.uri)
                let fallbackResolvedMessage = "LocalService queue resolved fallback title='\(item.title)' " +
                    "itemId=\(itemID) uri=\(itemURI)"
                SonosLog.debug(
                    .playbackLink,
                    fallbackResolvedMessage)
                return item
            }
        }

        if !didAttemptResolution {
            throw LocalServiceSonosPlaybackError.noPlayableCatalogID
        }
        throw LocalServiceSonosPlaybackError.playbackFailed(searchManager.errorMessage)
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

    func albums(for artist: Artist, limit: Int = 100) async throws -> [Album] {
        try await client.albums(for: artist, limit: limit)
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
            let directArtworkURLString = Self.directArtworkURLString($0.artwork)
            return LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .song,
                title: $0.title,
                artist: $0.artistName,
                album: $0.albumTitle,
                hasMusicKitArtwork: directArtworkURLString != nil,
                directArtworkURLString: directArtworkURLString)
        })
        items.append(contentsOf: snapshot.albums.map {
            let directArtworkURLString = Self.directArtworkURLString($0.artwork)
            return LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .album,
                title: $0.title,
                artist: $0.artistName,
                album: $0.title,
                hasMusicKitArtwork: directArtworkURLString != nil,
                directArtworkURLString: directArtworkURLString)
        })
        items.append(contentsOf: snapshot.artists.map {
            let directArtworkURLString = Self.directArtworkURLString($0.artwork)
            return LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .artist,
                title: $0.name,
                artist: $0.name,
                album: nil,
                hasMusicKitArtwork: directArtworkURLString != nil,
                directArtworkURLString: directArtworkURLString)
        })
        items.append(contentsOf: snapshot.playlists.map {
            let directArtworkURLString = Self.directArtworkURLString($0.artwork)
            return LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .playlist,
                catalogID: LocalMusicCatalogIDExtractor.playlistCatalogID(
                    rawID: $0.id.rawValue,
                    urlString: $0.url?.absoluteString),
                title: $0.name,
                artist: $0.curatorName,
                album: nil,
                hasMusicKitArtwork: directArtworkURLString != nil,
                directArtworkURLString: directArtworkURLString)
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
        let directArtworkURLString = Self.directArtworkURLString(album.artwork)
        return LocalMusicCatalogArtworkLookupItem(
            id: id ?? album.id.rawValue,
            kind: .album,
            title: album.title,
            artist: album.artistName,
            album: album.title,
            hasMusicKitArtwork: directArtworkURLString != nil,
            directArtworkURLString: directArtworkURLString)
    }

    private static func artworkLookupItem(for playlist: Playlist, id: String? = nil) -> LocalMusicCatalogArtworkLookupItem {
        let storageID = id ?? playlist.id.rawValue
        let urlString = playlist.url?.absoluteString
        let catalogID = LocalMusicCatalogIDExtractor.playlistCatalogID(
            rawID: storageID,
            urlString: urlString)
        let directArtworkURLString = Self.directArtworkURLString(playlist.artwork)

        return LocalMusicCatalogArtworkLookupItem(
            id: storageID,
            kind: .playlist,
            catalogID: catalogID,
            title: playlist.name,
            artist: playlist.curatorName,
            album: nil,
            hasMusicKitArtwork: directArtworkURLString != nil,
            directArtworkURLString: directArtworkURLString)
    }

    private static func artworkLookupItem(forPlaylistTrack track: Track) -> LocalMusicCatalogArtworkLookupItem {
        let directArtworkURLString = directArtworkURLString(track.artwork)
        let item = LocalMusicPlaylistTrackArtworkLookup.lookupItem(
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            directArtworkURLString: directArtworkURLString)
        return item
    }

    private static func playlistTrackArtworkStorageID(for track: Track) -> String {
        LocalMusicPlaylistTrackArtworkLookup.storageID(
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle)
    }

    private func scheduleCatalogArtworkLookup(for items: [LocalMusicCatalogArtworkLookupItem]) {
        let plan = LocalMusicCatalogArtworkPlan.make(
            items: items,
            inMemoryURLStrings: catalogArtworkURLStrings,
            inMemoryMissIDs: catalogArtworkMissIDs,
            inFlightStorageKeys: catalogArtworkInFlightIDs,
            cache: catalogArtworkCache)

        logPlaylistArtworkPlan(items: items, plan: plan)

        if !plan.immediateURLStringsByKey.isEmpty {
            var nextURLStrings = catalogArtworkURLStrings
            for (key, urlString) in plan.immediateURLStringsByKey {
                nextURLStrings[key.storageKey] = urlString
            }
            catalogArtworkURLStrings = nextURLStrings
        }

        let candidates = plan.lookupItems
        guard !candidates.isEmpty else { return }

        let batchID = UUID()
        let inFlightStorageKeys = Set(candidates.map { $0.key.storageKey })
        catalogArtworkInFlightIDs.formUnion(inFlightStorageKeys)
        artworkLookupTasks[batchID] = Task { [weak self] in
            await self?.resolveCatalogArtwork(
                for: candidates,
                batchID: batchID,
                inFlightStorageKeys: inFlightStorageKeys)
        }
    }

    private func logPlaylistArtworkPlan(
        items: [LocalMusicCatalogArtworkLookupItem],
        plan: LocalMusicCatalogArtworkPlan
    ) {
        let playlistItems = items.filter { $0.kind == .playlist }
        let playlistTrackItems = items.filter(Self.isPlaylistTrackArtworkItem)
        guard !playlistItems.isEmpty || !playlistTrackItems.isEmpty else { return }

        if !playlistItems.isEmpty {
            SonosLog.debug(
                .localService,
                "Playlist artwork plan total=\(playlistItems.count) " +
                    "immediate=\(plan.immediateURLStringsByKey.count) lookup=\(plan.lookupItems.count) " +
                    "inflight=\(playlistItems.filter { catalogArtworkInFlightIDs.contains($0.key.storageKey) }.count)")
        }

        guard !playlistTrackItems.isEmpty else { return }

        SonosLog.debug(
            .localService,
            "LSPlaylistTrackArtwork plan total=\(playlistTrackItems.count) " +
                "immediate=\(plan.immediateURLStringsByKey.count) lookup=\(plan.lookupItems.count) " +
                "inflight=\(playlistTrackItems.filter { catalogArtworkInFlightIDs.contains($0.key.storageKey) }.count)")
    }

    private func resolveCatalogArtwork(
        for items: [LocalMusicCatalogArtworkLookupItem],
        batchID: UUID,
        inFlightStorageKeys: Set<String>
    ) async {
        defer {
            completeCatalogArtworkLookup(batchID: batchID, inFlightStorageKeys: inFlightStorageKeys)
        }

        SonosLog.debug(
            .search,
            "LocalService resolving catalog artwork for \(items.count) library items " +
                "with concurrency=\(LocalMusicCatalogArtworkResolver.defaultMaxConcurrentLookups)")

        let results = await LocalMusicCatalogArtworkResolver.resolve(items: items) { item in
            await Self.catalogArtworkURLString(for: item)
        }

        guard !Task.isCancelled else { return }
        var resolvedURLStringsByKey: [LocalMusicCatalogArtworkKey: String] = [:]
        var nextURLStrings = catalogArtworkURLStrings
        var nextMissIDs = catalogArtworkMissIDs

        for result in results {
            let key = result.item.key
            if let urlString = result.urlString {
                if result.item.kind == .playlist {
                    SonosLog.debug(
                        .localService,
                        "Playlist artwork resolved title='\(result.item.title)' storageKey='\(key.storageKey)' " +
                            "url=\(Self.diagnosticURLStatus(urlString))")
                } else if Self.isPlaylistTrackArtworkItem(result.item) {
                    SonosLog.debug(
                        .localService,
                        "LSPlaylistTrackArtwork resolved title='\(result.item.title)' storageKey='\(key.storageKey)' " +
                            "url=\(Self.diagnosticURLStatus(urlString))")
                }
                nextURLStrings[key.storageKey] = urlString
                resolvedURLStringsByKey[key] = urlString
            } else {
                if result.item.kind == .playlist {
                    SonosLog.debug(
                        .localService,
                        "Playlist artwork unresolved title='\(result.item.title)' storageKey='\(key.storageKey)' " +
                            "catalogID=\(Self.diagnosticValue(result.item.catalogID))")
                } else if Self.isPlaylistTrackArtworkItem(result.item) {
                    SonosLog.debug(
                        .localService,
                        "LSPlaylistTrackArtwork unresolved title='\(result.item.title)' storageKey='\(key.storageKey)' " +
                            "artist=\(Self.diagnosticValue(result.item.artist)) album=\(Self.diagnosticValue(result.item.album))")
                }
                nextMissIDs.insert(key.storageKey)
            }
        }

        if catalogArtworkURLStrings != nextURLStrings {
            catalogArtworkURLStrings = nextURLStrings
        }
        if catalogArtworkMissIDs != nextMissIDs {
            catalogArtworkMissIDs = nextMissIDs
        }
        catalogArtworkCache.storeURLStrings(resolvedURLStringsByKey)
    }

    private func cancelCatalogArtworkLookupTasks() {
        for task in artworkLookupTasks.values {
            task.cancel()
        }
        artworkLookupTasks = [:]
        catalogArtworkInFlightIDs = []
    }

    private func completeCatalogArtworkLookup(batchID: UUID, inFlightStorageKeys: Set<String>) {
        guard artworkLookupTasks[batchID] != nil else { return }
        artworkLookupTasks[batchID] = nil
        catalogArtworkInFlightIDs.subtract(inFlightStorageKeys)
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
            } else if Self.isPlaylistTrackArtworkItem(item) {
                SonosLog.debug(
                    .localService,
                    "LSPlaylistTrackArtwork fallback search start title='\(item.title)' term='\(term)' " +
                        "artist=\(diagnosticValue(item.artist)) album=\(diagnosticValue(item.album))")
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
                        "candidateSummary=\(Self.catalogSearchSummary(items, type: .playlist)) " +
                        "match=\(Self.catalogSearchMatchSummary(match)) url=\(diagnosticURLStatus(urlString))")
            } else if Self.isPlaylistTrackArtworkItem(item) {
                SonosLog.debug(
                    .localService,
                    "LSPlaylistTrackArtwork fallback search result title='\(item.title)' term='\(term)' " +
                        "candidateSummary=\(Self.catalogSearchSummary(items, type: .song)) " +
                        "match=\(Self.catalogSearchMatchSummary(match)) url=\(diagnosticURLStatus(urlString))")
            }
            return urlString
        } catch {
            if item.kind == .playlist {
                SonosLog.debug(
                    .localService,
                    "Playlist artwork fallback search failed title='\(item.title)' term='\(term)' error=\(error)")
            } else if Self.isPlaylistTrackArtworkItem(item) {
                SonosLog.debug(
                    .localService,
                    "LSPlaylistTrackArtwork fallback search failed title='\(item.title)' term='\(term)' error=\(error)")
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

    private static func isPlaylistTrackArtworkItem(_ item: LocalMusicCatalogArtworkLookupItem) -> Bool {
        item.kind == .song && item.id.hasPrefix("playlist-track:")
    }

    private static func catalogSearchSummary(
        _ items: [AppleMusicCatalogSearchItem],
        type: AppleMusicCatalogItemType
    ) -> String {
        let matchingItems = items.filter { $0.type == type }
        guard !matchingItems.isEmpty else { return "\(type)=0 total=\(items.count)" }
        let preview = matchingItems.prefix(3).map {
            "\($0.id)|\($0.title)|\($0.artist)|art=\(diagnosticURLStatus($0.artworkURLString))"
        }.joined(separator: "; ")
        return "\(type)=\(matchingItems.count) total=\(items.count) preview=[\(preview)]"
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
