import Foundation

nonisolated enum PlaybackArtworkPrewarmPolicy {
    static let defaultLimit = 48

    static func urls(
        from items: [BrowseItem],
        limit: Int = defaultLimit
    ) -> [URL] {
        urls(
            from: items.map(\.thumbnailArtworkURL),
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
}
