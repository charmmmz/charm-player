import XCTest
@testable import SonosWidget

final class PlaybackArtworkURLCacheTests: XCTestCase {
    func testSharedCacheUsesSmallBoundedPersistentStore() {
        XCTAssertLessThanOrEqual(PlaybackArtworkURLCache.shared.maxEntries, 1_500)
    }

    func testPersistsRegisteredAppleMusicArtworkAcrossInstances() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let item = BrowseItem(
            id: "song:123",
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg",
            uri: "x-sonos-http:song%3a123.mp4?sid=204&flags=8232&sn=2",
            isContainer: false,
            cloudType: "TRACK"
        )

        cache.register(items: [item], service: .appleMusic, source: .sonosCloud)

        let reloaded = PlaybackArtworkURLCache(
            defaults: defaults,
            now: cache.now,
            ttlBySource: cache.ttlBySource,
            maxEntries: cache.maxEntries
        )
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: " moon ",
            artist: "DANIEL CAESAR",
            album: "Freudian",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            uri: "x-sonos-http:song%3a123.mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )

        let resolved = reloaded.resolvedQueueItem(queueItem, service: .appleMusic)

        XCTAssertEqual(
            resolved.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/240x240bb.jpg"
        )
    }

    func testAppleMusicArtworkSizeVariantsDoNotMakeIdentityAmbiguous() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = PlaybackArtworkIdentity.metadata(
            objectIDs: ["song:123"],
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian"
        )

        cache.storeURLString(
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg",
            service: .appleMusic,
            source: .musicKitDirect,
            identity: identity
        )
        cache.storeURLString(
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/1200x1200bb.jpg",
            service: .appleMusic,
            source: .musicKitDirect,
            identity: identity
        )

        XCTAssertEqual(
            cache.cachedURL(for: identity, service: .appleMusic)?.urlString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/1200x1200bb.jpg"
        )
    }

    func testLegacySizeSpecificCacheKeyMigratesToArtworkFamilyKey() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (cache, defaults, suiteName) = makeCache(now: { now })
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyURLString = "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg"
        let storageKey = PlaybackArtworkLookupKey.object("song:123").storageKey(service: .appleMusic)
        let legacyJSON = """
        {
          "\(storageKey)": {
            "urlString": "\(legacyURLString)",
            "cacheKey": "\(legacyURLString)",
            "source": "musicKitDirect",
            "storedAt": 1000,
            "lastAccessedAt": 1000,
            "isAmbiguous": false
          }
        }
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "PlaybackArtworkURLCache.v1")
        let identity = PlaybackArtworkIdentity.metadata(
            objectIDs: ["song:123"],
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian"
        )

        now = Date(timeIntervalSince1970: 1_010)
        cache.storeURLString(
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/1200x1200bb.jpg",
            service: .appleMusic,
            source: .musicKitDirect,
            identity: identity
        )

        XCTAssertEqual(
            cache.cachedURL(for: identity, service: .appleMusic)?.urlString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/1200x1200bb.jpg"
        )
    }

    func testResolvedQueueItemUsesSmallAppleArtworkVariant() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queueItem = objectOnlyQueueItem(id: "song:123")

        cache.storeURLString(
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/1200x1200bb.jpg",
            service: .appleMusic,
            source: .musicKitDirect,
            identity: .queueItem(queueItem)
        )

        XCTAssertEqual(
            cache.resolvedQueueItem(queueItem, service: .appleMusic).albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/240x240bb.jpg"
        )
    }

    func testConflictingTextKeyIsAmbiguousButObjectIDStillWins() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        cache.register(
            items: [
                BrowseItem(
                    id: "song:1",
                    title: "Intro",
                    artist: "Artist",
                    album: "Album",
                    albumArtURL: "https://cdn.example.com/a.jpg",
                    isContainer: false,
                    cloudType: "TRACK"
                ),
                BrowseItem(
                    id: "song:2",
                    title: "Intro",
                    artist: "Artist",
                    album: "Album",
                    albumArtURL: "https://cdn.example.com/b.jpg",
                    isContainer: false,
                    cloudType: "TRACK"
                )
            ],
            service: .appleMusic,
            source: .sonosCloud
        )
        let textOnlyQueueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Intro",
            artist: "Artist",
            album: "Album",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            uri: nil,
            metaXML: nil
        )
        let objectQueueItem = QueueItem(
            id: "1",
            objectID: "Q:0/1",
            trackNumber: 2,
            title: "Intro",
            artist: "Artist",
            album: "Album",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            uri: "x-sonos-http:song%3a2.mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )

        XCTAssertEqual(
            cache.resolvedQueueItem(textOnlyQueueItem, service: .appleMusic).albumArtURL,
            "http://192.168.50.249:1400/getaa?s=1"
        )
        XCTAssertEqual(
            cache.resolvedQueueItem(objectQueueItem, service: .appleMusic).albumArtURL,
            "https://cdn.example.com/b.jpg"
        )
    }

    func testPrunesLeastRecentlyUsedKeys() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (cache, defaults, suiteName) = makeCache(now: { now }, maxEntries: 2)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        cache.register(items: [objectOnlyItem(id: "song:1", url: "https://cdn.example.com/1.jpg")], service: .appleMusic, source: .musicKitDirect)
        now = Date(timeIntervalSince1970: 1_010)
        cache.register(items: [objectOnlyItem(id: "song:2", url: "https://cdn.example.com/2.jpg")], service: .appleMusic, source: .musicKitDirect)
        now = Date(timeIntervalSince1970: 1_020)
        XCTAssertEqual(cache.resolvedQueueItem(objectOnlyQueueItem(id: "song:1"), service: .appleMusic).albumArtURL, "https://cdn.example.com/1.jpg")
        now = Date(timeIntervalSince1970: 1_030)
        cache.register(items: [objectOnlyItem(id: "song:3", url: "https://cdn.example.com/3.jpg")], service: .appleMusic, source: .musicKitDirect)

        XCTAssertNil(cache.resolvedQueueItem(objectOnlyQueueItem(id: "song:1"), service: .appleMusic).albumArtURL)
        XCTAssertEqual(cache.resolvedQueueItem(objectOnlyQueueItem(id: "song:2"), service: .appleMusic).albumArtURL, "https://cdn.example.com/2.jpg")
        XCTAssertEqual(cache.resolvedQueueItem(objectOnlyQueueItem(id: "song:3"), service: .appleMusic).albumArtURL, "https://cdn.example.com/3.jpg")
    }

    func testPrunesOversizedPersistentStoreWhenLoaded() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (writer, defaults, suiteName) = makeCache(now: { now }, maxEntries: 10)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        writer.register(items: [objectOnlyItem(id: "song:1", url: "https://cdn.example.com/1.jpg")], service: .appleMusic, source: .musicKitDirect)
        now = Date(timeIntervalSince1970: 1_010)
        writer.register(items: [objectOnlyItem(id: "song:2", url: "https://cdn.example.com/2.jpg")], service: .appleMusic, source: .musicKitDirect)
        now = Date(timeIntervalSince1970: 1_020)
        writer.register(items: [objectOnlyItem(id: "song:3", url: "https://cdn.example.com/3.jpg")], service: .appleMusic, source: .musicKitDirect)

        let reader = PlaybackArtworkURLCache(
            defaults: defaults,
            now: { now },
            ttlBySource: writer.ttlBySource,
            maxEntries: 2
        )

        XCTAssertNil(reader.resolvedQueueItem(objectOnlyQueueItem(id: "song:1"), service: .appleMusic).albumArtURL)
        XCTAssertEqual(reader.resolvedQueueItem(objectOnlyQueueItem(id: "song:2"), service: .appleMusic).albumArtURL, "https://cdn.example.com/2.jpg")
        XCTAssertEqual(reader.resolvedQueueItem(objectOnlyQueueItem(id: "song:3"), service: .appleMusic).albumArtURL, "https://cdn.example.com/3.jpg")
    }

    func testSkipsLocalSonosArtworkURLs() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        cache.register(
            items: [
                BrowseItem(
                    id: "song:1",
                    title: "Song",
                    artist: "Artist",
                    album: "Album",
                    albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
                    isContainer: false,
                    cloudType: "TRACK"
                )
            ],
            service: .appleMusic,
            source: .sonosCloud
        )

        XCTAssertNil(cache.resolvedQueueItem(objectOnlyQueueItem(id: "song:1"), service: .appleMusic).albumArtURL)
    }

    func testMusicKitSearchArtworkDoesNotReuseLocalGetAAIdentityAcrossDifferentTracks() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstLocalArtworkURL = "http://192.168.50.249:1400/getaa?s=1"
        let secondLocalArtworkURL = "http://192.168.50.249:1400/getaa?s=2"
        let first = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Drum Show",
            artist: "twenty one pilots",
            album: "Favorite Songs",
            albumArtURL: firstLocalArtworkURL,
            uri: nil,
            metaXML: nil
        )
        let second = QueueItem(
            id: "1",
            objectID: "Q:0/1",
            trackNumber: 2,
            title: "Time of Our Lives",
            artist: "Pitbull & Ne-Yo",
            album: "Globalization",
            albumArtURL: secondLocalArtworkURL,
            uri: nil,
            metaXML: nil
        )

        cache.storeURLString(
            "https://is1-ssl.mzstatic.com/image/thumb/Music/drum-show.jpg/600x600bb.jpg",
            service: .appleMusic,
            source: .musicKitSearch,
            identity: .queueItem(first)
        )

        let resolved = cache.resolvedQueueItem(second, service: .appleMusic)

        XCTAssertEqual(resolved.albumArtURL, secondLocalArtworkURL)
    }

    func testCacheHitDoesNotRewritePersistentStore() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (cache, defaults, suiteName) = makeCache(now: { now })
        defer { defaults.removePersistentDomain(forName: suiteName) }
        cache.register(
            items: [objectOnlyItem(id: "song:123", url: "https://cdn.example.com/123.jpg")],
            service: .appleMusic,
            source: .musicKitDirect
        )
        let beforeHit = defaults.data(forKey: "PlaybackArtworkURLCache.v1")

        now = Date(timeIntervalSince1970: 1_030)
        XCTAssertEqual(
            cache.resolvedQueueItem(objectOnlyQueueItem(id: "song:123"), service: .appleMusic).albumArtURL,
            "https://cdn.example.com/123.jpg"
        )

        XCTAssertEqual(defaults.data(forKey: "PlaybackArtworkURLCache.v1"), beforeHit)
    }

    func testStoreURLStringDoesNotRewriteUnchangedEntries() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (cache, defaults, suiteName) = makeCache(now: { now })
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = PlaybackArtworkIdentity.metadata(
            objectIDs: ["song:123"],
            title: "Song",
            artist: "Artist",
            album: "Album"
        )

        cache.storeURLString(
            "https://cdn.example.com/123.jpg",
            service: .appleMusic,
            source: .musicKitDirect,
            identity: identity
        )
        let beforeSecondStore = defaults.data(forKey: "PlaybackArtworkURLCache.v1")

        now = Date(timeIntervalSince1970: 2_000)
        cache.storeURLString(
            "https://cdn.example.com/123.jpg",
            service: .appleMusic,
            source: .musicKitDirect,
            identity: identity
        )

        XCTAssertEqual(defaults.data(forKey: "PlaybackArtworkURLCache.v1"), beforeSecondStore)
    }

    func testCacheReusesDecodedEntriesForRepeatedLookups() {
        let suiteName = "PlaybackArtworkURLCacheTests.\(UUID().uuidString)"
        let defaults = CountingUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = PlaybackArtworkURLCache(
            defaults: defaults,
            ttlBySource: [.musicKitDirect: 60],
            maxEntries: 256
        )
        cache.register(
            items: [objectOnlyItem(id: "song:123", url: "https://cdn.example.com/123.jpg")],
            service: .appleMusic,
            source: .musicKitDirect
        )
        defaults.dataReadCount = 0

        XCTAssertNotNil(cache.cachedURL(for: .metadata(objectIDs: ["song:123"], title: "", artist: "", album: ""), service: .appleMusic))
        XCTAssertNotNil(cache.cachedURL(for: .metadata(objectIDs: ["song:123"], title: "", artist: "", album: ""), service: .appleMusic))

        XCTAssertEqual(defaults.dataReadCount, 0)
    }

    func testDoesNotPersistVolatileQueueObjectIDs() {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/2",
            trackNumber: 2,
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            uri: nil,
            metaXML: """
            <DIDL-Lite><item id="Q:0/2"><res>x-sonosapi-hls-static:song%3a123?sid=204&amp;flags=8232&amp;sn=2</res></item></DIDL-Lite>
            """
        )

        cache.storeURLString(
            "https://cdn.example.com/123.jpg",
            service: .appleMusic,
            source: .musicKitDirect,
            identity: .queueItem(queueItem)
        )

        let stored = defaults.data(forKey: "PlaybackArtworkURLCache.v1")
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(stored.contains("q:0/2"))
        XCTAssertNil(
            cache.cachedURL(
                for: .metadata(objectIDs: ["Q:0/2"], title: "", artist: "", album: ""),
                service: .appleMusic
            )
        )
        XCTAssertEqual(
            cache.cachedURL(
                for: .metadata(objectIDs: ["song:123"], title: "Song", artist: "Artist", album: "Album"),
                service: .appleMusic
            )?.urlString,
            "https://cdn.example.com/123.jpg"
        )
    }

    private func makeCache(
        now: @escaping () -> Date = Date.init,
        maxEntries: Int = 256
    ) -> (PlaybackArtworkURLCache, UserDefaults, String) {
        let suiteName = "PlaybackArtworkURLCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            PlaybackArtworkURLCache(
                defaults: defaults,
                now: now,
                ttlBySource: [
                    .sonosCloud: 60,
                    .musicKitDirect: 60,
                    .musicKitSearch: 60,
                    .iTunesLookup: 60,
                    .iTunesSearch: 60,
                    .registry: 60
                ],
                maxEntries: maxEntries
            ),
            defaults,
            suiteName
        )
    }

    private func objectOnlyItem(id: String, url: String) -> BrowseItem {
        BrowseItem(
            id: id,
            title: "",
            artist: "",
            album: "",
            albumArtURL: url,
            isContainer: false,
            cloudType: "TRACK"
        )
    }

    private func objectOnlyQueueItem(id: String) -> QueueItem {
        QueueItem(
            id: id,
            objectID: "Q:0/\(id)",
            trackNumber: 1,
            title: "",
            artist: "",
            album: "",
            albumArtURL: nil,
            uri: "x-sonos-http:\(id.replacingOccurrences(of: ":", with: "%3a")).mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )
    }
}

private final class CountingUserDefaults: UserDefaults {
    var dataReadCount = 0

    override func data(forKey defaultName: String) -> Data? {
        dataReadCount += 1
        return super.data(forKey: defaultName)
    }
}
