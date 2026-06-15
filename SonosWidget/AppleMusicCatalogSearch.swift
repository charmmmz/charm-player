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

enum AppleMusicExternalResourceKind: Equatable, Sendable {
    case song
    case album
    case artist
    case playlist

    init(_ favoriteResourceType: AppleMusicFavoriteResourceType) {
        switch favoriteResourceType {
        case .songs:
            self = .song
        case .albums:
            self = .album
        case .artists:
            self = .artist
        case .playlists:
            self = .playlist
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
    let urlString: String?

    init(
        id: String,
        type: AppleMusicCatalogItemType,
        title: String,
        artist: String,
        album: String,
        artworkURLString: String?,
        duration: TimeInterval?,
        urlString: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURLString = artworkURLString
        self.duration = duration
        self.urlString = urlString
    }

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

enum LocalMusicCatalogIDExtractor {
    static func playlistCatalogID(rawID: String, urlString: String?) -> String? {
        if let urlString,
           let link = AppleMusicShareLinkParser.parse(urlString),
           link.kind == .playlist {
            return link.catalogID
        }

        if let link = AppleMusicShareLinkParser.parse(rawID),
           link.kind == .playlist {
            return link.catalogID
        }

        return rawPlaylistCatalogID(rawID)
    }

    private static func rawPlaylistCatalogID(_ value: String) -> String? {
        let decoded = value.removingPercentEncoding ?? value
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed
            .split(separator: ":", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? trimmed

        return suffix.hasPrefix("pl.") ? suffix : nil
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
              LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(value) else {
            return nil
        }
        return value
    }
}

enum LocalMusicCatalogWebURLFallback {
    static func urlString(
        in items: [AppleMusicCatalogSearchItem],
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?,
        allowGeneratedFallback: Bool = true
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

        if let urlString = validAppleMusicURLString(match.urlString, kind: kind) {
            return urlString
        }

        guard allowGeneratedFallback else { return nil }

        guard let webKind = LocalMusicAppleMusicURL.Kind(kind),
              let playable = LocalServiceAppleMusicPlayable.make(catalogItem: match) else {
            return nil
        }

        return LocalMusicAppleMusicURL.url(
            existingURL: nil,
            playable: playable,
            kind: webKind
        )?.absoluteString
    }

    private static func validAppleMusicURLString(
        _ value: String?,
        kind: LocalServiceAppleMusicPlayable.Kind
    ) -> String? {
        guard let value,
              let link = AppleMusicShareLinkParser.parse(value),
              link.kind == AppleMusicShareLink.Kind(kind) else {
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

private extension AppleMusicShareLink.Kind {
    init?(_ kind: LocalServiceAppleMusicPlayable.Kind) {
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
    static let maximumSearchLimit = 25

    func search(term: String, limit: Int = 8) async throws -> [AppleMusicCatalogSearchItem] {
        try await ensureAuthorized()

        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Song.self, Album.self, Artist.self, Playlist.self]
        )
        request.limit = Self.effectiveSearchLimit(requested: limit)
        let response = try await request.response()

        var items: [AppleMusicCatalogSearchItem] = []
        items.append(contentsOf: response.songs.map(Self.item(from:)))
        items.append(contentsOf: response.albums.map(Self.item(from:)))
        items.append(contentsOf: response.artists.map(Self.item(from:)))
        items.append(contentsOf: response.playlists.map(Self.item(from:)))
        return items
    }

    static func effectiveSearchLimit(requested limit: Int) -> Int {
        min(max(limit, 1), maximumSearchLimit)
    }

    func album(catalogID: String) async throws -> Album {
        try await ensureAuthorized()

        var request = MusicCatalogResourceRequest<Album>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        request.limit = 1
        let response = try await request.response()
        guard let album = response.items.first else {
            throw LocalMusicLibraryError.catalogMatchMissing
        }
        return try await album.with(.tracks)
    }

    func artist(catalogID: String) async throws -> Artist {
        try await ensureAuthorized()

        var request = MusicCatalogResourceRequest<Artist>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        request.limit = 1
        let response = try await request.response()
        guard let artist = response.items.first else {
            throw LocalMusicLibraryError.catalogMatchMissing
        }
        return try await artist.with(.fullAlbums, .singles, .latestRelease, .topSongs)
    }

    func playlist(catalogID: String) async throws -> Playlist {
        try await ensureAuthorized()

        var request = MusicCatalogResourceRequest<Playlist>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        request.limit = 1
        let response = try await request.response()
        guard let playlist = response.items.first else {
            throw LocalMusicLibraryError.catalogMatchMissing
        }
        return try await playlist.with(.tracks)
    }

    func playlistArtworkURLString(catalogID: String) async throws -> String? {
        try await ensureAuthorized()

        var request = MusicCatalogResourceRequest<Playlist>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        request.limit = 1
        let response = try await request.response()
        return response.items.first.flatMap { Self.artworkURLString($0.artwork) }
    }

    func appleMusicURLString(
        kind: LocalMusicAppleMusicURL.Kind,
        catalogID: String
    ) async throws -> String? {
        try await ensureAuthorized()

        switch kind {
        case .album:
            var request = MusicCatalogResourceRequest<Album>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first?.url?.absoluteString
        case .artist:
            var request = MusicCatalogResourceRequest<Artist>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first?.url?.absoluteString
        case .playlist:
            var request = MusicCatalogResourceRequest<Playlist>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first?.url?.absoluteString
        }
    }

    func appleMusicURLString(
        kind: AppleMusicExternalResourceKind,
        catalogID: String
    ) async throws -> String? {
        try await ensureAuthorized()

        switch kind {
        case .song:
            var request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first?.url?.absoluteString
        case .album:
            return try await appleMusicURLString(kind: LocalMusicAppleMusicURL.Kind.album, catalogID: catalogID)
        case .artist:
            return try await appleMusicURLString(kind: LocalMusicAppleMusicURL.Kind.artist, catalogID: catalogID)
        case .playlist:
            return try await appleMusicURLString(kind: LocalMusicAppleMusicURL.Kind.playlist, catalogID: catalogID)
        }
    }

    private func ensureAuthorized() async throws {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return
        case .notDetermined:
            guard await MusicAuthorization.request() == .authorized else {
                throw AppleMusicCatalogSearchError.authorizationDenied
            }
        case .denied, .restricted:
            throw AppleMusicCatalogSearchError.authorizationDenied
        @unknown default:
            throw AppleMusicCatalogSearchError.authorizationDenied
        }
    }

    private static func item(from song: Song) -> AppleMusicCatalogSearchItem {
        AppleMusicCatalogSearchItem(
            id: song.id.rawValue,
            type: .song,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            artworkURLString: artworkURLString(song.artwork),
            duration: song.duration,
            urlString: song.url?.absoluteString
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
            duration: nil,
            urlString: album.url?.absoluteString
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
            duration: nil,
            urlString: artist.url?.absoluteString
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
            duration: nil,
            urlString: playlist.url?.absoluteString
        )
    }

    private static func artworkURLString(_ artwork: Artwork?) -> String? {
        validArtworkURLString(artwork?.url(width: 400, height: 400)?.absoluteString)
    }

    private static func validArtworkURLString(_ value: String?) -> String? {
        guard let value,
              LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(value) else {
            return nil
        }
        return value
    }
}
