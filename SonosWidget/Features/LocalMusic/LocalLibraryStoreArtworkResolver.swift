import Foundation
import MusicKit
import Observation

extension LocalLibraryStore {

    func songs(for artist: Artist, limit: Int = 100) async throws -> [Song] {
        try await client.songs(for: artist, limit: limit)
    }

    func albums(for artist: Artist, limit: Int = 100) async throws -> [Album] {
        try await client.albums(for: artist, limit: limit)
    }

    func catalogArtworkURL(kind: LocalServiceAppleMusicPlayable.Kind, id: String) -> URL? {
        catalogArtworkURLStrings[Self.catalogArtworkKey(kind: kind, id: id)]
            .flatMap(URL.init(string:))
    }

    func scheduleCatalogArtworkLookup(
        for content: LocalMusicHomeContent,
        recentlyAddedContent: LocalMusicRecentlyAddedContent
    ) {
        var items = Self.artworkLookupItems(for: recentlyAddedContent)
        items.append(contentsOf: content.recentlyPlayed.compactMap(Self.artworkLookupItem(for:)))
        for recommendation in content.recommendations {
            items.append(contentsOf: recommendation.items.compactMap(Self.artworkLookupItem(for:)))
            items.append(contentsOf: recommendation.albums.map { Self.artworkLookupItem(for: $0) })
            items.append(contentsOf: recommendation.playlists.map { Self.artworkLookupItem(for: $0) })
        }
        scheduleCatalogArtworkLookup(for: items)
    }

    func scheduleCatalogArtworkLookup(for snapshot: LocalMusicLibrarySnapshot) {
        scheduleCatalogArtworkLookup(for: Self.artworkLookupItems(for: snapshot))
    }

    static func artworkLookupItems(for snapshot: LocalMusicLibrarySnapshot) -> [LocalMusicCatalogArtworkLookupItem] {
        var items: [LocalMusicCatalogArtworkLookupItem] = []
        items.append(contentsOf: snapshot.songs.map(Self.artworkLookupItem(for:)))
        items.append(contentsOf: snapshot.albums.map { Self.artworkLookupItem(for: $0) })
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
        items.append(contentsOf: snapshot.playlists.map { Self.artworkLookupItem(for: $0) })
        return items
    }

    static func artworkLookupItems(
        for recentlyAddedContent: LocalMusicRecentlyAddedContent
    ) -> [LocalMusicCatalogArtworkLookupItem] {
        recentlyAddedContent.items.map(Self.artworkLookupItem(for:))
    }

    static func artworkLookupItem(
        for item: LocalMusicRecentlyAddedItem
    ) -> LocalMusicCatalogArtworkLookupItem {
        switch item {
        case .album(let album):
            return artworkLookupItem(for: album)
        case .playlist(let playlist):
            return artworkLookupItem(for: playlist)
        case .song(let song):
            return artworkLookupItem(for: song)
        }
    }

    static func artworkLookupItem(for song: Song) -> LocalMusicCatalogArtworkLookupItem {
        let directArtworkURLString = Self.directArtworkURLString(song.artwork)
        return LocalMusicCatalogArtworkLookupItem(
            id: song.id.rawValue,
            kind: .song,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            hasMusicKitArtwork: directArtworkURLString != nil,
            directArtworkURLString: directArtworkURLString)
    }

