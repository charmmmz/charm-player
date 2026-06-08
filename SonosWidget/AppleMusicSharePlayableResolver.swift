import Foundation
import MusicKit

enum AppleMusicSharePlaybackError: LocalizedError, Equatable {
    case invalidAppleMusicLink
    case authorizationDenied
    case catalogItemNotFound
    case noPlayableCatalogID
    case playbackFailed(String?)

    var errorDescription: String? {
        switch self {
        case .invalidAppleMusicLink:
            return "This is not a supported Apple Music link."
        case .authorizationDenied:
            return "Apple Music access was not granted."
        case .catalogItemNotFound:
            return "This Apple Music item could not be found."
        case .noPlayableCatalogID:
            return "This Apple Music item could not be matched to a Sonos-playable resource."
        case .playbackFailed(let message):
            return message ?? "Sonos could not start this Apple Music item."
        }
    }
}

struct AppleMusicSharePlayableResolver {
    static let shared = AppleMusicSharePlayableResolver()

    func resolve(_ share: PendingAppleMusicShare) async throws -> LocalServiceAppleMusicPlayable {
        try await resolve(urlString: share.urlString)
    }

    func resolve(urlString: String) async throws -> LocalServiceAppleMusicPlayable {
        guard let link = AppleMusicShareLinkParser.parse(urlString) else {
            throw AppleMusicSharePlaybackError.invalidAppleMusicLink
        }

        try await ensureAuthorized()

        switch link.kind {
        case .song:
            return try await resolveSong(id: link.catalogID)
        case .album:
            return try await resolveAlbum(id: link.catalogID)
        case .playlist:
            return try await resolvePlaylist(id: link.catalogID)
        case .artist:
            return try await resolveArtist(id: link.catalogID)
        }
    }

    private func ensureAuthorized() async throws {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return
        case .notDetermined:
            guard await MusicAuthorization.request() == .authorized else {
                throw AppleMusicSharePlaybackError.authorizationDenied
            }
        case .denied, .restricted:
            throw AppleMusicSharePlaybackError.authorizationDenied
        @unknown default:
            throw AppleMusicSharePlaybackError.authorizationDenied
        }
    }

    private func resolveSong(id: String) async throws -> LocalServiceAppleMusicPlayable {
        var request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: MusicItemID(id)
        )
        request.limit = 1
        let response = try await request.response()
        guard let song = response.items.first else {
            throw AppleMusicSharePlaybackError.catalogItemNotFound
        }
        guard let playable = LocalServiceAppleMusicPlayable.make(song: song) else {
            throw AppleMusicSharePlaybackError.noPlayableCatalogID
        }
        return playable
    }

    private func resolveAlbum(id: String) async throws -> LocalServiceAppleMusicPlayable {
        var request = MusicCatalogResourceRequest<Album>(
            matching: \.id,
            equalTo: MusicItemID(id)
        )
        request.limit = 1
        let response = try await request.response()
        guard let album = response.items.first else {
            throw AppleMusicSharePlaybackError.catalogItemNotFound
        }
        guard let playable = LocalServiceAppleMusicPlayable.make(album: album) else {
            throw AppleMusicSharePlaybackError.noPlayableCatalogID
        }
        return playable
    }

    private func resolvePlaylist(id: String) async throws -> LocalServiceAppleMusicPlayable {
        var request = MusicCatalogResourceRequest<Playlist>(
            matching: \.id,
            equalTo: MusicItemID(id)
        )
        request.limit = 1
        let response = try await request.response()
        guard let playlist = response.items.first else {
            throw AppleMusicSharePlaybackError.catalogItemNotFound
        }
        guard let playable = LocalServiceAppleMusicPlayable.make(playlist: playlist) else {
            throw AppleMusicSharePlaybackError.noPlayableCatalogID
        }
        return playable
    }

    private func resolveArtist(id: String) async throws -> LocalServiceAppleMusicPlayable {
        var request = MusicCatalogResourceRequest<Artist>(
            matching: \.id,
            equalTo: MusicItemID(id)
        )
        request.limit = 1
        let response = try await request.response()
        guard let artist = response.items.first else {
            throw AppleMusicSharePlaybackError.catalogItemNotFound
        }
        guard let playable = LocalServiceAppleMusicPlayable.make(artist: artist) else {
            throw AppleMusicSharePlaybackError.noPlayableCatalogID
        }
        return playable
    }
}
