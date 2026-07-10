import Foundation

@MainActor
final class PlaybackArtworkRegistry {
    static let shared = PlaybackArtworkRegistry()

    private enum LookupKey: Hashable {
        case object(String)
        case track(title: String, artist: String, album: String)
        case album(artist: String, album: String)
    }

    private struct Entry {
        var urlString: String?
        var cacheKey: String
        var isAmbiguous: Bool
    }

    private var entries: [LookupKey: Entry] = [:]

    func register(items: [BrowseItem]) {
        for item in items {
            register(item)
        }
    }

    func register(_ item: BrowseItem) {
        guard let urlString = canonicalArtworkURLString(for: item) else { return }

        for key in lookupKeys(for: item) {
            remember(urlString, for: key)
        }
    }

    func resolvedQueueItems(_ items: [QueueItem]) -> (items: [QueueItem], replacementCount: Int) {
        var replacementCount = 0
        let resolved = items.map { item in
            let next = resolvedQueueItem(item)
            if next.albumArtURL != item.albumArtURL {
                replacementCount += 1
            }
            return next
        }
        return (resolved, replacementCount)
    }

    func resolvedQueueItem(_ item: QueueItem) -> QueueItem {
        guard shouldReplaceArtworkURL(item.albumArtURL),
              let replacement = artworkURLString(for: item) else {
            return item
        }

        var resolved = item
        resolved.albumArtURL = PlaybackArtworkImageSize.queueThumbnailURLString(from: replacement)
        return resolved
    }

    private func artworkURLString(for item: QueueItem) -> String? {
        for key in lookupKeys(for: item) {
            guard let entry = entries[key],
                  !entry.isAmbiguous,
                  let urlString = entry.urlString else {
                continue
            }
            return urlString
        }
        return nil
    }

    func artworkURLString(for identity: PlaybackArtworkIdentity) -> String? {
        for key in lookupKeys(for: identity) {
            guard let entry = entries[key],
                  !entry.isAmbiguous,
                  let urlString = entry.urlString else {
                continue
            }
            return urlString
        }
        return nil
    }

    private func remember(_ urlString: String, for key: LookupKey) {
        let cacheKey = ArtworkURLNormalizer.playbackArtworkFamilyCacheKey(from: urlString)
            ?? ArtworkURLNormalizer.artworkCacheKey(from: urlString)
            ?? urlString
        guard let existing = entries[key] else {
            entries[key] = Entry(urlString: urlString, cacheKey: cacheKey, isAmbiguous: false)
            return
        }

        guard existing.cacheKey != cacheKey else {
            entries[key] = Entry(urlString: urlString, cacheKey: cacheKey, isAmbiguous: false)
            return
        }
        entries[key] = Entry(urlString: nil, cacheKey: existing.cacheKey, isAmbiguous: true)
    }

    private func canonicalArtworkURLString(for item: BrowseItem) -> String? {
        let candidates = [item.thumbnailArtworkURL, item.preferredDetailArtworkURL]
        for candidate in candidates {
            guard let normalized = ArtworkURLNormalizer.loadableURLString(
                from: candidate,
                preserveExistingAppleArtworkSize: true
            ),
                  !QueueArtPrefetchPolicy.isLocalSonosArtworkURL(normalized) else {
                continue
            }
            return normalized
        }
        return nil
    }

    private func shouldReplaceArtworkURL(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        return QueueArtPrefetchPolicy.isLocalSonosArtworkURL(trimmed)
    }

    private func lookupKeys(for item: BrowseItem) -> [LookupKey] {
        lookupKeys(for: PlaybackArtworkIdentity.browseItem(item))
    }

    private func lookupKeys(for item: QueueItem) -> [LookupKey] {
        lookupKeys(for: PlaybackArtworkIdentity.queueItem(item))
    }

    private func lookupKeys(for identity: PlaybackArtworkIdentity) -> [LookupKey] {
        identity.lookupKeys.map { key in
            switch key {
            case .object(let value):
                return .object(value)
            case .track(let title, let artist, let album):
                return .track(title: title, artist: artist, album: album)
            case .album(let artist, let album):
                return .album(artist: artist, album: album)
            }
        }
    }
}