    static func artworkLookupItem(for item: RecentlyPlayedMusicItem) -> LocalMusicCatalogArtworkLookupItem? {
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

    static func artworkLookupItem(
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

    static func artworkLookupItem(for album: Album, id: String? = nil) -> LocalMusicCatalogArtworkLookupItem {
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

    static func artworkLookupItem(for playlist: Playlist, id: String? = nil) -> LocalMusicCatalogArtworkLookupItem {
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

    static func artworkLookupItem(
        for playable: LocalServiceAppleMusicPlayable
    ) -> LocalMusicCatalogArtworkLookupItem {
        LocalMusicCatalogArtworkLookupItem(
            id: playable.catalogID,
            kind: playable.kind,
            catalogID: catalogArtworkCatalogID(for: playable),
            title: playable.title,
            artist: playable.artist.isEmpty ? nil : playable.artist,
            album: playable.album.isEmpty ? nil : playable.album,
            directArtworkURLString: playable.artworkURLString)
    }

    static func catalogArtworkCatalogID(
        for playable: LocalServiceAppleMusicPlayable
    ) -> String? {
        let decoded = playable.catalogID.removingPercentEncoding ?? playable.catalogID
        let suffix = decoded
            .split(separator: ":", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? decoded
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch playable.kind {
        case .song:
            return SonosAppleMusicTrackResolver.storeID(fromObjectID: decoded)
        case .album:
            return trimmed.hasPrefix("l.") ? nil : trimmed
        case .artist:
            return trimmed.hasPrefix("r.") ? nil : trimmed
        case .playlist:
            return trimmed.hasPrefix("pl.") ? trimmed : nil
        case .station:
            return nil
        }
    }

    static func artworkLookupItem(forPlaylistTrack track: Track) -> LocalMusicCatalogArtworkLookupItem {
        let directArtworkURLString = directArtworkURLString(track.artwork)
        let item = LocalMusicPlaylistTrackArtworkLookup.lookupItem(
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            directArtworkURLString: directArtworkURLString)
        return item
    }

    static func playlistTrackArtworkStorageID(for track: Track) -> String {
        LocalMusicPlaylistTrackArtworkLookup.storageID(
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle)
    }

    func scheduleCatalogArtworkLookup(for items: [LocalMusicCatalogArtworkLookupItem]) {
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

    func logPlaylistArtworkPlan(
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

    func resolveCatalogArtwork(
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

    func cancelCatalogArtworkLookupTasks() {
        for task in artworkLookupTasks.values {
            task.cancel()
        }
        artworkLookupTasks = [:]
        catalogArtworkInFlightIDs = []
    }

    func completeCatalogArtworkLookup(batchID: UUID, inFlightStorageKeys: Set<String>) {
        guard artworkLookupTasks[batchID] != nil else { return }
        artworkLookupTasks[batchID] = nil
        catalogArtworkInFlightIDs.subtract(inFlightStorageKeys)
    }

    static func catalogArtworkURLString(for item: LocalMusicCatalogArtworkLookupItem) async -> String? {
        if let catalogID = item.catalogID {
            SonosLog.debug(
                .localService,
                "LocalService catalog artwork direct lookup start kind=\(item.kind.cloudType) " +
                    "title='\(item.title)' catalogID='\(catalogID)'")

            do {
                if let urlString = try await AppleMusicCatalogSearchClient.shared.artworkURLString(
                    kind: item.kind,
                    catalogID: catalogID
                ) {
                    SonosLog.debug(
                        .localService,
                        "LocalService catalog artwork direct lookup success kind=\(item.kind.cloudType) " +
                            "title='\(item.title)' catalogID='\(catalogID)' " +
                            "url=\(diagnosticURLStatus(urlString))")
                    return urlString
                }
                SonosLog.debug(
                    .localService,
                    "LocalService catalog artwork direct lookup empty kind=\(item.kind.cloudType) " +
                        "title='\(item.title)' catalogID='\(catalogID)'")
            } catch {
                SonosLog.debug(
                    .localService,
                    "LocalService catalog artwork direct lookup failed kind=\(item.kind.cloudType) " +
                        "title='\(item.title)' catalogID='\(catalogID)' error=\(error)")
            }
        } else if item.kind == .playlist {
            SonosLog.debug(
                .localService,
                "Playlist artwork direct catalog lookup skipped title='\(item.title)' reason=no-catalog-id")
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

    static func catalogArtworkKey(kind: LocalServiceAppleMusicPlayable.Kind, id: String) -> String {
        LocalMusicCatalogArtworkKey(kind: kind, id: id).storageKey
    }

    static func directArtworkURLString(_ artwork: Artwork?) -> String? {
        guard let artwork else { return nil }
        return LocalMusicArtworkURL.url(
            for: artwork,
            shortSidePixels: LocalMusicArtworkURL.catalogDisplayShortSidePixels
        )?.absoluteString
    }

    static func diagnosticValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        return "'\(value)'"
    }

    static func diagnosticURLStatus(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        let status = LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(value) ? "loadable" : "not-loadable"
        return "\(status)('\(value)')"
    }

    static func isPlaylistTrackArtworkItem(_ item: LocalMusicCatalogArtworkLookupItem) -> Bool {
        item.kind == .song && item.id.hasPrefix("playlist-track:")
    }

    static func catalogSearchSummary(
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

    static func catalogSearchMatchSummary(_ item: AppleMusicCatalogSearchItem?) -> String {
        guard let item else { return "nil" }
        return "'\(item.id)|\(item.title)|\(item.artist)'"
    }

}
