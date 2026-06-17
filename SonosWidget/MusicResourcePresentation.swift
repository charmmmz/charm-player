import Foundation

enum MusicResourceKind: Equatable, Sendable {
    case song
    case album
    case artist
    case playlist
    case station
    case collection
    case unknown

    init(cloudType: String?) {
        switch cloudType {
        case "TRACK":
            self = .song
        case "ALBUM":
            self = .album
        case "ARTIST":
            self = .artist
        case "PLAYLIST":
            self = .playlist
        case "PROGRAM":
            self = .station
        case "COLLECTION":
            self = .collection
        default:
            self = .unknown
        }
    }
}

enum MusicResourceAccessory: Equatable, Sendable {
    case play
    case chevron
    case progress
    case none
}

enum MusicResourceMenuAction: Equatable, Hashable, Identifiable, Sendable {
    case playNow
    case playNext
    case addToQueue
    case startStation
    case favorite(AlbumFavoriteKind, isActive: Bool)

    var id: String {
        switch self {
        case .playNow: return "play-now"
        case .playNext: return "play-next"
        case .addToQueue: return "add-to-queue"
        case .startStation: return "start-station"
        case .favorite(let kind, let isActive):
            return "favorite-\(kind)-\(isActive)"
        }
    }

    var title: String {
        switch self {
        case .playNow: return "Play Now"
        case .playNext: return "Play Next"
        case .addToQueue: return "Add to Queue"
        case .startStation: return "Start Station"
        case .favorite(.sonos, false):
            return "Add to Sonos Favorites"
        case .favorite(.sonos, true):
            return "Remove from Sonos Favorites"
        case .favorite(.appleMusic, false):
            return "Add to Apple Music Favorites"
        case .favorite(.appleMusic, true):
            return "Remove from Apple Music Favorites"
        }
    }

    var systemImage: String {
        switch self {
        case .playNow: return "play.fill"
        case .playNext: return "text.line.first.and.arrowtriangle.forward"
        case .addToQueue: return "text.badge.plus"
        case .startStation: return "antenna.radiowaves.left.and.right"
        case .favorite(_, false): return "heart"
        case .favorite(_, true): return "heart.slash"
        }
    }
}

enum MusicResourceActionPolicy {
    static func actions(
        kind: MusicResourceKind,
        isQueueable: Bool,
        supportsStation: Bool = false
    ) -> [MusicResourceMenuAction] {
        if kind == .artist, supportsStation {
            return [.startStation]
        }

        guard isQueueable else {
            return [.playNow]
        }

        return [.playNow, .playNext, .addToQueue]
    }
}

struct MusicResourcePresentation: Identifiable, Sendable {
    let id: String
    let kind: MusicResourceKind
    let title: String
    let subtitle: String
    let detail: String?
    let fallbackSystemImage: String
    let accessory: MusicResourceAccessory
    let isQueueable: Bool

    var artworkTapID: String { id }
    var titleTapID: String { id }

    static func fromBrowseItem(
        _ item: BrowseItem,
        fallbackSystemImage: String,
        accessory: MusicResourceAccessory
    ) -> MusicResourcePresentation {
        MusicResourcePresentation(
            id: item.id,
            kind: MusicResourceKind(cloudType: item.cloudType),
            title: item.title,
            subtitle: item.artist.isEmpty ? item.album : item.artist,
            detail: item.album.isEmpty ? nil : item.album,
            fallbackSystemImage: fallbackSystemImage,
            accessory: accessory,
            isQueueable: item.playbackDescriptor.isQueueable
        )
    }
}

enum MusicResourceArtworkSelection {
    static func preferredRowArtworkURL(primary: URL?, fallback: URL?) -> URL? {
        primary ?? fallback
    }
}

enum MusicResourceTrackLeadingPolicy: Equatable, Sendable {
    case albumTrack
    case playlistTrack

    func selectedArtworkURL(primaryArtworkURL: URL?, fallbackArtworkURL: URL?) -> URL? {
        switch self {
        case .albumTrack:
            nil
        case .playlistTrack:
            MusicResourceArtworkSelection.preferredRowArtworkURL(
                primary: primaryArtworkURL,
                fallback: fallbackArtworkURL)
        }
    }
}

enum LocalMusicTrackRowMenuPolicy {
    static func showsVisibleMenuButton(
        leadingPolicy: MusicResourceTrackLeadingPolicy,
        isPlaying: Bool,
        contextMenuActions: [MusicResourceMenuAction]
    ) -> Bool {
        guard !isPlaying, !contextMenuActions.isEmpty else { return false }

        switch leadingPolicy {
        case .playlistTrack:
            return true
        case .albumTrack:
            return false
        }
    }
}
