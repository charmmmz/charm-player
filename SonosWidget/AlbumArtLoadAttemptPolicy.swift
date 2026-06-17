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

nonisolated enum QueueArtPrefetchPolicy {
    static let defaultLocalSonosArtworkLimit = 3
    static let localSonosArtworkConcurrency = 2
    static let remoteArtworkConcurrency = 8

    static func urlsToPrefetch(
        from urls: [String],
        cachedURLs: Set<String>,
        localSonosArtworkLimit: Int = defaultLocalSonosArtworkLimit
    ) -> [String] {
        var seen = Set<String>()
        var localSonosArtworkCount = 0
        let localLimit = max(0, localSonosArtworkLimit)

        return urls.compactMap { urlString in
            guard !cachedURLs.contains(urlString),
                  seen.insert(urlString).inserted else {
                return nil
            }

            if isLocalSonosArtworkURL(urlString) {
                guard localSonosArtworkCount < localLimit else {
                    return nil
                }
                localSonosArtworkCount += 1
            }

            return urlString
        }
    }

    static func maxConcurrentFetches(for urls: [String]) -> Int {
        urls.contains(where: isLocalSonosArtworkURL)
            ? localSonosArtworkConcurrency
            : remoteArtworkConcurrency
    }

    static func isLocalSonosArtworkURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "http",
              url.port == 1400 else {
            return false
        }
        return url.path.lowercased().contains("getaa")
    }
}
