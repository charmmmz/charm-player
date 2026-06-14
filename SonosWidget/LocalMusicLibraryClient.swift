import Foundation
import MusicKit

struct LocalMusicLibrarySnapshot {
    var songs: [Song] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []

    var summary: LocalLibrarySnapshotSummary {
        LocalLibrarySnapshotSummary(
            songCount: songs.count,
            albumCount: albums.count,
            artistCount: artists.count,
            playlistCount: playlists.count
        )
    }

    var isEmpty: Bool {
        summary.isEmpty
    }
}

struct LocalMusicHomeContent {
    var snapshot = LocalMusicLibrarySnapshot()
    var recentlyPlayed: [RecentlyPlayedMusicItem] = []
    var recommendations: [MusicPersonalRecommendation] = []

    var isEmpty: Bool {
        snapshot.isEmpty && recentlyPlayed.isEmpty && recommendations.isEmpty
    }
}

enum LocalMusicLibraryError: LocalizedError, Equatable {
    case authorizationDenied
    case emptyPlaybackQueue
    case artistHasNoSongs
    case catalogMatchMissing

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Apple Music access was not granted."
        case .emptyPlaybackQueue:
            return "Nothing could be queued for playback."
        case .artistHasNoSongs:
            return "No playable songs were found for this artist."
        case .catalogMatchMissing:
            return "This Apple Music library item could not be matched in the catalog."
        }
    }
}

@MainActor
struct LocalMusicLibraryClient {
    static let shared = LocalMusicLibraryClient()

