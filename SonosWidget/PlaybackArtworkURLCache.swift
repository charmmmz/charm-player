import Foundation

struct PlaybackArtworkURLCache {
    static let shared = PlaybackArtworkURLCache(
        defaults: UserDefaults(suiteName: SharedStorage.appGroupID) ?? .standard
    )

    struct CachedURL: Equatable {
        let urlString: String
        let source: PlaybackArtworkResolutionSource
    }

    private struct Entry: Codable {
        var urlString: String?
        var cacheKey: String
        var source: PlaybackArtworkResolutionSource
        var storedAt: TimeInterval
        var lastAccessedAt: TimeInterval
        var isAmbiguous: Bool
    }

    private final class StorageBox {
        let lock = NSLock()
        var entries: [String: Entry]?
    }

    let defaults: UserDefaults
    let now: () -> Date
    let ttlBySource: [PlaybackArtworkResolutionSource: TimeInterval]
    let maxEntries: Int

    private let storeKey = "PlaybackArtworkURLCache.v1"
    private let storageBox = StorageBox()

    init(
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        ttlBySource: [PlaybackArtworkResolutionSource: TimeInterval] = Self.defaultTTLBySource,
        maxEntries: Int = 1_500
    ) {
        self.defaults = defaults
        self.now = now
        self.ttlBySource = ttlBySource
        self.maxEntries = max(1, maxEntries)
    }

    static let defaultTTLBySource: [PlaybackArtworkResolutionSource: TimeInterval] = [
        .existingPublic: 60 * 60 * 24 * 30,
        .registry: 60 * 60 * 24 * 30,
        .sonosCloud: 60 * 60 * 24 * 30,
        .musicKitDirect: 60 * 60 * 24 * 90,
        .musicKitSearch: 60 * 60 * 24 * 30,
        .iTunesLookup: 60 * 60 * 24 * 30,
        .iTunesSearch: 60 * 60 * 24 * 14
    ]

    func register(
        items: [BrowseItem],
        service: PlaybackArtworkService,
        source: PlaybackArtworkResolutionSource
    ) {
        var storedCount = 0
        var skippedCount = 0
        var entries = entries()

        for item in items {
            guard let urlString = canonicalArtworkURLString(for: item) else {
                skippedCount += 1
                continue
            }
            let keys = PlaybackArtworkIdentity.browseItem(item).lookupKeys
            guard !keys.isEmpty else {
                skippedCount += 1
                continue
            }
            storedCount += remember(
                urlString,
                source: source,
                service: service,
                lookupKeys: keys,
                entries: &entries
            )
        }

        let prunedCount = prune(entries: &entries)
        if storedCount > 0 || prunedCount > 0 {
            store(entries)
        }

        if storedCount > 0 || skippedCount > 0 {
            SonosLog.debug(
                .playbackLink,
                "Playback artwork URL cache register service=\(service.rawValue) source=\(source.rawValue) " +
                    "items=\(items.count) storedKeys=\(storedCount) skipped=\(skippedCount) entries=\(entries.count)")
        }
    }

    func storeURLString(
        _ urlString: String,
        service: PlaybackArtworkService,
        source: PlaybackArtworkResolutionSource,
        identity: PlaybackArtworkIdentity
    ) {
        guard let normalized = canonicalArtworkURLString(urlString),
              !identity.lookupKeys.isEmpty else {
            SonosLog.debug(
                .playbackLink,
                "Playback artwork URL cache store skipped source=\(source.rawValue) " +
                    "url=\(SonosLog.playbackLinkValue(urlString, maxLength: 240)) keys=\(identity.lookupKeys.count)")
            return
        }

        var entries = entries()
        let changedCount = remember(
            normalized,
            source: source,
            service: service,
            lookupKeys: identity.lookupKeys,
            entries: &entries
        )
        let prunedCount = prune(entries: &entries)
        if changedCount > 0 || prunedCount > 0 {
            store(entries)
        }
        SonosLog.debug(
            .playbackLink,
            "Playback artwork URL cache store service=\(service.rawValue) source=\(source.rawValue) " +
                "storedKeys=\(changedCount) entries=\(entries.count) " +
                "url=\(SonosLog.playbackLinkValue(normalized, maxLength: 240))")
    }

    func cachedURL(
        for identity: PlaybackArtworkIdentity,
        service: PlaybackArtworkService
    ) -> CachedURL? {
        let lookupKeys = identity.lookupKeys
        guard !lookupKeys.isEmpty else { return nil }

        var current = entries()
        var removedStale = false
        for key in lookupKeys {
            let storageKey = key.storageKey(service: service)
            guard let entry = current[storageKey],
                  !entry.isAmbiguous,
                  let urlString = entry.urlString else {
                continue
            }
            guard isFresh(entry), canonicalArtworkURLString(urlString) != nil else {
                current.removeValue(forKey: storageKey)
                removedStale = true
                SonosLog.debug(
                    .playbackLink,
                    "Playback artwork URL cache stale service=\(service.rawValue) source=\(entry.source.rawValue) key=\(storageKey)")
                continue
            }
            if removedStale {
                store(current)
            }
            SonosLog.debug(
                .playbackLink,
                "Playback artwork URL cache hit service=\(service.rawValue) source=\(entry.source.rawValue) key=\(storageKey)")
            return CachedURL(urlString: urlString, source: entry.source)
        }

        if removedStale {
            store(current)
        }
        SonosLog.debug(
            .playbackLink,
            "Playback artwork URL cache miss service=\(service.rawValue) keys=\(lookupKeys.count)")
        return nil
    }

