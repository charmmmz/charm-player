import XCTest
@testable import SonosWidget

final class PlaybackArtworkURLCacheTests: XCTestCase {
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
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg"
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

        XCTAssertNil(cache.resolvedQueueItem(objectOnlyQueueItem(id: "song:2"), service: .appleMusic).albumArtURL)
        XCTAssertEqual(cache.resolvedQueueItem(objectOnlyQueueItem(id: "song:1"), service: .appleMusic).albumArtURL, "https://cdn.example.com/1.jpg")
        XCTAssertEqual(cache.resolvedQueueItem(objectOnlyQueueItem(id: "song:3"), service: .appleMusic).albumArtURL, "https://cdn.example.com/3.jpg")
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
