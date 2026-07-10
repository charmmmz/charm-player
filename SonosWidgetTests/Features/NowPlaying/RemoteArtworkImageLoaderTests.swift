import Foundation
import UIKit
import XCTest
@testable import SonosWidget

final class RemoteArtworkImageLoaderTests: XCTestCase {
    func testCacheKeyNormalizesSchemeHostAndDropsFragment() {
        let url = URL(string: "HTTPS://Example.COM/artwork/cover.jpg#now-playing")!

        XCTAssertEqual(
            RemoteArtworkImageCacheKey.normalized(url),
            "https://example.com/artwork/cover.jpg")
    }

    func testLoaderUsesMemoryCacheForRepeatedURL() async throws {
        let probe = RemoteArtworkFetchProbe(data: Self.pngData)
        let loader = RemoteArtworkImageLoader(fetch: { request in
            try await probe.fetch(request)
        })
        let url = URL(string: "https://example.com/cover.jpg")!

        _ = try await loader.image(for: url)
        _ = try await loader.image(for: url)

        let requestCount = await probe.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testLoaderMergesConcurrentRequestsForSameURL() async throws {
        let probe = RemoteArtworkFetchProbe(data: Self.pngData, delayNanoseconds: 40_000_000)
        let loader = RemoteArtworkImageLoader(fetch: { request in
            try await probe.fetch(request)
        })
        let url = URL(string: "https://example.com/cover.jpg")!

        async let first = loader.image(for: url)
        async let second = loader.image(for: url)
        _ = try await (first, second)

        let requestCount = await probe.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testLoaderThrowsForNonSuccessHTTPStatus() async {
        let probe = RemoteArtworkFetchProbe(data: Self.pngData, statusCode: 404)
        let loader = RemoteArtworkImageLoader(fetch: { request in
            try await probe.fetch(request)
        })
        let url = URL(string: "https://example.com/missing.jpg")!

        do {
            _ = try await loader.image(for: url)
            XCTFail("Expected HTTP status failure")
        } catch RemoteArtworkImageLoaderError.httpStatus(let statusCode) {
            XCTAssertEqual(statusCode, 404)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoaderThrowsForInvalidImageData() async {
        let probe = RemoteArtworkFetchProbe(data: Data("not an image".utf8))
        let loader = RemoteArtworkImageLoader(fetch: { request in
            try await probe.fetch(request)
        })
        let url = URL(string: "https://example.com/bad.jpg")!

        do {
            _ = try await loader.image(for: url)
            XCTFail("Expected invalid image failure")
        } catch RemoteArtworkImageLoaderError.invalidImageData {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )!
}

private actor RemoteArtworkFetchProbe {
    private let data: Data
    private let statusCode: Int
    private let delayNanoseconds: UInt64
    private var count = 0

    init(data: Data, statusCode: Int = 200, delayNanoseconds: UInt64 = 0) {
        self.data = data
        self.statusCode = statusCode
        self.delayNanoseconds = delayNanoseconds
    }

    func requestCount() -> Int { count }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