    func resolvedQueueItems(
        _ items: [QueueItem],
        service: PlaybackArtworkService
    ) -> (items: [QueueItem], replacementCount: Int) {
        var replacementCount = 0
        let resolved = items.map { item in
            let next = resolvedQueueItem(item, service: service)
            if next.albumArtURL != item.albumArtURL {
                replacementCount += 1
            }
            return next
        }
        return (resolved, replacementCount)
    }

    func resolvedQueueItem(
        _ item: QueueItem,
        service: PlaybackArtworkService
    ) -> QueueItem {
        guard shouldReplaceArtworkURL(item.albumArtURL),
              let cached = cachedURL(for: .queueItem(item), service: service) else {
            return item
        }

        var resolved = item
        resolved.albumArtURL = cached.urlString
        return resolved
    }

    private func remember(
        _ urlString: String,
        source: PlaybackArtworkResolutionSource,
        service: PlaybackArtworkService,
        lookupKeys: [PlaybackArtworkLookupKey],
        entries: inout [String: Entry]
    ) -> Int {
        let nowSeconds = now().timeIntervalSince1970
        let cacheKey = ArtworkURLNormalizer.artworkCacheKey(from: urlString) ?? urlString
        var changedCount = 0

        for lookupKey in lookupKeys {
            let storageKey = lookupKey.storageKey(service: service)
            guard let existing = entries[storageKey] else {
                entries[storageKey] = Entry(
                    urlString: urlString,
                    cacheKey: cacheKey,
                    source: source,
                    storedAt: nowSeconds,
                    lastAccessedAt: nowSeconds,
                    isAmbiguous: false
                )
                changedCount += 1
                continue
            }

            guard existing.cacheKey != cacheKey else {
                guard existing.urlString != urlString
                        || existing.source != source
                        || existing.isAmbiguous else {
                    continue
                }
                entries[storageKey] = Entry(
                    urlString: urlString,
                    cacheKey: cacheKey,
                    source: source,
                    storedAt: existing.storedAt,
                    lastAccessedAt: nowSeconds,
                    isAmbiguous: false
                )
                changedCount += 1
                continue
            }

            guard !existing.isAmbiguous else { continue }
            entries[storageKey] = Entry(
                urlString: nil,
                cacheKey: existing.cacheKey,
                source: existing.source,
                storedAt: existing.storedAt,
                lastAccessedAt: nowSeconds,
                isAmbiguous: true
            )
            changedCount += 1
            SonosLog.debug(
                .playbackLink,
                "Playback artwork URL cache ambiguous service=\(service.rawValue) key=\(storageKey)")
        }

        return changedCount
    }

    private func prune(entries: inout [String: Entry]) -> Int {
        guard entries.count > maxEntries else { return 0 }
        let overflow = entries.count - maxEntries
        let keysToRemove = entries
            .sorted {
                if $0.value.lastAccessedAt == $1.value.lastAccessedAt {
                    return $0.key < $1.key
                }
                return $0.value.lastAccessedAt < $1.value.lastAccessedAt
            }
            .prefix(overflow)
            .map(\.key)
        for key in keysToRemove {
            entries.removeValue(forKey: key)
        }
        let removedCount = keysToRemove.count
        SonosLog.debug(
            .playbackLink,
            "Playback artwork URL cache pruned removed=\(removedCount) entries=\(entries.count) max=\(maxEntries)")
        return removedCount
    }

    private func entries() -> [String: Entry] {
        storageBox.lock.lock()
        if let cached = storageBox.entries {
            storageBox.lock.unlock()
            return cached
        }
        storageBox.lock.unlock()

        guard let data = defaults.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            storageBox.lock.lock()
            storageBox.entries = [:]
            storageBox.lock.unlock()
            return [:]
        }
        var loaded = decoded
        let prunedCount = prune(entries: &loaded)
        if prunedCount > 0 {
            store(loaded)
        } else {
            storageBox.lock.lock()
            storageBox.entries = loaded
            storageBox.lock.unlock()
        }
        return loaded
    }

    private func store(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        storageBox.lock.lock()
        storageBox.entries = entries
        storageBox.lock.unlock()
        defaults.set(data, forKey: storeKey)
    }

    private func isFresh(_ entry: Entry) -> Bool {
        let ttl = ttlBySource[entry.source] ?? 60 * 60 * 24 * 30
        return now().timeIntervalSince1970 - entry.storedAt <= ttl
    }

    private func canonicalArtworkURLString(for item: BrowseItem) -> String? {
        for candidate in [item.thumbnailArtworkURL, item.preferredDetailArtworkURL] {
            guard let normalized = canonicalArtworkURLString(candidate) else { continue }
            return normalized
        }
        return nil
    }

    private func canonicalArtworkURLString(_ value: String?) -> String? {
        guard let normalized = ArtworkURLNormalizer.loadableURLString(
            from: value,
            preserveExistingAppleArtworkSize: true
        ),
              !QueueArtPrefetchPolicy.isLocalSonosArtworkURL(normalized) else {
            return nil
        }
        return normalized
    }

    private func shouldReplaceArtworkURL(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        return QueueArtPrefetchPolicy.isLocalSonosArtworkURL(trimmed)
    }
}