    func authorize() async throws -> MusicAuthorization.Status {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return .authorized
        case .notDetermined:
            let status = await MusicAuthorization.request()
            guard status == .authorized else {
                throw LocalMusicLibraryError.authorizationDenied
            }
            return status
        case .denied, .restricted:
            throw LocalMusicLibraryError.authorizationDenied
        @unknown default:
            throw LocalMusicLibraryError.authorizationDenied
        }
    }

    func loadSnapshot(limit: Int? = nil) async throws -> LocalMusicLibrarySnapshot {
        _ = try await authorize()

        async let songs = librarySongs(limit: limit)
        async let albums = libraryAlbums(limit: limit)
        async let artists = libraryArtists(limit: limit)
        async let playlists = libraryPlaylists(limit: limit)

        return try await LocalMusicLibrarySnapshot(
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists
        )
    }

    func loadHomeContent(
        snapshotLimit: Int? = nil,
        recentlyPlayedLimit: Int = 12,
        recommendationLimit: Int = 6
    ) async throws -> LocalMusicHomeContent {
        _ = try await authorize()

        async let snapshot = librarySnapshot(limit: snapshotLimit)
        async let recentlyPlayed = optionalRecentlyPlayed(limit: recentlyPlayedLimit)
        async let recommendations = optionalPersonalRecommendations(limit: recommendationLimit)

        return try await LocalMusicHomeContent(
            snapshot: snapshot,
            recentlyPlayed: recentlyPlayed,
            recommendations: recommendations
        )
    }

    func search(term: String, limit: Int = 40) async throws -> LocalMusicLibrarySnapshot {
        _ = try await authorize()

        var request = MusicLibrarySearchRequest(
            term: term,
            types: [Song.self, Album.self, Artist.self, Playlist.self]
        )
        request.limit = limit
        let response = try await request.response()
        return LocalMusicLibrarySnapshot(
            songs: Array(response.songs),
            albums: Array(response.albums),
            artists: Array(response.artists),
            playlists: Array(response.playlists)
        )
    }

    func play(song: Song) async throws {
        try await play([song], startingAt: song)
    }

    func play(track: Track) async throws {
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [track], startingAt: track)
        try await player.prepareToPlay()
        try await player.play()
    }

    func play(album: Album) async throws {
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [album])
        try await player.prepareToPlay()
        try await player.play()
    }

    func play(playlist: Playlist) async throws {
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [playlist])
        try await player.prepareToPlay()
        try await player.play()
    }

    func play(station: Station) async throws {
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [station])
        try await player.prepareToPlay()
        try await player.play()
    }

    func play(recentlyPlayed item: RecentlyPlayedMusicItem) async throws {
        switch item {
        case .album(let album):
            try await play(album: album)
        case .playlist(let playlist):
            try await play(playlist: playlist)
        case .station(let station):
            try await play(station: station)
        @unknown default:
            throw LocalMusicLibraryError.emptyPlaybackQueue
        }
    }

    func play(recommendation item: MusicPersonalRecommendation.Item) async throws {
        switch item {
        case .album(let album):
            try await play(album: album)
        case .playlist(let playlist):
            try await play(playlist: playlist)
        case .station(let station):
            try await play(station: station)
        @unknown default:
            throw LocalMusicLibraryError.emptyPlaybackQueue
        }
    }

    func albumDetails(for album: Album) async throws -> Album {
        try await album.with(.tracks)
    }

    func completeCatalogAlbumDetails(for album: Album) async throws -> Album {
        try await catalogAlbumDetails(for: album)
    }

    func playlistDetails(for playlist: Playlist) async throws -> Playlist {
        do {
            return try await playlist.with(.tracks)
        } catch {
            SonosLog.info(.playlistDetail, "Library playlist detail load failed, trying catalog fallback: \(error)")
            return try await catalogPlaylistDetails(for: playlist)
        }
    }

    func songs(for artist: Artist, limit: Int = 100) async throws -> [Song] {
        try await librarySongs(for: artist, limit: limit)
    }

    func albums(for artist: Artist, limit: Int = 100) async throws -> [Album] {
        try await libraryAlbums(for: artist, limit: limit)
    }

    func play(artist: Artist) async throws {
        let songs = try await librarySongs(for: artist, limit: 100)
        guard let first = songs.first else {
            throw LocalMusicLibraryError.artistHasNoSongs
        }
        try await play(songs, startingAt: first)
    }

    private func librarySnapshot(limit: Int?) async throws -> LocalMusicLibrarySnapshot {
        async let songs = librarySongs(limit: limit)
        async let albums = libraryAlbums(limit: limit)
        async let artists = libraryArtists(limit: limit)
        async let playlists = libraryPlaylists(limit: limit)

        return try await LocalMusicLibrarySnapshot(
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists
        )
    }

    private func recentlyPlayed(limit: Int) async throws -> [RecentlyPlayedMusicItem] {
        var request = MusicRecentlyPlayedContainerRequest()
        request.limit = limit
        let response = try await request.response()
        return Array(response.items)
    }

    private func optionalRecentlyPlayed(limit: Int) async -> [RecentlyPlayedMusicItem] {
        (try? await recentlyPlayed(limit: limit)) ?? []
    }

    private func personalRecommendations(limit: Int) async throws -> [MusicPersonalRecommendation] {
        var request = MusicPersonalRecommendationsRequest()
        request.limit = limit
        let response = try await request.response()
        return Array(response.recommendations)
    }

    private func optionalPersonalRecommendations(limit: Int) async -> [MusicPersonalRecommendation] {
        (try? await personalRecommendations(limit: limit)) ?? []
    }

    private func librarySongs(limit: Int?) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        if let limit {
            request.limit = limit
        }
        request.sort(by: \.libraryAddedDate, ascending: false)
        let response = try await request.response()
        return Array(response.items)
    }

    private func libraryAlbums(limit: Int?) async throws -> [Album] {
        var request = MusicLibraryRequest<Album>()
        if let limit {
            request.limit = limit
        }
        request.sort(by: \.libraryAddedDate, ascending: false)
        let response = try await request.response()
        return Array(response.items)
    }

    private func libraryArtists(limit: Int?) async throws -> [Artist] {
        var request = MusicLibraryRequest<Artist>()
        if let limit {
            request.limit = limit
        }
        request.sort(by: \.name, ascending: true)
        let response = try await request.response()
        return Array(response.items)
    }

    private func libraryPlaylists(limit: Int?) async throws -> [Playlist] {
        var request = MusicLibraryRequest<Playlist>()
        if let limit {
            request.limit = limit
        }
        request.sort(by: \.libraryAddedDate, ascending: false)
        let response = try await request.response()
        return Array(response.items)
    }

    private func librarySongs(for artist: Artist, limit: Int) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.limit = limit
        request.filter(matching: \.artists, contains: artist)
        request.sort(by: \.title, ascending: true)
        let response = try await request.response()
        return Array(response.items)
    }

    private func libraryAlbums(for artist: Artist, limit: Int) async throws -> [Album] {
        var request = MusicLibraryRequest<Album>()
        request.limit = limit
        request.filter(matching: \.artists, contains: artist)
        request.sort(by: \.title, ascending: true)
        let response = try await request.response()
        return Array(response.items)
    }

    private func catalogAlbumDetails(for album: Album) async throws -> Album {
        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: .album,
            title: album.title,
            artist: album.artistName,
            album: album.title)
        var request = MusicCatalogSearchRequest(term: term, types: [Album.self])
        request.limit = 12
        let response = try await request.response()
        let albums = Array(response.albums)
        let items = albums.map {
            AppleMusicCatalogSearchItem(
                id: $0.id.rawValue,
                type: .album,
                title: $0.title,
                artist: $0.artistName,
                album: $0.title,
                artworkURLString: $0.artwork?.url(width: 400, height: 400)?.absoluteString,
                duration: nil)
        }
        guard let match = LocalMusicCatalogMatcher.bestItem(
            in: items,
            kind: .album,
            title: album.title,
            artist: album.artistName,
            album: album.title),
              let catalogAlbum = albums.first(where: { $0.id.rawValue == match.id }) else {
            throw LocalMusicLibraryError.catalogMatchMissing
        }
        return try await catalogAlbum.with(.tracks)
    }

    private func catalogPlaylistDetails(for playlist: Playlist) async throws -> Playlist {
        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: .playlist,
            title: playlist.name,
            artist: playlist.curatorName,
            album: nil)
        var request = MusicCatalogSearchRequest(term: term, types: [Playlist.self])
        request.limit = 12
        let response = try await request.response()
        let playlists = Array(response.playlists)
        let items = playlists.map {
            AppleMusicCatalogSearchItem(
                id: $0.id.rawValue,
                type: .playlist,
                title: $0.name,
                artist: $0.curatorName ?? "",
                album: "",
                artworkURLString: $0.artwork?.url(width: 400, height: 400)?.absoluteString,
                duration: nil)
        }
        guard let match = LocalMusicCatalogMatcher.bestItem(
            in: items,
            kind: .playlist,
            title: playlist.name,
            artist: playlist.curatorName,
            album: nil),
              let catalogPlaylist = playlists.first(where: { $0.id.rawValue == match.id }) else {
            throw LocalMusicLibraryError.catalogMatchMissing
        }
        return try await catalogPlaylist.with(.tracks)
    }

    private func play(_ songs: [Song], startingAt song: Song) async throws {
        guard !songs.isEmpty else {
            throw LocalMusicLibraryError.emptyPlaybackQueue
        }

        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: song)
        try await player.prepareToPlay()
        try await player.play()
    }
}
