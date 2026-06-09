import Foundation

nonisolated struct LocalMusicCatalogArtworkKey: Hashable, Sendable {
    let kind: LocalServiceAppleMusicPlayable.Kind
    let id: String

    var storageKey: String {
        "\(kind.storageName):\(id)"
    }
}

nonisolated struct LocalMusicCatalogArtworkLookupItem: Sendable {
    let id: String
    let kind: LocalServiceAppleMusicPlayable.Kind
    let title: String
    let artist: String?
    let album: String?
    let directArtworkURLString: String?

    var key: LocalMusicCatalogArtworkKey {
        LocalMusicCatalogArtworkKey(kind: kind, id: id)
    }
}

nonisolated struct LocalMusicCatalogArtworkCache {
    static let shared = LocalMusicCatalogArtworkCache(
        defaults: UserDefaults(suiteName: SharedStorage.appGroupID) ?? .standard
    )

    private struct Entry: Codable {
        let value: String
        let storedAt: TimeInterval
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let ttl: TimeInterval
    private let urlStoreKey = "LocalMusicCatalogArtworkURLCache.v1"
    private let missStoreKey = "LocalMusicCatalogArtworkMissCache.v1"

    init(
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        ttl: TimeInterval = 60 * 60 * 24 * 30
    ) {
        self.defaults = defaults
        self.now = now
        self.ttl = ttl
    }

    func urlString(for key: LocalMusicCatalogArtworkKey) -> String? {
        guard let entry = entries(for: urlStoreKey)[key.storageKey],
              isFresh(entry),
              isValidURLString(entry.value) else {
            return nil
        }
        return entry.value
    }

    func storeURLString(_ urlString: String, for key: LocalMusicCatalogArtworkKey) {
        guard isValidURLString(urlString) else { return }
        var current = entries(for: urlStoreKey)
        current[key.storageKey] = Entry(value: urlString, storedAt: now().timeIntervalSince1970)
        store(current, for: urlStoreKey)
    }

    func hasRecentMiss(for key: LocalMusicCatalogArtworkKey) -> Bool {
        guard let entry = entries(for: missStoreKey)[key.storageKey],
              isFresh(entry) else {
            return false
        }
        return true
    }

    func storeMiss(for key: LocalMusicCatalogArtworkKey) {
        var current = entries(for: missStoreKey)
        current[key.storageKey] = Entry(value: "miss", storedAt: now().timeIntervalSince1970)
        store(current, for: missStoreKey)
    }

    func snapshot() -> LocalMusicCatalogArtworkCacheSnapshot {
        var urlStrings: [String: String] = [:]
        for (key, entry) in entries(for: urlStoreKey) {
            guard isFresh(entry), isValidURLString(entry.value) else {
                continue
            }
            urlStrings[key] = entry.value
        }

        var missKeys: Set<String> = []
        for (key, entry) in entries(for: missStoreKey) where isFresh(entry) {
            missKeys.insert(key)
        }

        return LocalMusicCatalogArtworkCacheSnapshot(
            urlStringsByStorageKey: urlStrings,
            missStorageKeys: missKeys
        )
    }

    private func entries(for key: String) -> [String: Entry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func store(_ entries: [String: Entry], for key: String) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    private func isFresh(_ entry: Entry) -> Bool {
        now().timeIntervalSince1970 - entry.storedAt <= ttl
    }

    private func isValidURLString(_ value: String) -> Bool {
        URL(string: value) != nil
    }
}

nonisolated struct LocalMusicCatalogArtworkCacheSnapshot {
    let urlStringsByStorageKey: [String: String]
    let missStorageKeys: Set<String>

    func urlString(for key: LocalMusicCatalogArtworkKey) -> String? {
        urlStringsByStorageKey[key.storageKey]
    }

    func hasRecentMiss(for key: LocalMusicCatalogArtworkKey) -> Bool {
        missStorageKeys.contains(key.storageKey)
    }
}

nonisolated struct LocalMusicCatalogArtworkPlan {
    let immediateURLStringsByKey: [LocalMusicCatalogArtworkKey: String]
    let lookupItems: [LocalMusicCatalogArtworkLookupItem]

    var immediateURLStrings: [String: String] {
        Dictionary(uniqueKeysWithValues: immediateURLStringsByKey.map {
            ($0.key.storageKey, $0.value)
        })
    }

    static func make(
        items: [LocalMusicCatalogArtworkLookupItem],
        inMemoryURLStrings: [String: String],
        inMemoryMissIDs: Set<String>,
        cache: LocalMusicCatalogArtworkCache
    ) -> LocalMusicCatalogArtworkPlan {
        var immediate: [LocalMusicCatalogArtworkKey: String] = [:]
        var lookupItems: [LocalMusicCatalogArtworkLookupItem] = []
        let cacheSnapshot = cache.snapshot()

        for item in items {
            let key = item.key
            let storageKey = key.storageKey
            if inMemoryURLStrings[storageKey] != nil {
                continue
            }
            if let directArtworkURLString = validURLString(item.directArtworkURLString) {
                immediate[key] = directArtworkURLString
                continue
            }
            if let cachedURLString = cacheSnapshot.urlString(for: key) {
                immediate[key] = cachedURLString
                continue
            }
            if inMemoryMissIDs.contains(storageKey) || cacheSnapshot.hasRecentMiss(for: key) {
                continue
            }
            lookupItems.append(item)
        }

        return LocalMusicCatalogArtworkPlan(
            immediateURLStringsByKey: immediate,
            lookupItems: lookupItems
        )
    }

    private static func validURLString(_ value: String?) -> String? {
        guard let value,
              URL(string: value) != nil else {
            return nil
        }
        return value
    }
}

nonisolated struct LocalMusicCatalogArtworkLookupResult: Sendable {
    let item: LocalMusicCatalogArtworkLookupItem
    let urlString: String?
}

nonisolated enum LocalMusicCatalogArtworkResolver {
    nonisolated static let defaultMaxConcurrentLookups = 6

    nonisolated static func resolve(
        items: [LocalMusicCatalogArtworkLookupItem],
        maxConcurrentLookups: Int = defaultMaxConcurrentLookups,
        lookup: @escaping @Sendable (LocalMusicCatalogArtworkLookupItem) async -> String?
    ) async -> [LocalMusicCatalogArtworkLookupResult] {
        guard !items.isEmpty else { return [] }

        let limit = max(1, maxConcurrentLookups)
        return await withTaskGroup(
            of: LocalMusicCatalogArtworkLookupResult.self,
            returning: [LocalMusicCatalogArtworkLookupResult].self
        ) { group in
            var iterator = items.makeIterator()
            var submittedCount = 0
            var results: [LocalMusicCatalogArtworkLookupResult] = []

            func submitNext() {
                guard let item = iterator.next() else { return }
                submittedCount += 1
                group.addTask {
                    LocalMusicCatalogArtworkLookupResult(
                        item: item,
                        urlString: await lookup(item)
                    )
                }
            }

            for _ in 0..<min(limit, items.count) {
                submitNext()
            }

            while let result = await group.next() {
                results.append(result)
                if submittedCount < items.count {
                    submitNext()
                }
            }

            return results
        }
    }
}

private extension LocalServiceAppleMusicPlayable.Kind {
    var storageName: String {
        switch self {
        case .song:
            return "song"
        case .album:
            return "album"
        case .artist:
            return "artist"
        case .playlist:
            return "playlist"
        case .station:
            return "station"
        }
    }
}
