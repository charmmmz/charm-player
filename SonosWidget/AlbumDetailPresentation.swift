import SwiftUI
import UIKit

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
