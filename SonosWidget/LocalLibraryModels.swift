import Foundation

enum LocalLibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case songs
    case albums
    case artists
    case playlists

    var id: String { rawValue }

    static var homeOrder: [LocalLibraryCategory] {
        [.playlists, .artists, .albums, .songs]
    }

    var showsAlphabetIndex: Bool {
        self != .playlists
    }

    var title: String {
        switch self {
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: return "music.note"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .playlists: return "music.note.list"
        }
    }

    var emptyTitle: String {
        switch self {
        case .songs: return "No Songs"
        case .albums: return "No Albums"
        case .artists: return "No Artists"
        case .playlists: return "No Playlists"
        }
    }
}

nonisolated enum LocalLibrarySectionIndex {
    static func indexTitle(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "#" }

        let folded = trimmed.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        guard let scalar = folded.uppercased().unicodeScalars.first,
              (65...90).contains(Int(scalar.value)) else {
            return "#"
        }

        return String(Character(scalar))
    }

    static func indexTitles(for titles: [String]) -> [String] {
        let titles = Set(titles.map(indexTitle(for:)))
        return titles.sorted { lhs, rhs in
            if lhs == "#" { return true }
            if rhs == "#" { return false }
            return lhs < rhs
        }
    }
}

struct LocalLibrarySnapshotSummary: Equatable, Sendable {
    let songCount: Int
    let albumCount: Int
    let artistCount: Int
    let playlistCount: Int

    var totalCount: Int {
        songCount + albumCount + artistCount + playlistCount
    }

    var isEmpty: Bool {
        totalCount == 0
    }

    func count(for category: LocalLibraryCategory) -> Int {
        switch category {
        case .songs: return songCount
        case .albums: return albumCount
        case .artists: return artistCount
        case .playlists: return playlistCount
        }
    }
}

enum LocalServiceSectionKind: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded
    case recentlyPlayed
    case recommendations
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .recommendations: return "For You"
        case .library: return "Your Library"
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyAdded: return "clock.badge.plus"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .recommendations: return "sparkles"
        case .library: return "music.note.list"
        }
    }
}

enum LocalMusicDetailAction: Equatable, Hashable, Sendable {
    case play
    case shuffle
    case playStation
    case openAppleMusic

    var title: String {
        switch self {
        case .play: return "Play"
        case .shuffle: return "Shuffle"
        case .playStation: return "Play Station"
        case .openAppleMusic: return "Apple Music"
        }
    }

    var systemImage: String {
        switch self {
        case .play: return "play.fill"
        case .shuffle: return "shuffle"
        case .playStation: return "antenna.radiowaves.left.and.right"
        case .openAppleMusic: return "music.note"
        }
    }

    var isCompact: Bool {
        self == .openAppleMusic
    }
}

enum LocalMusicDetailActions {
    static func album(hasAppleMusicURL _: Bool) -> [LocalMusicDetailAction] {
        [.play, .shuffle]
    }

    static func artist(hasAppleMusicURL _: Bool) -> [LocalMusicDetailAction] {
        [.playStation]
    }

    static func playlist(hasAppleMusicURL _: Bool) -> [LocalMusicDetailAction] {
        [.play, .shuffle]
    }
}

enum LocalMusicAppleMusicURL {
    enum Kind {
        case album
        case artist
        case playlist

        init?(_ kind: LocalServiceAppleMusicPlayable.Kind) {
            switch kind {
            case .album:
                self = .album
            case .artist:
                self = .artist
            case .playlist:
                self = .playlist
            case .song, .station:
                return nil
            }
        }

        var pathComponent: String {
            switch self {
            case .album: return "album"
            case .artist: return "artist"
            case .playlist: return "playlist"
            }
        }
    }

    static func url(
        existingURL: URL?,
        catalogURL: URL? = nil,
        playable: LocalServiceAppleMusicPlayable?,
        kind: Kind,
        storefront: String = "us"
    ) -> URL? {
        if let existingURL,
           isSupportedAppleMusicURL(existingURL, kind: kind) {
            return existingURL
        }
        if let catalogURL {
            return catalogURL
        }

        guard let playable,
              let catalogID = publicCatalogSuffix(from: playable.catalogID, kind: kind) else {
            return nil
        }

        let slug = slug(for: playable.title)
        return URL(string: "https://music.apple.com/\(storefront)/\(kind.pathComponent)/\(slug)/\(catalogID)")
    }

