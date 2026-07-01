import Foundation
import MusicKit

struct LocalMusicLibrarySnapshot: Codable {
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

struct LocalMusicRecentlyAddedCandidate<Item> {
    let date: Date?
    let title: String
    let item: Item
}

enum LocalMusicRecentlyAddedSelection {
    static let displayLimit = 16

    static func select<Item>(
        _ candidates: [LocalMusicRecentlyAddedCandidate<Item>],
        limit: Int = displayLimit
    ) -> [Item] {
        Array(
            candidates
                .sorted { lhs, rhs in
                    switch (lhs.date, rhs.date) {
                    case let (left?, right?):
                        return left > right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        return lhs.title < rhs.title
                    }
                }
                .prefix(limit)
                .map(\.item)
        )
    }
}

enum LocalMusicRecentlyAddedItem: Codable {
    case album(Album)
    case playlist(Playlist)
    case song(Song)

    var title: String {
        switch self {
        case .album(let album): return album.title
        case .playlist(let playlist): return playlist.name
        case .song(let song): return song.title
        }
    }

    var libraryAddedDate: Date? {
        switch self {
        case .album(let album): return album.libraryAddedDate
        case .playlist(let playlist): return playlist.libraryAddedDate
        case .song(let song): return song.libraryAddedDate
        }
    }
}

struct LocalMusicRecentlyAddedContent: Codable {
    var items: [LocalMusicRecentlyAddedItem] = []

    init() {}

    init(snapshot: LocalMusicLibrarySnapshot) {
        let candidates = snapshot.albums.map { LocalMusicRecentlyAddedItem.album($0) }
            + snapshot.playlists.map { LocalMusicRecentlyAddedItem.playlist($0) }
            + snapshot.songs.map { LocalMusicRecentlyAddedItem.song($0) }

        items = LocalMusicRecentlyAddedSelection.select(
            candidates.map {
                LocalMusicRecentlyAddedCandidate(
                    date: $0.libraryAddedDate,
                    title: $0.title,
                    item: $0)
            })
    }
}

struct LocalMusicHomeContent: Codable {
    var snapshot = LocalMusicLibrarySnapshot()
    var recentlyPlayed: [RecentlyPlayedMusicItem] = []
    var recommendations: [MusicPersonalRecommendation] = []
    var recommendationsLoadStatus = LocalMusicRecommendationsLoadStatus.loaded

    var recommendationsLoaded: Bool {
        recommendationsLoadStatus.didLoad
    }

    var isEmpty: Bool {
        snapshot.isEmpty && recentlyPlayed.isEmpty && recommendations.isEmpty
    }
}

enum LocalMusicRecommendationsLoadStatus: Codable, Equatable {
    case loaded
    case cancelled
    case failed(String)

    var didLoad: Bool {
        if case .loaded = self {
            return true
        }
        return false
    }

    var diagnosticDescription: String {
        switch self {
        case .loaded:
            return "loaded"
        case .cancelled:
            return "cancelled"
        case .failed(let message):
            return "failed(\(message))"
        }
    }
}

private struct OptionalPersonalRecommendationsResult {
    let items: [MusicPersonalRecommendation]
    let status: LocalMusicRecommendationsLoadStatus
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
        async let recommendationsResult = optionalPersonalRecommendations(limit: recommendationLimit)
        let recommendations = await recommendationsResult

        return try await LocalMusicHomeContent(
            snapshot: snapshot,
            recentlyPlayed: recentlyPlayed,
            recommendations: recommendations.items,
            recommendationsLoadStatus: recommendations.status
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

    func loadCategorySnapshot(_ category: LocalLibraryCategory) async throws -> LocalMusicLibrarySnapshot {
        _ = try await authorize()

        switch category {
        case .songs:
            return LocalMusicLibrarySnapshot(songs: try await librarySongs(limit: nil))
        case .albums:
            return LocalMusicLibrarySnapshot(albums: try await libraryAlbums(limit: nil))
        case .artists:
            return LocalMusicLibrarySnapshot(artists: try await libraryArtists(limit: nil))
        case .playlists:
            return LocalMusicLibrarySnapshot(playlists: try await libraryPlaylists(limit: nil))
        }
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

    func artistDetails(for artist: Artist) async throws -> Artist {
        if let catalogID = LocalMusicAppleMusicURL.publicCatalogID(from: artist.id.rawValue, kind: .artist) {
            return try await AppleMusicCatalogSearchClient.shared.artist(catalogID: catalogID)
        }
        return try await catalogArtistDetails(for: artist)
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

    private func optionalPersonalRecommendations(limit: Int) async -> OptionalPersonalRecommendationsResult {
        do {
            return OptionalPersonalRecommendationsResult(
                items: try await personalRecommendations(limit: limit),
                status: .loaded
            )
        } catch is CancellationError {
            SonosLog.info(.localService, "Personal recommendations cancelled")
            return OptionalPersonalRecommendationsResult(items: [], status: .cancelled)
        } catch {
            let message = "\(type(of: error)): \(error)"
            SonosLog.info(.localService, "Personal recommendations unavailable: \(message)")
            return OptionalPersonalRecommendationsResult(items: [], status: .failed(message))
        }
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

    private func catalogArtistDetails(for artist: Artist) async throws -> Artist {
        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: .artist,
            title: artist.name,
            artist: artist.name,
            album: nil)
        var request = MusicCatalogSearchRequest(term: term, types: [Artist.self])
        request.limit = 12
        let response = try await request.response()
        let artists = Array(response.artists)
        let items = artists.map {
            AppleMusicCatalogSearchItem(
                id: $0.id.rawValue,
                type: .artist,
                title: $0.name,
                artist: "",
                album: "",
                artworkURLString: $0.artwork?.url(width: 400, height: 400)?.absoluteString,
                duration: nil)
        }
        guard let match = LocalMusicCatalogMatcher.bestItem(
            in: items,
            kind: .artist,
            title: artist.name,
            artist: artist.name,
            album: nil),
              let catalogArtist = artists.first(where: { $0.id.rawValue == match.id }) else {
            throw LocalMusicLibraryError.catalogMatchMissing
        }
        return try await catalogArtist.with(.fullAlbums, .singles, .latestRelease, .topSongs)
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
