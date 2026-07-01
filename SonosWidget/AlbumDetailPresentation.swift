import SwiftUI
import UIKit

private struct AnimatedArtworkPlaybackSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isAnimatedArtworkPlaybackSuspended: Bool {
        get { self[AnimatedArtworkPlaybackSuspendedKey.self] }
        set { self[AnimatedArtworkPlaybackSuspendedKey.self] = newValue }
    }
}

enum AlbumFavoriteKind: Equatable, Hashable, Sendable {
    case sonos
    case appleMusic
}

enum AlbumPrimaryAction: Equatable, Hashable, Sendable {
    case shuffle
    case play
    case favorite(AlbumFavoriteKind)

    var accessibilityTitle: String {
        switch self {
        case .shuffle:
            return "Shuffle"
        case .play:
            return "Play"
        case .favorite(.sonos):
            return "Sonos Favorite"
        case .favorite(.appleMusic):
            return "Apple Music Favorite"
        }
    }
}

enum AlbumPrimaryActionPolicy {
    static func actions(favoriteKind: AlbumFavoriteKind) -> [AlbumPrimaryAction] {
        [.shuffle, .play, .favorite(favoriteKind)]
    }
}

enum AlbumOverflowAction: Equatable, Hashable, Sendable {
    case playNext
    case addToQueue
}

enum AlbumOverflowActionPolicy {
    static let albumActions: [AlbumOverflowAction] = [.playNext, .addToQueue]
}

enum AlbumPlaybackItemPolicy {
    static func playbackItem(from item: BrowseItem, resolvedAlbumID: String?) -> BrowseItem {
        guard item.cloudType?.localizedCaseInsensitiveCompare("ALBUM") == .orderedSame,
              let resolvedAlbumID = meaningfulAlbumID(resolvedAlbumID),
              resolvedAlbumID != item.id else {
            return item
        }

        return BrowseItem(
            id: resolvedAlbumID,
            title: item.title,
            artist: item.artist,
            album: item.album,
            albumArtURL: item.albumArtURL,
            detailArtworkURL: item.detailArtworkURL,
            uri: playbackURI(from: item.uri, resolvedAlbumID: resolvedAlbumID),
            metaXML: item.metaXML,
            duration: item.duration,
            resMD: nil,
            isContainer: item.isContainer,
            serviceId: item.serviceId,
            cloudType: item.cloudType,
            includeAlbumArtInCloudMetadata: item.includeAlbumArtInCloudMetadata,
            cloudFavoriteId: item.cloudFavoriteId
        )
    }

    private static func playbackURI(from uri: String?, resolvedAlbumID: String) -> String? {
        guard let uri,
              let queryStart = uri.firstIndex(of: "?") else {
            return uri
        }

        let encodedObjectID = SonosPlayableURIBuilder.encodedObjectID("1004206c\(resolvedAlbumID)")
        return "x-rincon-cpcontainer:\(encodedObjectID)\(uri[queryStart...])"
    }

    private static func meaningfulAlbumID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AlbumTrackMenuActionPolicy {
    static func actions(
        favoriteKind: AlbumFavoriteKind,
        isFavoriteActive: Bool,
        isQueueable: Bool
    ) -> [MusicResourceMenuAction] {
        var actions: [MusicResourceMenuAction] = [.playNow]
        if isQueueable {
            actions.append(contentsOf: [.playNext, .addToQueue])
        }
        actions.append(.favorite(favoriteKind, isActive: isFavoriteActive))
        return actions
    }

    static func songActions(
        isSonosFavoriteActive: Bool,
        isAppleMusicFavoriteActive: Bool,
        isQueueable: Bool,
        isAppleMusicFavoriteAvailable: Bool = true
    ) -> [MusicResourceMenuAction] {
        MusicResourceActionPolicy.actions(
            kind: .song,
            isQueueable: isQueueable,
            isSonosFavoriteActive: isSonosFavoriteActive,
            isAppleMusicFavoriteActive: isAppleMusicFavoriteActive,
            isAppleMusicFavoriteAvailable: isAppleMusicFavoriteAvailable
        )
    }
}

enum AlbumTrackSubtitlePolicy {
    static func subtitle(trackArtist: String?, albumArtist: String) -> String? {
        guard let trackArtist,
              !trackArtist.isEmpty,
              trackArtist.localizedCaseInsensitiveCompare(albumArtist) != .orderedSame else {
            return nil
        }
        return trackArtist
    }
}

enum EditorialDescriptionPolicy {
    static func text(
        standard: String?,
        short: String?,
        tagline: String?
    ) -> String? {
        [standard, short, tagline]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .first
    }
}

enum AlbumAnimatedArtworkPresentation {
    static func headerURL(
        info: AnimatedArtworkInfo?,
        isEnabled: Bool
    ) -> URL? {
        headerURL(
            info: info,
            isEnabled: isEnabled,
            isImmersiveLayoutActive: false
        )
    }

