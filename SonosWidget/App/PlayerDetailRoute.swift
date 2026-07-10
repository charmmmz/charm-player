import Foundation
import CoreGraphics

struct PlayerDetailRoute: Hashable {
    enum Kind: Hashable {
        case artist
        case album

        var logName: String {
            switch self {
            case .artist:
                return "artist"
            case .album:
                return "album"
            }
        }
    }

    let kind: Kind
    private let item: PlayerDetailRouteItem

    var browseItem: BrowseItem {
        item.browseItem
    }

    static func artist(_ item: BrowseItem) -> PlayerDetailRoute {
        PlayerDetailRoute(kind: .artist, item: PlayerDetailRouteItem(item))
    }

    static func album(_ item: BrowseItem) -> PlayerDetailRoute {
        PlayerDetailRoute(kind: .album, item: PlayerDetailRouteItem(item))
    }
}

struct PlayerDetailNavigationTransition: Equatable {
    let showFullPlayer: Bool
    let miniPlayerDragOffset: CGFloat
    let selectsHomeTab: Bool
}

enum PlayerDetailNavigationPolicy {
    static let transitionAfterNowPlayingDetailTap = PlayerDetailNavigationTransition(
        showFullPlayer: false,
        miniPlayerDragOffset: 0,
        selectsHomeTab: true
    )
}

enum NowPlayingAppleMusicLinkPolicy {
    static func shouldLinkTitle(canOpenAppleMusicTrack: Bool) -> Bool {
        canOpenAppleMusicTrack
    }

    static func shouldLinkSourceBadge(canOpenAppleMusicTrack _: Bool) -> Bool {
        false
    }
}

enum NowPlayingBottomActionSlot: Equatable, Identifiable, Sendable {
    case emptyLeading
    case queue
    case speaker
    case contextMenu

    var id: String {
        switch self {
        case .emptyLeading:
            return "empty-leading"
        case .queue:
            return "queue"
        case .speaker:
            return "speaker"
        case .contextMenu:
            return "context-menu"
        }
    }
}

enum NowPlayingBottomActionPolicy {
    static func slots(showQueue: Bool) -> [NowPlayingBottomActionSlot] {
        [
            showQueue ? .queue : .emptyLeading,
            .speaker,
            .contextMenu
        ]
    }
}

enum NowPlayingContextMenuAction: Equatable, Identifiable, Sendable {
    case addToSonosFavorites(isEnabled: Bool)
    case addToAppleMusicFavorites(isEnabled: Bool)
    case openInAppleMusic(isEnabled: Bool)

    var id: String {
        switch self {
        case .addToSonosFavorites:
            return "add-to-sonos-favorites"
        case .addToAppleMusicFavorites:
            return "add-to-apple-music-favorites"
        case .openInAppleMusic:
            return "open-in-apple-music"
        }
    }

    var title: String {
        switch self {
        case .addToSonosFavorites:
            return "Add to Sonos Favorites"
        case .addToAppleMusicFavorites:
            return "Add to Apple Music Favorites"
        case .openInAppleMusic:
            return "Open in Apple Music"
        }
    }

    var systemImage: String {
        switch self {
        case .addToSonosFavorites:
            return "heart"
        case .addToAppleMusicFavorites:
            return "music.note"
        case .openInAppleMusic:
            return "arrow.up.right.square"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .addToSonosFavorites(let isEnabled),
             .addToAppleMusicFavorites(let isEnabled),
             .openInAppleMusic(let isEnabled):
            return isEnabled
        }
    }
}

enum NowPlayingContextMenuPolicy {
    static func actions(
        canAddSonosFavorite: Bool,
        canAddAppleMusicFavorite: Bool,
        canOpenAppleMusicTrack: Bool
    ) -> [NowPlayingContextMenuAction] {
        [
            .addToSonosFavorites(isEnabled: canAddSonosFavorite),
            .addToAppleMusicFavorites(isEnabled: canAddAppleMusicFavorite),
            .openInAppleMusic(isEnabled: canOpenAppleMusicTrack)
        ]
    }
}

private struct PlayerDetailRouteItem: Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumArtURL: String?
    let detailArtworkURL: String?
    let uri: String?
    let metaXML: String?
    let duration: TimeInterval
    let resMD: String?
    let isContainer: Bool
    let serviceId: Int?
    let cloudType: String?
    let includeAlbumArtInCloudMetadata: Bool
    let cloudFavoriteId: String?

    init(_ item: BrowseItem) {
        id = item.id
        title = item.title
        artist = item.artist
        album = item.album
        albumArtURL = item.albumArtURL
        detailArtworkURL = item.detailArtworkURL
        uri = item.uri
        metaXML = item.metaXML
        duration = item.duration
        resMD = item.resMD
        isContainer = item.isContainer
        serviceId = item.serviceId
        cloudType = item.cloudType
        includeAlbumArtInCloudMetadata = item.includeAlbumArtInCloudMetadata
        cloudFavoriteId = item.cloudFavoriteId
    }

    var browseItem: BrowseItem {
        BrowseItem(
            id: id,
            title: title,
            artist: artist,
            album: album,
            albumArtURL: albumArtURL,
            detailArtworkURL: detailArtworkURL,
            uri: uri,
            metaXML: metaXML,
            duration: duration,
            resMD: resMD,
            isContainer: isContainer,
            serviceId: serviceId,
            cloudType: cloudType,
            includeAlbumArtInCloudMetadata: includeAlbumArtInCloudMetadata,
            cloudFavoriteId: cloudFavoriteId
        )
    }
}
