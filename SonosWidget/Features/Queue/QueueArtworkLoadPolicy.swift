import Foundation

nonisolated enum QueueArtworkLoadPolicy {
    static func shouldAttemptPlaybackArtworkResolution(
        urlString: String?,
        isAppleMusicQueueItem: Bool
    ) -> Bool {
        guard isAppleMusicQueueItem else { return false }
        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || QueueArtPrefetchPolicy.isLocalSonosArtworkURL(trimmed)
    }

    static func shouldLoadRemoteArtwork(
        urlString: String?,
        isAppleMusicQueueItem: Bool,
        didMissPlaybackArtworkResolution: Bool
    ) -> Bool {
        guard let urlString,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard shouldAttemptPlaybackArtworkResolution(
            urlString: urlString,
            isAppleMusicQueueItem: isAppleMusicQueueItem
        ) else {
            return true
        }
        return didMissPlaybackArtworkResolution
    }

    static func isAppleMusicQueueItem(_ item: QueueItem) -> Bool {
        let candidates = [item.uri, item.albumArtURL, item.metaXML]
        return candidates.compactMap { $0 }.contains { value in
            PlaybackSource.from(trackURI: value) == .appleMusic || value.localizedCaseInsensitiveContains("sid=204")
        }
    }

    static func shouldLoadQueueDiskCacheAsync(
        urlString: String?,
        hasQueueMemoryImage: Bool,
        isKnownDiskCached: Bool
    ) -> Bool {
        guard PlaybackArtworkCachingPolicy.isQueueDiskCacheEnabled else {
            return false
        }
        guard let urlString,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !hasQueueMemoryImage && isKnownDiskCached
    }
}