    static func headerURL(
        info: AnimatedArtworkInfo?,
        isEnabled: Bool,
        isImmersiveLayoutActive: Bool
    ) -> URL? {
        guard isEnabled,
              !isImmersiveLayoutActive,
              fullScreenBackgroundURL(info: info, isEnabled: isEnabled) == nil else {
            return nil
        }
        return info?.playerURL
    }

    static func fullScreenBackgroundURL(
        info: AnimatedArtworkInfo?,
        isEnabled: Bool
    ) -> URL? {
        guard isEnabled else { return nil }
        return info?.tallArtworkURL
    }

    static func shouldUseImmersiveLayout(
        backgroundURL: URL?,
        readyURL: URL?
    ) -> Bool {
        guard let backgroundURL else { return false }
        return readyURL == backgroundURL
    }

    static func shouldResetReadyState(
        current: AnimatedArtworkInfo?,
        next: AnimatedArtworkInfo?
    ) -> Bool {
        !hasSameRenderableArtwork(current, next)
    }

    private static func hasSameRenderableArtwork(
        _ lhs: AnimatedArtworkInfo?,
        _ rhs: AnimatedArtworkInfo?
    ) -> Bool {
        lhs?.playerURL == rhs?.playerURL &&
        lhs?.tallArtworkURL == rhs?.tallArtworkURL
    }

    static func shouldPlayVideo(
        isEnabled: Bool,
        isBackgroundPlaybackSuspended: Bool
    ) -> Bool {
        isEnabled && !isBackgroundPlaybackSuspended
    }

    static func immersiveHeaderSpacerHeight(
        containerWidth: CGFloat,
        viewportHeight: CGFloat,
        videoAspectRatio: CGFloat?
    ) -> CGFloat {
        let width = max(0, containerWidth)
        guard width > 0 else { return 0 }

        let aspectRatio = max(0.35, videoAspectRatio ?? 0.75)
        let foregroundHeight = width / aspectRatio
        let naturalHeight = max(260, foregroundHeight - 118)
        let viewportAlignedHeight = viewportHeight > 0
            ? min(320, max(300, viewportHeight * 0.35))
            : 300
        return min(naturalHeight, viewportAlignedHeight)
    }

    static func contentBackdropTopPadding(isImmersive: Bool) -> CGFloat {
        isImmersive ? -144 : 0
    }

    static func contentBackdropTopOpacity(isImmersive: Bool) -> CGFloat {
        isImmersive ? 0 : 0
    }

    static func contentBackdropStrongFadeLocation(isImmersive: Bool) -> CGFloat {
        isImmersive ? 0.58 : 1
    }

    static func contentBackdropMinimumHeight(
        isImmersive: Bool,
        viewportHeight: CGFloat
    ) -> CGFloat {
        guard isImmersive else { return 0 }
        return max(0, viewportHeight)
    }
}

enum LocalMusicArtistTopSongsPolicy {
    static let previewLimit = 5

    static func previewCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), previewLimit)
    }

    static func shouldShowFullListLink(totalCount: Int) -> Bool {
        totalCount > previewLimit
    }
}

struct AlbumThemeColorComponents: Equatable, Sendable {
    let hue: CGFloat
    let saturation: CGFloat
    let brightness: CGFloat
    let alpha: CGFloat
}

enum AlbumThemeColorPolicy {
    private static let saturationScale: CGFloat = 0.62
    private static let minimumSaturation: CGFloat = 0.16
    private static let maximumSaturation: CGFloat = 0.48
    private static let brightnessScale: CGFloat = 0.58
    private static let minimumBrightness: CGFloat = 0.20
    private static let maximumBrightness: CGFloat = 0.48
    private static let fallbackOpacity: CGFloat = 0.55

    static func mutedComponents(from components: AlbumThemeColorComponents) -> AlbumThemeColorComponents {
        AlbumThemeColorComponents(
            hue: components.hue,
            saturation: min(
                max(components.saturation * saturationScale, minimumSaturation),
                maximumSaturation
            ),
            brightness: min(
                max(components.brightness * brightnessScale, minimumBrightness),
                maximumBrightness
            ),
            alpha: components.alpha
        )
    }

    static func mutedColor(from uiColor: UIColor) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        guard uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return Color(uiColor).opacity(fallbackOpacity)
        }

        let muted = mutedComponents(
            from: AlbumThemeColorComponents(
                hue: hue,
                saturation: saturation,
                brightness: brightness,
                alpha: alpha
            )
        )

        return Color(
            uiColor: UIColor(
                hue: muted.hue,
                saturation: muted.saturation,
                brightness: muted.brightness,
                alpha: muted.alpha
            )
        )
    }
}