    static func externalURL(
        existingURL: URL?,
        catalogURL: URL?,
        kind: Kind,
        requiresCatalogURL: Bool = false
    ) -> URL? {
        if let catalogURL,
           isSupportedAppleMusicURL(catalogURL, kind: kind) {
            return catalogURL
        }

        guard !requiresCatalogURL,
              let existingURL,
              isSupportedAppleMusicURL(existingURL, kind: kind) else {
            return nil
        }
        return existingURL
    }

    static func publicCatalogID(from value: String, kind: Kind) -> String? {
        publicCatalogSuffix(from: value, kind: kind)
    }

    private static func publicCatalogSuffix(from value: String, kind: Kind) -> String? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        let suffix = parts.last ?? value
        let namespace = parts.count > 1 ? parts.dropLast().last?.lowercased() : nil
        guard namespace?.hasPrefix("library") != true,
              !suffix.isEmpty else {
            return nil
        }

        switch kind {
        case .album, .artist:
            return suffix.allSatisfy(\.isNumber) ? suffix : nil
        case .playlist:
            return suffix.hasPrefix("pl.") ? suffix : nil
        }
    }

    private static func isSupportedAppleMusicURL(_ url: URL, kind: Kind) -> Bool {
        guard let link = AppleMusicShareLinkParser.parse(url.absoluteString) else {
            return false
        }

        switch (kind, link.kind) {
        case (.album, .album), (.artist, .artist), (.playlist, .playlist):
            return true
        default:
            return false
        }
    }

    private static func slug(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var result = ""
        var didAppendSeparator = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                didAppendSeparator = false
            } else if !didAppendSeparator, !result.isEmpty {
                result.append("-")
                didAppendSeparator = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased().isEmpty
            ? "music"
            : result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }
}

struct LocalMusicArtistAlbumSummaryInput: Equatable, Sendable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let artworkURL: URL?
}

struct LocalMusicArtistAlbumSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let artistName: String
    let artworkURL: URL?
    let songCount: Int
}

nonisolated enum LocalMusicArtistAlbumSummaryBuilder {
    static func summaries(
        from songs: [LocalMusicArtistAlbumSummaryInput]
    ) -> [LocalMusicArtistAlbumSummary] {
        let grouped = Dictionary(grouping: songs) { song in
            albumTitle(song.albumTitle)
        }

        return grouped
            .map { title, songs in
                let artistName = firstMeaningfulArtist(in: songs)
                return LocalMusicArtistAlbumSummary(
                    id: albumID(title: title, artistName: artistName),
                    title: title,
                    artistName: artistName,
                    artworkURL: songs.first { $0.artworkURL != nil }?.artworkURL,
                    songCount: songs.count)
            }
            .sorted(by: summarySort)
    }

    static func artworkLookupItems(
        from summaries: [LocalMusicArtistAlbumSummary]
    ) -> [LocalMusicCatalogArtworkLookupItem] {
        summaries.map { summary in
            LocalMusicCatalogArtworkLookupItem(
                id: summary.id,
                kind: .album,
                title: summary.title,
                artist: summary.artistName,
                album: summary.title,
                directArtworkURLString: summary.artworkURL?.absoluteString)
        }
    }

    private static func albumTitle(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown Album" : trimmed
    }

    private static func albumID(title: String, artistName: String) -> String {
        "artist-album:\(artistName):\(title)"
    }

    private static func firstMeaningfulArtist(
        in songs: [LocalMusicArtistAlbumSummaryInput]
    ) -> String {
        songs.first {
            !$0.artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.artistName ?? ""
    }

    private static func summarySort(
        _ lhs: LocalMusicArtistAlbumSummary,
        _ rhs: LocalMusicArtistAlbumSummary
    ) -> Bool {
        if lhs.title == "Unknown Album" { return false }
        if rhs.title == "Unknown Album" { return true }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}
