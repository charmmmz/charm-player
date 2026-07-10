import XCTest
@testable import SonosWidget

final class AppleMusicITunesArtworkClientTests: XCTestCase {
    func testLookupArtworkURLUsesCatalogIDAndUpsizesArtwork() async throws {
        var requestedURLs: [URL] = []
        let client = AppleMusicITunesArtworkClient { request in
            requestedURLs.append(try XCTUnwrap(request.url))
            return (
                Data(
                    """
                    {
                      "resultCount": 1,
                      "results": [
                        {
                          "wrapperType": "track",
                          "trackId": 1440857781,
                          "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/cover/100x100bb.jpg"
                        }
                      ]
                    }
                    """.utf8
                ),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let urlString = try await client.lookupArtworkURLString(
            catalogID: "1440857781",
            countryCode: "US"
        )

        XCTAssertEqual(
            urlString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/cover/600x600bb.jpg"
        )
        let requested = try XCTUnwrap(requestedURLs.first)
        XCTAssertEqual(requested.host, "itunes.apple.com")
        XCTAssertEqual(requested.path, "/lookup")
        let components = try XCTUnwrap(URLComponents(url: requested, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "id" })?.value, "1440857781")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "country" })?.value, "US")
    }

    func testLookupSkipsNonNumericCatalogIDWithoutFetching() async throws {
        var fetchCount = 0
        let client = AppleMusicITunesArtworkClient { request in
            fetchCount += 1
            return (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }

        let urlString = try await client.lookupArtworkURLString(
            catalogID: "pl.u-11zBXe4t8ZL1",
            countryCode: "US"
        )

        XCTAssertNil(urlString)
        XCTAssertEqual(fetchCount, 0)
    }

    func testSearchArtworkURLUsesSongEntityAndBestMatchingArtwork() async throws {
        var requestedURLs: [URL] = []
        let client = AppleMusicITunesArtworkClient { request in
            requestedURLs.append(try XCTUnwrap(request.url))
            return (
                Data(
                    """
                    {
                      "resultCount": 2,
                      "results": [
                        {
                          "wrapperType": "track",
                          "trackName": "Moon",
                          "artistName": "Different Artist",
                          "collectionName": "Other",
                          "artworkUrl100": "https://cdn.example.com/wrong/100x100bb.jpg"
                        },
                        {
                          "wrapperType": "track",
                          "trackName": "Moon",
                          "artistName": "Daniel Caesar",
                          "collectionName": "Freudian",
                          "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/moon/100x100bb.jpg"
                        }
                      ]
                    }
                    """.utf8
                ),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let urlString = try await client.searchArtworkURLString(
            kind: .song,
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            countryCode: "US"
        )

        XCTAssertEqual(
            urlString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/moon/600x600bb.jpg"
        )
        let requested = try XCTUnwrap(requestedURLs.first)
        XCTAssertEqual(requested.path, "/search")
        let components = try XCTUnwrap(URLComponents(url: requested, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "media" })?.value, "music")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "entity" })?.value, "song")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "5")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "country" })?.value, "US")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "term" })?.value,
            "Moon Daniel Caesar Freudian"
        )
    }

    func testSearchSongCatalogIDUsesBestMatchingTrackIDWithoutRequiringArtwork() async throws {
        var requestedURLs: [URL] = []
        let client = AppleMusicITunesArtworkClient { request in
            requestedURLs.append(try XCTUnwrap(request.url))
            return (
                Data(
                    """
                    {
                      "resultCount": 2,
                      "results": [
                        {
                          "wrapperType": "track",
                          "trackId": 111,
                          "trackName": "Neon",
                          "artistName": "Different Artist",
                          "collectionName": "Other"
                        },
                        {
                          "wrapperType": "track",
                          "trackId": 1440857781,
                          "trackName": "Neon",
                          "artistName": "John Mayer",
                          "collectionName": "Where the Light Is"
                        }
                      ]
                    }
                    """.utf8
                ),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let catalogID = try await client.searchSongCatalogID(
            title: "Neon",
            artist: "John Mayer",
            album: "Where the Light Is",
            countryCode: "US"
        )

        XCTAssertEqual(catalogID, "1440857781")
        let requested = try XCTUnwrap(requestedURLs.first)
        let components = try XCTUnwrap(URLComponents(url: requested, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "entity" })?.value, "song")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "term" })?.value,
            "Neon John Mayer Where the Light Is"
        )
    }
}
