import Foundation
import MusicKit
import Observation

extension LocalLibraryStore {

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
            case .favorite(_, _, _):
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
                case .playNow, .startStation, .favorite(_, _, _):
                    didQueue = false
                }

                guard didQueue else {
                    throw LocalServiceSonosPlaybackError.playbackFailed(
                        searchManager.errorMessage ?? manager.errorMessage)
                }
            }
        }
    }

    func toggleSonosFavorite(
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
            let didUpdate: Bool
            if searchManager.isFavorited(item) {
                didUpdate = await searchManager.removeFromFavorites(item: item, manager: manager)
            } else {
                didUpdate = await searchManager.addToFavorites(item: item, manager: manager)
            }

            guard didUpdate else {
                throw LocalServiceSonosPlaybackError.playbackFailed(
                    searchManager.errorMessage ?? manager.errorMessage)
            }
        }
    }

    func addSonosFavorite(
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
            await searchManager.ensureBrowseContentLoaded(manager: manager)
            if searchManager.isFavorited(item) {
                return
            }

            let didUpdate = await searchManager.addToFavorites(item: item, manager: manager)
            guard didUpdate else {
                throw LocalServiceSonosPlaybackError.playbackFailed(
                    searchManager.errorMessage ?? manager.errorMessage)
            }
        }
    }

    func startOnSonos(
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
            let playbackPlayable = await playablePreferringCatalogArtwork(playable)
            let didStart = await searchManager.playLocalAppleMusic(playbackPlayable, manager: manager)
            if didStart { return }
        }

        let shouldAttemptCatalogFallback = LocalServicePlaybackFallbackPolicy.shouldAttemptCatalogFallback(
            primaryKind: playable?.kind,
            fallbackKind: fallbackKind)
        if !shouldAttemptCatalogFallback, let fallbackKind, let fallbackTitle {
            SonosLog.info(
                .playback,
                "LocalService catalog fallback skipped primaryKind=\(playable?.kind.cloudType ?? "nil") " +
                    "fallbackKind=\(fallbackKind.cloudType) title='\(fallbackTitle)' reason=primary-playlist")
        }

        if shouldAttemptCatalogFallback,
           let fallbackKind,
           let fallbackTitle,
           let catalogPlayable = await catalogFallbackPlayable(
            kind: fallbackKind,
            title: fallbackTitle,
            artist: fallbackArtist,
            album: fallbackAlbum
           ),
           catalogPlayable.id != playable?.id {
            didAttemptPlayback = true
            let playbackPlayable = await playablePreferringCatalogArtwork(catalogPlayable)
            let didStart = await searchManager.playLocalAppleMusic(playbackPlayable, manager: manager)
            if didStart { return }
        }

        if !didAttemptPlayback {
            throw LocalServiceSonosPlaybackError.noPlayableCatalogID
        }
        throw LocalServiceSonosPlaybackError.playbackFailed(searchManager.errorMessage)
    }

    func playablePreferringCatalogArtwork(
        _ playable: LocalServiceAppleMusicPlayable
    ) async -> LocalServiceAppleMusicPlayable {
        guard playable.kind != .station else { return playable }
        guard LocalServicePlaybackArtworkPolicy.shouldPreferCatalogArtwork(
            kind: playable.kind,
            existingArtworkURLString: playable.artworkURLString
        ) else {
            SonosLog.debug(
                .localService,
                "LocalService playback artwork keeping existing kind=\(playable.kind.cloudType) " +
                    "title='\(playable.title)' direct=\(Self.diagnosticURLStatus(playable.artworkURLString))")
            return playable
        }

        let lookupItem = Self.artworkLookupItem(for: playable)
        let key = lookupItem.key
        let storageKey = key.storageKey
        let directStatus = Self.diagnosticURLStatus(playable.artworkURLString)

        if let cachedURLString = catalogArtworkURLStrings[storageKey] ?? catalogArtworkCache.urlString(for: key) {
            SonosLog.debug(
                .localService,
                "LocalService playback artwork using cached catalog kind=\(playable.kind.cloudType) " +
                    "title='\(playable.title)' storageKey='\(storageKey)' direct=\(directStatus) " +
                    "catalog=\(Self.diagnosticURLStatus(cachedURLString))")
            return playable.withPreferredArtworkURLString(cachedURLString)
        }

        SonosLog.debug(
            .localService,
            "LocalService playback artwork catalog lookup start kind=\(playable.kind.cloudType) " +
                "title='\(playable.title)' storageKey='\(storageKey)' " +
                "catalogID=\(Self.diagnosticValue(lookupItem.catalogID)) direct=\(directStatus)")

        guard let catalogURLString = await Self.catalogArtworkURLString(for: lookupItem) else {
            SonosLog.debug(
                .localService,
                "LocalService playback artwork catalog lookup empty kind=\(playable.kind.cloudType) " +
                    "title='\(playable.title)' storageKey='\(storageKey)' fallback=library " +
                    "direct=\(directStatus)")
            return playable
        }

        catalogArtworkURLStrings[storageKey] = catalogURLString
        catalogArtworkCache.storeURLString(catalogURLString, for: key)
        SonosLog.debug(
            .localService,
            "LocalService playback artwork catalog lookup applied kind=\(playable.kind.cloudType) " +
                "title='\(playable.title)' storageKey='\(storageKey)' direct=\(directStatus) " +
                "catalog=\(Self.diagnosticURLStatus(catalogURLString))")
        return playable.withPreferredArtworkURLString(catalogURLString)
    }

    func resolveQueueBrowseItems(
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

    func resolveQueueBrowseItem(
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
            let playbackPlayable = await playablePreferringCatalogArtwork(playable)
            let primaryCatalogID = SonosLog.playbackLinkValue(playbackPlayable.catalogID, maxLength: 640)
            let primaryResolveMessage = "LocalService queue resolve primary kind=\(playbackPlayable.kind.cloudType) " +
                "title='\(playbackPlayable.title)' catalogID=\(primaryCatalogID)"
            SonosLog.debug(
                .playbackLink,
                primaryResolveMessage)
            if let item = await searchManager.resolveLocalAppleMusicBrowseItem(
                playbackPlayable,
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

        let shouldAttemptCatalogFallback = LocalServicePlaybackFallbackPolicy.shouldAttemptCatalogFallback(
            primaryKind: playable?.kind,
            fallbackKind: fallbackKind)
        if !shouldAttemptCatalogFallback, let fallbackKind, let fallbackTitle {
            SonosLog.info(
                .playbackLink,
                "LocalService queue catalog fallback skipped primaryKind=\(playable?.kind.cloudType ?? "nil") " +
                    "fallbackKind=\(fallbackKind.cloudType) title='\(fallbackTitle)' reason=primary-playlist")
        }

        if shouldAttemptCatalogFallback,
           let fallbackKind,
           let fallbackTitle,
           let catalogPlayable = await catalogFallbackPlayable(
            kind: fallbackKind,
            title: fallbackTitle,
            artist: fallbackArtist,
            album: fallbackAlbum
           ),
           catalogPlayable.id != playable?.id {
            didAttemptResolution = true
            let playbackPlayable = await playablePreferringCatalogArtwork(catalogPlayable)
            let fallbackCatalogID = SonosLog.playbackLinkValue(playbackPlayable.catalogID, maxLength: 640)
            let fallbackResolveMessage = "LocalService queue resolve fallback kind=\(playbackPlayable.kind.cloudType) " +
                "title='\(playbackPlayable.title)' catalogID=\(fallbackCatalogID)"
            SonosLog.debug(
                .playbackLink,
                fallbackResolveMessage)
            if let item = await searchManager.resolveLocalAppleMusicBrowseItem(
                playbackPlayable,
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

    func catalogFallbackPlayable(
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

}
