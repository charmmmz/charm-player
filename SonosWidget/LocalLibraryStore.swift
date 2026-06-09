import Foundation
import MusicKit
import Observation

@MainActor
@Observable
final class LocalLibraryStore {
    private let client: LocalMusicLibraryClient

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

    init(client: LocalMusicLibraryClient) {
        self.client = client
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
            scheduleCatalogArtworkLookup(for: content.snapshot)
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

    private func scheduleCatalogArtworkLookup(for snapshot: LocalMusicLibrarySnapshot) {
        var items: [LocalMusicCatalogArtworkLookupItem] = []
        items.append(contentsOf: snapshot.songs.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .song,
                title: $0.title,
                artist: $0.artistName,
                album: $0.albumTitle)
        })
        items.append(contentsOf: snapshot.albums.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .album,
                title: $0.title,
                artist: $0.artistName,
                album: $0.title)
        })
        items.append(contentsOf: snapshot.artists.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .artist,
                title: $0.name,
                artist: $0.name,
                album: nil)
        })
        items.append(contentsOf: snapshot.playlists.map {
            LocalMusicCatalogArtworkLookupItem(
                id: $0.id.rawValue,
                kind: .playlist,
                title: $0.name,
                artist: $0.curatorName,
                album: nil)
        })

        scheduleCatalogArtworkLookup(for: items)
    }

    private func scheduleCatalogArtworkLookup(for items: [LocalMusicCatalogArtworkLookupItem]) {
        let candidates = items.filter { item in
            let key = Self.catalogArtworkKey(kind: item.kind, id: item.id)
            return catalogArtworkURLStrings[key] == nil
                && !catalogArtworkMissIDs.contains(key)
        }
        guard !candidates.isEmpty else { return }

        artworkLookupTask?.cancel()
        artworkLookupTask = Task { [weak self] in
            await self?.resolveCatalogArtwork(for: candidates)
        }
    }

    private func resolveCatalogArtwork(for items: [LocalMusicCatalogArtworkLookupItem]) async {
        SonosLog.debug(.search, "LocalService resolving catalog artwork for \(items.count) library items")

        for item in items {
            guard !Task.isCancelled else { return }
            let key = Self.catalogArtworkKey(kind: item.kind, id: item.id)
            if let urlString = await catalogArtworkURLString(for: item) {
                catalogArtworkURLStrings[key] = urlString
            } else {
                catalogArtworkMissIDs.insert(key)
            }
        }
    }

    private func catalogArtworkURLString(for item: LocalMusicCatalogArtworkLookupItem) async -> String? {
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
        "\(kind):\(id)"
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

private struct LocalMusicCatalogArtworkLookupItem {
    let id: String
    let kind: LocalServiceAppleMusicPlayable.Kind
    let title: String
    let artist: String?
    let album: String?
}
