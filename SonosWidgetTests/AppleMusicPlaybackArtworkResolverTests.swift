import XCTest
@testable import SonosWidget

final class AppleMusicPlaybackArtworkResolverTests: XCTestCase {
    func testExistingPublicArtworkShortCircuitsRegistryCacheAndLookups() async {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolver = AppleMusicPlaybackArtworkResolver(
            cache: cache,
            registryLookup: { _ in XCTFail("registry should not run for public artwork"); return nil },
            musicKitIsAuthorized: { true },
            musicKitDirectLookup: { _, _ in XCTFail("MusicKit direct should not run for public artwork"); return nil },
            musicKitSearchLookup: { _ in XCTFail("MusicKit search should not run for public artwork"); return nil },
            iTunesLookup: { _, _ in XCTFail("iTunes lookup should not run for public artwork"); return nil },
            iTunesSearch: { _ in XCTFail("iTunes search should not run for public artwork"); return nil },
            sonosCloudArtworkLookup: { _ in XCTFail("Sonos Cloud should not run for public artwork"); return nil }
        )

        let result = await resolver.resolve(
            request: request(
                catalogID: "1440857781",
                queueItem: queueItem(
                    storeID: "1440857781",
                    art: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg"
                )
            )
        )

        XCTAssertEqual(result?.source, .existingPublic)
        XCTAssertEqual(result?.urlString, "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg")
    }

    func testRegistryRunsBeforePersistentCache() async {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        cache.register(
            items: [
                BrowseItem(
                    id: "song:1440857781",
                    title: "Moon",
                    artist: "Daniel Caesar",
                    album: "Freudian",
                    albumArtURL: "https://cdn.example.com/cached.jpg",
                    isContainer: false,
                    cloudType: "TRACK"
                )
            ],
            service: .appleMusic,
            source: .sonosCloud
        )
        let resolver = AppleMusicPlaybackArtworkResolver(
            cache: cache,
            registryLookup: { _ in "https://cdn.example.com/current-detail.jpg" },
            musicKitIsAuthorized: { true },
            musicKitDirectLookup: { _, _ in XCTFail("MusicKit direct should not run after registry hit"); return nil },
            musicKitSearchLookup: { _ in XCTFail("MusicKit search should not run after registry hit"); return nil },
            iTunesLookup: { _, _ in XCTFail("iTunes lookup should not run after registry hit"); return nil },
            iTunesSearch: { _ in XCTFail("iTunes search should not run after registry hit"); return nil },
            sonosCloudArtworkLookup: { _ in XCTFail("Sonos Cloud should not run after registry hit"); return nil }
        )

        let result = await resolver.resolve(
            request: request(
                catalogID: "1440857781",
                queueItem: queueItem(storeID: "1440857781", art: "http://192.168.50.249:1400/getaa?s=1")
            )
        )

        XCTAssertEqual(result?.source, .registry)
        XCTAssertEqual(result?.urlString, "https://cdn.example.com/current-detail.jpg")
    }

    func testPersistentCacheRunsBeforeMusicKitWhenRegistryMisses() async {
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        cache.register(
            items: [
                BrowseItem(
                    id: "song:1440857781",
                    title: "Moon",
                    artist: "Daniel Caesar",
                    album: "Freudian",
                    albumArtURL: "https://cdn.example.com/persistent.jpg",
                    isContainer: false,
                    cloudType: "TRACK"
                )
            ],
            service: .appleMusic,
            source: .sonosCloud
        )
        let resolver = AppleMusicPlaybackArtworkResolver(
            cache: cache,
            registryLookup: { _ in nil },
            musicKitIsAuthorized: { true },
            musicKitDirectLookup: { _, _ in XCTFail("MusicKit direct should not run after persistent cache hit"); return nil },
            musicKitSearchLookup: { _ in XCTFail("MusicKit search should not run after persistent cache hit"); return nil },
            iTunesLookup: { _, _ in XCTFail("iTunes lookup should not run after persistent cache hit"); return nil },
            iTunesSearch: { _ in XCTFail("iTunes search should not run after persistent cache hit"); return nil },
            sonosCloudArtworkLookup: { _ in XCTFail("Sonos Cloud should not run after persistent cache hit"); return nil }
        )

        let result = await resolver.resolve(
            request: request(
                catalogID: "1440857781",
                queueItem: queueItem(storeID: "1440857781", art: "http://192.168.50.249:1400/getaa?s=1")
            )
        )

        XCTAssertEqual(result?.source, .persistentCache)
        XCTAssertEqual(result?.urlString, "https://cdn.example.com/persistent.jpg")
    }

