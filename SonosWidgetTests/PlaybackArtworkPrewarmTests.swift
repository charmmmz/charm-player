import Foundation
import XCTest
@testable import SonosWidget

@MainActor
final class PlaybackArtworkPrewarmTests: XCTestCase {
    func testLightweightArtworkMetadataRemainsEnabledWhenImagePrewarmIsDisabled() {
        XCTAssertTrue(PlaybackArtworkCachingPolicy.isRegistryEnabled)
        XCTAssertTrue(PlaybackArtworkCachingPolicy.isPlaybackURLCacheEnabled)
        XCTAssertTrue(PlaybackArtworkCachingPolicy.isArtworkHintsEnabled)
        XCTAssertFalse(PlaybackArtworkCachingPolicy.isPrewarmEnabled)
        XCTAssertFalse(PlaybackArtworkCachingPolicy.isQueueDiskCacheEnabled)
    }

    func testPolicyUsesThumbnailArtworkAndDedupesNormalizedURLs() {
        let items = [
            BrowseItem(
                id: "song:1",
                title: "One",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://example.com/cover.jpg#first",
                detailArtworkURL: "https://example.com/cover-large.jpg",
                isContainer: false,
                cloudType: "TRACK"),
            BrowseItem(
                id: "song:2",
                title: "Two",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://example.com/cover.jpg#second",
                isContainer: false,
                cloudType: "TRACK"),
            BrowseItem(
                id: "song:3",
                title: "Three",
                artist: "Artist",
                album: "Album",
                albumArtURL: nil,
                detailArtworkURL: "https://example.com/detail-only.jpg",
                isContainer: false,
                cloudType: "TRACK")
        ]

        let urls = PlaybackArtworkPrewarmPolicy.urls(from: items, limit: 8)

        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com/cover.jpg#first",
            "https://example.com/detail-only.jpg"
        ])
    }

    func testRemoteArtworkLoaderPrefetchDedupesAndHonorsLimit() async throws {
        let probe = PlaybackArtworkFetchProbe(data: Self.pngData)
        let loader = RemoteArtworkImageLoader(fetch: { request in
            try await probe.fetch(request)
        })
        let urls = [
            URL(string: "https://example.com/a.jpg#one")!,
            URL(string: "https://example.com/a.jpg#two")!,
            URL(string: "https://example.com/b.jpg")!
        ]

        await loader.prefetch(urls: urls, limit: 1)

        let requestURLs = await probe.requestURLs()
        XCTAssertEqual(requestURLs, ["https://example.com/a.jpg#one"])
    }

    func testSearchManagerDoesNotPrewarmPlaybackArtworkWhileCachingIsDisabled() async {
        let manager = SearchManager()
        var capturedURLs: [[String]] = []
        manager.playbackArtworkPrewarmOverride = { urls in
            capturedURLs.append(urls.map(\.absoluteString))
        }
        let items = [
            BrowseItem(
                id: "song:1",
                title: "One",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://example.com/one.jpg",
                isContainer: false,
                cloudType: "TRACK"),
            BrowseItem(
                id: "song:2",
                title: "Two",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://example.com/two.jpg",
                isContainer: false,
                cloudType: "TRACK")
        ]

        await manager.prewarmPlaybackArtwork(items: items)

        XCTAssertEqual(capturedURLs, [])
    }

    func testSearchManagerRegistersPlaybackArtworkMetadataWithoutImagePrewarm() async {
        let uniqueSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let objectID = "song:\(uniqueSuffix)"
        let escapedObjectID = objectID.replacingOccurrences(of: ":", with: "%3a")
        let urlString = "https://is1-ssl.mzstatic.com/image/thumb/Music/\(uniqueSuffix).jpg/600x600bb.jpg"
        let manager = SearchManager()
        manager.playbackArtworkPrewarmOverride = { _ in
            XCTFail("image prewarm should stay disabled")
        }
        let browseItem = BrowseItem(
            id: objectID,
            title: "Unique Registry Song \(uniqueSuffix)",
            artist: "Registry Artist",
            album: "Registry Album",
            albumArtURL: urlString,
            uri: "x-sonos-http:\(escapedObjectID).mp4?sid=204&flags=8232&sn=2",
            isContainer: false,
            cloudType: "TRACK"
        )

        await manager.prewarmPlaybackArtwork(items: [browseItem])

        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: browseItem.title,
            artist: browseItem.artist,
            album: browseItem.album,
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            uri: "x-sonos-http:\(escapedObjectID).mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )

        XCTAssertEqual(
            PlaybackArtworkRegistry.shared.resolvedQueueItem(queueItem).albumArtURL,
            urlString
        )
        XCTAssertEqual(
            PlaybackArtworkURLCache.shared.resolvedQueueItem(queueItem, service: .appleMusic).albumArtURL,
            urlString
        )
    }

    private static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )!
}

private actor PlaybackArtworkFetchProbe {
    private let data: Data
    private var urls: [String] = []

    init(data: Data) {
        self.data = data
    }

    func requestURLs() -> [String] { urls }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        urls.append(request.url!.absoluteString)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
