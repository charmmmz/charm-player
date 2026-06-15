import Foundation

enum AlbumArtTrackIdentity {
    static func make(from trackInfo: TrackInfo?) -> String? {
        guard let trackInfo else { return nil }

        let title = normalizedMetadata(trackInfo.title)
        let artist = normalizedMetadata(trackInfo.artist)
        let album = normalizedMetadata(trackInfo.album)
        if !title.isEmpty || !artist.isEmpty || !album.isEmpty {
            return "meta:\(title)|\(artist)|\(album)|\(trackInfo.source.rawValue)"
        }

        if let trackURI = normalizedURI(trackInfo.trackURI) {
            return "uri:\(trackURI)"
        }

        return nil
    }

    private static func normalizedMetadata(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizedURI(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

enum AlbumArtRefreshPolicy {
    static func shouldPreserveDisplayedArtwork(
        hasDisplayedArtwork: Bool,
        displayedTrackIdentity: String?,
        incomingTrackIdentity: String?
    ) -> Bool {
        guard hasDisplayedArtwork,
              let displayedTrackIdentity,
              let incomingTrackIdentity else {
            return false
        }
        return displayedTrackIdentity == incomingTrackIdentity
    }
}

enum AlbumArtTransitionIdentity {
    static func id(trackIdentity: String?, hasDisplayedArtwork: Bool) -> String {
        guard hasDisplayedArtwork else { return "album-art-placeholder" }
        return "album-art-\(trackIdentity ?? "unknown")"
    }

    static func id(
        displayedTrackIdentity: String?,
        currentTrackIdentity: String?,
        hasDisplayedArtwork: Bool
    ) -> String {
        id(
            trackIdentity: displayedTrackIdentity ?? currentTrackIdentity,
            hasDisplayedArtwork: hasDisplayedArtwork
        )
    }

    static func id(albumArtURL _: String?, hasDisplayedArtwork: Bool) -> String {
        id(trackIdentity: nil, hasDisplayedArtwork: hasDisplayedArtwork)
    }
}

enum AlbumArtPlaceholderIcon {
    static func systemName(source: PlaybackSource?, hasDisplayedArtwork: Bool) -> String? {
        if source == .tv {
            return "tv"
        }
        return hasDisplayedArtwork ? nil : "music.note"
    }
}
