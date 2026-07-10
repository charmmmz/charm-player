import Foundation

nonisolated enum PlaybackArtworkCachingPolicy {
    // Heavy image caches/prewarm stay disabled while playback artwork resolution is validated.
    static let isQueueDiskCacheEnabled = false
    static let isPrewarmEnabled = false

    // Lightweight URL metadata only. These do not fetch images.
    static let isRegistryEnabled = true
    static let isPlaybackURLCacheEnabled = true
    static let isArtworkHintsEnabled = false
}

nonisolated enum PlaybackArtworkPrewarmPolicy {
    static let defaultLimit = 48

    static func urls(
        from items: [BrowseItem],
        limit: Int = defaultLimit
    ) -> [URL] {
        urls(
            from: items.map { thumbnailArtworkURLString(for: $0) },
            limit: limit
        )
    }

    static func urls(
        from urlStrings: [String?],
        limit: Int = defaultLimit
    ) -> [URL] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var urls: [URL] = []

        for rawValue in urlStrings {
            guard urls.count < limit,
                  let rawValue,
                  !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let url = URL(string: rawValue) else {
                continue
            }
            let key = RemoteArtworkImageCacheKey.normalized(url)
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }

        return urls
    }

    private static func thumbnailArtworkURLString(for item: BrowseItem) -> String? {
        nonEmptyArtworkURL(item.albumArtURL) ?? nonEmptyArtworkURL(item.detailArtworkURL)
    }

    private static func nonEmptyArtworkURL(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
