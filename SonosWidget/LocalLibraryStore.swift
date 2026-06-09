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
            scheduleCatalogArtworkLookup(for: content.snapshot.songs)
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
            scheduleCatalogArtworkLookup(for: snapshot.songs)
        } catch {
            guard !Task.isCancelled else { return }
            searchSnapshot = nil
            authorizationStatus = MusicAuthorization.currentStatus
            errorMessage = displayMessage(for: error)
        }

        isSearching = false
    }

    func catalogArtworkURL(for song: Song) -> URL? {
        catalogArtworkURLStrings[song.id.rawValue].flatMap(URL.init(string:))
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

    private func scheduleCatalogArtworkLookup(for songs: [Song]) {
        let candidates = songs.filter { song in
            catalogArtworkURLStrings[song.id.rawValue] == nil
                && !catalogArtworkMissIDs.contains(song.id.rawValue)
        }
        guard !candidates.isEmpty else { return }

        artworkLookupTask?.cancel()
        artworkLookupTask = Task { [weak self] in
            await self?.resolveCatalogArtwork(for: candidates)
        }
    }

    private func resolveCatalogArtwork(for songs: [Song]) async {
        SonosLog.debug(.search, "LocalService resolving catalog artwork for \(songs.count) library songs")

        for song in songs {
            guard !Task.isCancelled else { return }
            if let urlString = await catalogArtworkURLString(for: song) {
                catalogArtworkURLStrings[song.id.rawValue] = urlString
            } else {
                catalogArtworkMissIDs.insert(song.id.rawValue)
            }
        }
    }

    private func catalogArtworkURLString(for song: Song) async -> String? {
        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: .song,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle)
        guard !term.isEmpty else { return nil }

        do {
            let items = try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: 8)
            return LocalMusicCatalogArtworkFallback.artworkURLString(
                in: items,
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle)
        } catch {
            SonosLog.debug(.search, "LocalService catalog artwork fallback failed for '\(term)': \(error)")
            return nil
        }
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
