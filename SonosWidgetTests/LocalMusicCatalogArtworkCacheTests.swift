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

    func testExpiredURLStringsAreIgnored() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (cache, defaults, suiteName) = makeCache(now: { now }, ttl: 60)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = LocalMusicCatalogArtworkKey(kind: .playlist, id: "playlist-1")

        cache.storeURLString("https://example.com/playlist.jpg", for: key)
        now = Date(timeIntervalSince1970: 1_061)

        XCTAssertNil(cache.urlString(for: key))
    }

    func testRecentMissesPreventRepeatedLookup() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = LocalMusicCatalogArtworkKey(kind: .artist, id: "artist-1")

        cache.storeMiss(for: key)

        XCTAssertTrue(cache.hasRecentMiss(for: key))
    }

    func testSnapshotReturnsFreshURLsAndRecentMisses() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (cache, defaults, suiteName) = makeCache(now: { now }, ttl: 60)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let freshKey = LocalMusicCatalogArtworkKey(kind: .album, id: "fresh-album")
        let expiredKey = LocalMusicCatalogArtworkKey(kind: .album, id: "expired-album")
        let missKey = LocalMusicCatalogArtworkKey(kind: .artist, id: "missing-artist")

        cache.storeURLString("https://example.com/expired.jpg", for: expiredKey)
        now = Date(timeIntervalSince1970: 1_030)
        cache.storeURLString("https://example.com/fresh.jpg", for: freshKey)
        now = Date(timeIntervalSince1970: 1_061)
        cache.storeMiss(for: missKey)

        let snapshot = cache.snapshot()

        XCTAssertEqual(snapshot.urlString(for: freshKey), "https://example.com/fresh.jpg")
        XCTAssertNil(snapshot.urlString(for: expiredKey))
        XCTAssertTrue(snapshot.hasRecentMiss(for: missKey))
    }

    func testPlannerPromotesDirectArtworkAndCachedArtworkBeforeLookup() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let direct = LocalMusicCatalogArtworkLookupItem(
            id: "song-1",
            kind: .song,
            title: "Song",
            artist: "Artist",
            album: "Album",
            directArtworkURLString: "https://example.com/direct.jpg")
        let cached = LocalMusicCatalogArtworkLookupItem(
            id: "album-1",
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
            items: [direct, cached, missing],
            inMemoryURLStrings: [:],
            inMemoryMissIDs: [],
            cache: cache)

        XCTAssertEqual(
            plan.immediateURLStrings[direct.key.storageKey],
            "https://example.com/direct.jpg")
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
