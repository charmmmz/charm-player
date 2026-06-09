import Foundation
import MusicKit

enum AppleMusicCatalogItemType: Equatable, Sendable {
    case song
    case album
    case artist
    case playlist

    var cloudType: String {
        switch self {
        case .song: return "TRACK"
        case .album: return "ALBUM"
        case .artist: return "ARTIST"
        case .playlist: return "PLAYLIST"
        }
    }

    var isContainer: Bool {
        switch self {
        case .album, .playlist: return true
        case .song, .artist: return false
        }
    }
}

struct AppleMusicCatalogSearchItem: Identifiable, Equatable, Sendable {
    let id: String
    let type: AppleMusicCatalogItemType
    let title: String
    let artist: String
    let album: String
    let artworkURLString: String?
    let duration: TimeInterval?

    var sonosPlayableObjectID: String {
        switch type {
        case .song:
            return "song:\(id)"
        case .album:
            return "album:\(id)"
        case .artist:
            return "artist:\(id)"
        case .playlist:
            return "playlist:\(id)"
        }
    }

    var sonosPlayableMimeType: String? {
        switch type {
        case .song:
            return "audio/mp4"
        case .album, .artist, .playlist:
            return nil
        }
    }

    func browseItem(localServiceId: Int?, uri: String? = nil) -> BrowseItem {
        BrowseItem(
            id: sonosPlayableObjectID,
            title: title,
            artist: artist,
            album: album,
            albumArtURL: artworkURLString,
            uri: uri,
            duration: duration ?? 0,
            isContainer: type.isContainer,
            serviceId: localServiceId,
            cloudType: type.cloudType
        )
    }
}

enum LocalMusicCatalogMatcher {
    static func bestItem(
        in items: [AppleMusicCatalogSearchItem],
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> AppleMusicCatalogSearchItem? {
        guard let targetType = AppleMusicCatalogItemType(kind: kind) else { return nil }
        let candidates = items.filter { $0.type == targetType }
        guard !candidates.isEmpty else { return nil }

        let targetTitle = normalized(title)
        let targetArtist = normalized(artist ?? "")
        let targetAlbum = normalized(album ?? "")

        let titleMatches = candidates.filter { normalized($0.title) == targetTitle }
        if let exact = titleMatches.first(where: {
            switch kind {
            case .song:
                return targetArtist.isEmpty || normalized($0.artist) == targetArtist
            case .album:
                return targetArtist.isEmpty || normalized($0.artist) == targetArtist
            case .artist:
                return true
            case .playlist:
                return targetArtist.isEmpty || normalized($0.artist) == targetArtist
            case .station:
                return false
            }
        }) {
            return exact
        }

        if kind == .song,
           let albumMatch = titleMatches.first(where: {
               !targetAlbum.isEmpty && normalized($0.album) == targetAlbum
           }) {
            return albumMatch
        }

        return titleMatches.first ?? candidates.first
    }

    static func searchTerm(
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> String {
        var parts = [title]
        switch kind {
        case .song, .album, .artist:
            parts.append(artist ?? "")
        case .playlist:
            break
        case .station:
            parts.append(artist ?? "")
        }
        if kind == .song {
            parts.append(album ?? "")
        }
        return dedupedNormalized(parts)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func dedupedNormalized(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let normalizedValue = normalized(value)
            guard !normalizedValue.isEmpty, seen.insert(normalizedValue).inserted else { continue }
            result.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
}

enum LocalMusicCatalogArtworkFallback {
    static func artworkURLString(
        in items: [AppleMusicCatalogSearchItem],
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> String? {
        guard let match = LocalMusicCatalogMatcher.bestItem(
            in: items,
            kind: kind,
            title: title,
            artist: artist,
            album: album
        ) else {
            return nil
        }

        return validURLString(match.artworkURLString)
    }

    private static func validURLString(_ value: String?) -> String? {
        guard let value,
              URL(string: value) != nil else {
            return nil
        }
        return value
    }
}

extension AppleMusicCatalogItemType {
    init?(kind: LocalServiceAppleMusicPlayable.Kind) {
        switch kind {
        case .song:
            self = .song
        case .album:
            self = .album
        case .artist:
            self = .artist
        case .playlist:
            self = .playlist
        case .station:
            return nil
        }
    }
}

enum AppleMusicCatalogSearchError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Apple Music access was not granted."
        }
    }
}

struct AppleMusicCatalogSearchClient {
    static let shared = AppleMusicCatalogSearchClient()

    func search(term: String, limit: Int = 8) async throws -> [AppleMusicCatalogSearchItem] {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            break
        case .notDetermined:
            guard await MusicAuthorization.request() == .authorized else {
                throw AppleMusicCatalogSearchError.authorizationDenied
            }
        case .denied, .restricted:
            throw AppleMusicCatalogSearchError.authorizationDenied
        @unknown default:
            throw AppleMusicCatalogSearchError.authorizationDenied
        }

        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Song.self, Album.self, Artist.self, Playlist.self]
        )
        request.limit = limit
        let response = try await request.response()

        var items: [AppleMusicCatalogSearchItem] = []
        items.append(contentsOf: response.songs.map(Self.item(from:)))
        items.append(contentsOf: response.albums.map(Self.item(from:)))
        items.append(contentsOf: response.artists.map(Self.item(from:)))
        items.append(contentsOf: response.playlists.map(Self.item(from:)))
        return items
    }

    private static func item(from song: Song) -> AppleMusicCatalogSearchItem {
        AppleMusicCatalogSearchItem(
            id: song.id.rawValue,
            type: .song,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            artworkURLString: artworkURLString(song.artwork),
            duration: song.duration
        )
    }

    private static func item(from album: Album) -> AppleMusicCatalogSearchItem {
        AppleMusicCatalogSearchItem(
            id: album.id.rawValue,
            type: .album,
            title: album.title,
            artist: album.artistName,
            album: album.title,
            artworkURLString: artworkURLString(album.artwork),
            duration: nil
        )
    }

    private static func item(from artist: Artist) -> AppleMusicCatalogSearchItem {
        AppleMusicCatalogSearchItem(
            id: artist.id.rawValue,
            type: .artist,
            title: artist.name,
            artist: "",
            album: "",
            artworkURLString: artworkURLString(artist.artwork),
            duration: nil
        )
    }

    private static func item(from playlist: Playlist) -> AppleMusicCatalogSearchItem {
        AppleMusicCatalogSearchItem(
            id: playlist.id.rawValue,
            type: .playlist,
            title: playlist.name,
            artist: playlist.curatorName ?? "",
            album: "",
            artworkURLString: artworkURLString(playlist.artwork),
            duration: nil
        )
    }

    private static func artworkURLString(_ artwork: Artwork?) -> String? {
        artwork?.url(width: 400, height: 400)?.absoluteString
    }
}
