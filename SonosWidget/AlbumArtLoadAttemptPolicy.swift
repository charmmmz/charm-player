import Foundation

enum AlbumArtLoadAttemptPolicy {
    static func shouldStartLoad(
        urlString: String,
        lastLoadedURL: String?,
        hasDisplayedArtwork: Bool,
        loadingURL: String?
    ) -> Bool {
        guard !urlString.isEmpty else {
            return lastLoadedURL != "" || hasDisplayedArtwork
        }
        if loadingURL == urlString { return false }
        if lastLoadedURL == urlString, hasDisplayedArtwork { return false }
        return true
    }

    static func shouldClearArtworkForMissingURL(
        trackSource: PlaybackSource?,
        hasDisplayedArtwork: Bool,
        displayedTrackIdentity: String?,
        incomingTrackIdentity: String?,
        hasDeferredMissingArtworkForIncomingTrack: Bool
    ) -> Bool {
        guard hasDisplayedArtwork else { return true }
        if trackSource == .tv || trackSource == .lineIn { return true }
        guard let displayedTrackIdentity,
              let incomingTrackIdentity,
              displayedTrackIdentity != incomingTrackIdentity else {
            return true
        }
        return hasDeferredMissingArtworkForIncomingTrack
    }
}

enum AlbumArtURLCarryoverPolicy {
    static func albumArtURL(
        incomingURL: String?,
        previousTrackInfo: TrackInfo?,
        incomingTrackInfo: TrackInfo
    ) -> String? {
        if let incomingURL = normalizedURL(incomingURL) {
            return incomingURL
        }
        guard let previousTrackInfo,
              AlbumArtTrackIdentity.make(from: previousTrackInfo) == AlbumArtTrackIdentity.make(from: incomingTrackInfo) else {
            return nil
        }
        return normalizedURL(previousTrackInfo.albumArtURL)
    }

    private static func normalizedURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
