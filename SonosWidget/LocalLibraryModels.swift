import Foundation

enum LocalLibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case songs
    case albums
    case artists
    case playlists

    var id: String { rawValue }

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
    static func album(hasAppleMusicURL: Bool) -> [LocalMusicDetailAction] {
        var actions: [LocalMusicDetailAction] = [.play, .shuffle]
        if hasAppleMusicURL {
            actions.append(.openAppleMusic)
        }
        return actions
    }

    static func artist(hasAppleMusicURL: Bool) -> [LocalMusicDetailAction] {
        var actions: [LocalMusicDetailAction] = [.playStation]
        if hasAppleMusicURL {
            actions.append(.openAppleMusic)
        }
        return actions
    }
}