    func testUnauthorizedMusicKitIsSkippedAndITunesLookupRuns() async {
        var musicKitCallCount = 0
        var iTunesLookupIDs: [String] = []
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolver = AppleMusicPlaybackArtworkResolver(
            cache: cache,
            registryLookup: { _ in nil },
            musicKitIsAuthorized: { false },
            musicKitDirectLookup: { _, _ in musicKitCallCount += 1; return nil },
            musicKitSearchLookup: { _ in musicKitCallCount += 1; return nil },
            iTunesLookup: { catalogID, _ in
                iTunesLookupIDs.append(catalogID)
                return "https://cdn.example.com/itunes-lookup.jpg"
            },
            iTunesSearch: { _ in nil },
            sonosCloudArtworkLookup: { _ in nil }
        )

        let result = await resolver.resolve(
            request: request(catalogID: "1440857781")
        )

        XCTAssertEqual(musicKitCallCount, 0)
        XCTAssertEqual(iTunesLookupIDs, ["1440857781"])
        XCTAssertEqual(result?.source, .iTunesLookup)
        XCTAssertEqual(result?.urlString, "https://cdn.example.com/itunes-lookup.jpg")
    }

    func testITunesFallbackRunsAfterMusicKitSearchAndBeforeSonosCloud() async {
        var order: [String] = []
        let (cache, defaults, suiteName) = makeCache()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolver = AppleMusicPlaybackArtworkResolver(
            cache: cache,
            registryLookup: { _ in nil },
            musicKitIsAuthorized: { true },
            musicKitDirectLookup: { _, _ in order.append("musicKitDirect"); return nil },
            musicKitSearchLookup: { _ in order.append("musicKitSearch"); return nil },
            iTunesLookup: { _, _ in order.append("iTunesLookup"); return nil },
            iTunesSearch: { _ in order.append("iTunesSearch"); return "https://cdn.example.com/itunes-search.jpg" },
            sonosCloudArtworkLookup: { _ in order.append("sonosCloud"); return nil }
        )

        let result = await resolver.resolve(
            request: request(catalogID: "1440857781")
        )

        XCTAssertEqual(order, ["musicKitDirect", "musicKitSearch", "iTunesLookup", "iTunesSearch"])
        XCTAssertEqual(result?.source, .iTunesSearch)
        XCTAssertEqual(result?.urlString, "https://cdn.example.com/itunes-search.jpg")
    }

    private func makeCache() -> (PlaybackArtworkURLCache, UserDefaults, String) {
        let suiteName = "AppleMusicPlaybackArtworkResolverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            PlaybackArtworkURLCache(
                defaults: defaults,
                ttlBySource: [
                    .sonosCloud: 60,
                    .musicKitDirect: 60,
                    .musicKitSearch: 60,
                    .iTunesLookup: 60,
                    .iTunesSearch: 60,
                    .registry: 60
                ],
                maxEntries: 256
            ),
            defaults,
            suiteName
        )
    }

    private func request(
        catalogID: String?,
        queueItem: QueueItem? = nil
    ) -> PlaybackArtworkRequest {
        PlaybackArtworkRequest(
            service: .appleMusic,
            kind: .song,
            catalogID: catalogID,
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            currentArtworkURLString: queueItem?.albumArtURL,
            identity: queueItem.map(PlaybackArtworkIdentity.queueItem) ?? .metadata(
                objectIDs: catalogID.map { ["song:\($0)"] } ?? [],
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian"
            ),
            countryCode: "US"
        )
    }

    private func queueItem(storeID: String, art: String?) -> QueueItem {
        QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: art,
            uri: "x-sonos-http:song%3a\(storeID).mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )
    }
}
