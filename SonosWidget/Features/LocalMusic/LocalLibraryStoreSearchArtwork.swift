import Foundation
import MusicKit
import Observation

extension LocalLibraryStore {

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
                searchSnapshotRevision += 1
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

}
