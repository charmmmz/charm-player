import Foundation
import XCTest
@testable import SonosWidget

@MainActor
final class PlaybackArtworkPrewarmTests: XCTestCase {
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

    func testSearchManagerPrewarmsKnownPlaybackItems() async {
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

        XCTAssertEqual(capturedURLs, [[
            "https://example.com/one.jpg",
            "https://example.com/two.jpg"
        ]])
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
