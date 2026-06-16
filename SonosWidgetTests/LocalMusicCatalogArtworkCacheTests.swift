import XCTest
@testable import SonosWidget

final class LocalMusicCatalogArtworkCacheTests: XCTestCase {
    func testCachePersistsURLStringsByArtworkKey() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = LocalMusicCatalogArtworkKey(kind: .album, id: "album-1")

        cache.storeURLString("https://example.com/album.jpg", for: key)

        XCTAssertEqual(
            cache.urlString(for: key),
            "https://example.com/album.jpg")
    }

    func testCachePersistsBatchURLStringsByArtworkKey() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let albumKey = LocalMusicCatalogArtworkKey(kind: .album, id: "album-1")
        let playlistKey = LocalMusicCatalogArtworkKey(kind: .playlist, id: "playlist-1")
        let invalidKey = LocalMusicCatalogArtworkKey(kind: .artist, id: "artist-1")

        cache.storeURLStrings([
            albumKey: "https://example.com/album.jpg",
            playlistKey: "https://example.com/playlist.jpg",
            invalidKey: "musickit://artwork/artist-1"
        ])

        XCTAssertEqual(cache.urlString(for: albumKey), "https://example.com/album.jpg")
        XCTAssertEqual(cache.urlString(for: playlistKey), "https://example.com/playlist.jpg")
        XCTAssertNil(cache.urlString(for: invalidKey))
    }

    func testExpiredURLStringsAreIgnored() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (cache, defaults, suiteName) = makeCache(now: { now }, ttl: 60)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = LocalMusicCatalogArtworkKey(kind: .playlist, id: "playlist-1")

        cache.storeURLString("https://example.com/playlist.jpg", for: key)
        now = Date(timeIntervalSince1970: 1_061)

        XCTAssertNil(cache.urlString(for: key))
    }

    func testUnsupportedArtworkURLSchemesAreIgnored() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = LocalMusicCatalogArtworkKey(kind: .album, id: "album-1")

        cache.storeURLString("musickit://artwork/album-1", for: key)

        XCTAssertNil(cache.urlString(for: key))
    }

    func testSnapshotReturnsFreshURLs() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (cache, defaults, suiteName) = makeCache(now: { now }, ttl: 60)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let freshKey = LocalMusicCatalogArtworkKey(kind: .album, id: "fresh-album")
        let expiredKey = LocalMusicCatalogArtworkKey(kind: .album, id: "expired-album")

        cache.storeURLString("https://example.com/expired.jpg", for: expiredKey)
        now = Date(timeIntervalSince1970: 1_030)
        cache.storeURLString("https://example.com/fresh.jpg", for: freshKey)
        now = Date(timeIntervalSince1970: 1_061)

        let snapshot = cache.snapshot()

        XCTAssertEqual(snapshot.urlString(for: freshKey), "https://example.com/fresh.jpg")
        XCTAssertNil(snapshot.urlString(for: expiredKey))
    }

    func testPlannerUsesInMemoryMissesOnlyForTheCurrentLoad() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let item = LocalMusicCatalogArtworkLookupItem(
            id: "artist-1",
            kind: .artist,
            title: "Artist",
            artist: "Artist",
            album: nil,
            directArtworkURLString: nil)

        let plan = LocalMusicCatalogArtworkPlan.make(
            items: [item],
            inMemoryURLStrings: [:],
            inMemoryMissIDs: [item.key.storageKey],
            cache: cache)

        XCTAssertTrue(plan.lookupItems.isEmpty)
    }

    func testPlannerDoesNotLetPersistedMissesPoisonFutureLoads() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let item = LocalMusicCatalogArtworkLookupItem(
            id: "album-1",
            kind: .album,
            title: "Album",
            artist: "Artist",
            album: "Album",
            directArtworkURLString: nil)
        let legacyMisses = [
            item.key.storageKey: LegacyCatalogArtworkMissEntry(value: "miss", storedAt: 1_000)
        ]
        defaults.set(
            try! JSONEncoder().encode(legacyMisses),
            forKey: "LocalMusicCatalogArtworkMissCache.v1")

        let plan = LocalMusicCatalogArtworkPlan.make(
            items: [item],
            inMemoryURLStrings: [:],
            inMemoryMissIDs: [],
            cache: cache)

        XCTAssertEqual(plan.lookupItems.map(\.id), ["album-1"])
    }

    func testPlannerLooksUpFallbackWhenDirectArtworkURLIsNotWebLoadable() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let item = LocalMusicCatalogArtworkLookupItem(
            id: "album-1",
            kind: .album,
            title: "Album",
            artist: "Artist",
            album: "Album",
            directArtworkURLString: "musickit://artwork/album-1")

        let plan = LocalMusicCatalogArtworkPlan.make(
            items: [item],
            inMemoryURLStrings: [:],
            inMemoryMissIDs: [],
            cache: cache)

        XCTAssertTrue(plan.immediateURLStrings.isEmpty)
        XCTAssertEqual(plan.lookupItems.map(\.id), ["album-1"])
    }

    func testPlannerSkipsCachedArtworkWhenMusicKitArtworkIsAlreadyPresent() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let item = LocalMusicCatalogArtworkLookupItem(
            id: "album-with-artwork",
            kind: .album,
            title: "Album",
            artist: "Artist",
            album: "Album",
            directArtworkURLString: "https://example.com/direct.jpg")
        cache.storeURLString("https://example.com/cached-wrong.jpg", for: item.key)

        let plan = LocalMusicCatalogArtworkPlan.make(
            items: [item],
            inMemoryURLStrings: [:],
            inMemoryMissIDs: [],
            cache: cache)

        XCTAssertTrue(plan.immediateURLStrings.isEmpty)
        XCTAssertTrue(plan.lookupItems.isEmpty)
    }

    func testPlannerUsesCachedArtworkBeforeLookupWhenMusicKitArtworkIsMissing() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cached = LocalMusicCatalogArtworkLookupItem(
            id: "album-without-artwork",
            kind: .album,
            title: "Album",
            artist: "Artist",
            album: "Album",
            directArtworkURLString: nil)
        let missing = LocalMusicCatalogArtworkLookupItem(
            id: "artist-1",
            kind: .artist,
            title: "Artist",
            artist: "Artist",
            album: nil,
            directArtworkURLString: nil)
        cache.storeURLString("https://example.com/cached.jpg", for: cached.key)

        let plan = LocalMusicCatalogArtworkPlan.make(
            items: [cached, missing],
            inMemoryURLStrings: [:],
            inMemoryMissIDs: [],
            cache: cache)

        XCTAssertEqual(
            plan.immediateURLStrings[cached.key.storageKey],
            "https://example.com/cached.jpg")
        XCTAssertEqual(plan.lookupItems.map(\.id), ["artist-1"])
    }

    func testResolverLimitsConcurrentLookups() async {
        let items = (0..<10).map {
            LocalMusicCatalogArtworkLookupItem(
                id: "item-\($0)",
                kind: .song,
                title: "Song \($0)",
                artist: "Artist",
                album: "Album",
                directArtworkURLString: nil)
        }
        let probe = LocalMusicCatalogArtworkConcurrencyProbe()

        let results = await LocalMusicCatalogArtworkResolver.resolve(
            items: items,
            maxConcurrentLookups: 3
        ) { item in
            await probe.begin()
            try? await Task.sleep(for: .milliseconds(20))
            await probe.end()
            return "https://example.com/\(item.id).jpg"
        }

        XCTAssertEqual(results.count, 10)
        let maxActiveCount = await probe.maxActiveCount
        XCTAssertLessThanOrEqual(maxActiveCount, 3)
    }

    private func makeCache(
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) },
        ttl: TimeInterval = 60
    ) -> (LocalMusicCatalogArtworkCache, UserDefaults, String) {
        let suiteName = "LocalMusicCatalogArtworkCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            LocalMusicCatalogArtworkCache(defaults: defaults, now: now, ttl: ttl),
            defaults,
            suiteName
        )
    }
}

private actor LocalMusicCatalogArtworkConcurrencyProbe {
    private var activeCount = 0
    private var recordedMaxActiveCount = 0

    var maxActiveCount: Int { recordedMaxActiveCount }

    func begin() {
        activeCount += 1
        recordedMaxActiveCount = max(recordedMaxActiveCount, activeCount)
    }

    func end() {
        activeCount -= 1
    }
}

private struct LegacyCatalogArtworkMissEntry: Codable {
    let value: String
    let storedAt: TimeInterval
}
