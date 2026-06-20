import Foundation

struct AppleMusicITunesArtworkClient {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = AppleMusicITunesArtworkClient()

    private struct LookupResponse: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let wrapperType: String?
        let kind: String?
        let trackName: String?
        let collectionName: String?
        let artistName: String?
        let artworkUrl30: String?
        let artworkUrl60: String?
        let artworkUrl100: String?
    }

    private let fetch: Fetch

    init(fetch: @escaping Fetch = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.fetch = fetch
    }

    func lookupArtworkURLString(
        catalogID: String,
        countryCode: String?
    ) async throws -> String? {
        let trimmedID = catalogID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              trimmedID.allSatisfy(\.isNumber) else {
            SonosLog.debug(
                .playbackLink,
                "iTunes artwork lookup skipped reason=non_numeric_catalog_id id=\(SonosLog.playbackLinkValue(catalogID, maxLength: 120))")
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        components.queryItems = [
            URLQueryItem(name: "id", value: trimmedID),
            URLQueryItem(name: "country", value: normalizedCountryCode(countryCode))
        ]
        guard let url = components.url else { return nil }

        SonosLog.debug(.playbackLink, "iTunes artwork lookup start id=\(trimmedID)")
        let response = try await decodedResponse(from: URLRequest(url: url))
        let urlString = response.results
            .compactMap { artworkURLString(from: $0) }
            .first
        SonosLog.debug(
            .playbackLink,
            "iTunes artwork lookup \(urlString == nil ? "miss" : "hit") id=\(trimmedID) " +
                "url=\(SonosLog.playbackLinkValue(urlString, maxLength: 240))")
        return urlString
    }

    func searchArtworkURLString(
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?,
        countryCode: String?
    ) async throws -> String? {
        guard let entity = iTunesEntity(for: kind) else {
            SonosLog.debug(.playbackLink, "iTunes artwork search skipped kind=\(kind)")
            return nil
        }
        let term = searchTerm(kind: kind, title: title, artist: artist, album: album)
        guard !term.isEmpty else {
            SonosLog.debug(.playbackLink, "iTunes artwork search skipped reason=empty_term")
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "country", value: normalizedCountryCode(countryCode))
        ]
        guard let url = components.url else { return nil }

        SonosLog.debug(
            .playbackLink,
            "iTunes artwork search start kind=\(kind) term='\(SonosLog.playbackLinkValue(term, maxLength: 160))'")
        let response = try await decodedResponse(from: URLRequest(url: url))
        let match = bestResult(
            in: response.results,
            kind: kind,
            title: title,
            artist: artist,
            album: album
        )
        let urlString = match.flatMap { artworkURLString(from: $0) }
        SonosLog.debug(
            .playbackLink,
            "iTunes artwork search \(urlString == nil ? "miss" : "hit") kind=\(kind) " +
                "url=\(SonosLog.playbackLinkValue(urlString, maxLength: 240))")
        return urlString
    }

    private func decodedResponse(from request: URLRequest) async throws -> LookupResponse {
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(LookupResponse.self, from: data)
    }

    private func artworkURLString(from result: Result) -> String? {
        let raw = result.artworkUrl100 ?? result.artworkUrl60 ?? result.artworkUrl30
        guard let raw else { return nil }
        let resized = raw.replacingOccurrences(
            of: #"/\d+x\d+bb(\.[a-z0-9]+)?$"#,
            with: "/600x600bb.jpg",
            options: [.regularExpression, .caseInsensitive]
        )
        return ArtworkURLNormalizer.loadableURLString(
            from: resized,
            preserveExistingAppleArtworkSize: true
        )
    }

    private func bestResult(
        in results: [Result],
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> Result? {
        results
            .filter { artworkURLString(from: $0) != nil }
            .max {
                score($0, kind: kind, title: title, artist: artist, album: album) <
                    score($1, kind: kind, title: title, artist: artist, album: album)
            }
    }

    private func score(
        _ result: Result,
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> Int {
        let titleTarget = normalized(title)
        let artistTarget = normalized(artist ?? "")
        let albumTarget = normalized(album ?? "")
        var score = 0

        switch kind {
        case .song:
            if normalized(result.trackName ?? "") == titleTarget { score += 4 }
            if !artistTarget.isEmpty, normalized(result.artistName ?? "") == artistTarget { score += 3 }
            if !albumTarget.isEmpty, normalized(result.collectionName ?? "") == albumTarget { score += 2 }
            if result.wrapperType?.lowercased() == "track" { score += 1 }
        case .album:
            if normalized(result.collectionName ?? result.trackName ?? "") == titleTarget { score += 4 }
            if !artistTarget.isEmpty, normalized(result.artistName ?? "") == artistTarget { score += 3 }
            if result.wrapperType?.lowercased() == "collection" { score += 1 }
        case .artist:
            if normalized(result.artistName ?? result.trackName ?? "") == titleTarget { score += 4 }
            if result.wrapperType?.lowercased() == "artist" { score += 1 }
        case .playlist, .station:
            break
        }

        return score
    }

    private func iTunesEntity(for kind: LocalServiceAppleMusicPlayable.Kind) -> String? {
        switch kind {
        case .song:
            return "song"
        case .album:
            return "album"
        case .artist:
            return "musicArtist"
        case .playlist, .station:
            return nil
        }
    }

    private func searchTerm(
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> String {
        let parts: [String?]
        switch kind {
        case .song:
            parts = [title, artist, album]
        case .album:
            parts = [title, artist]
        case .artist, .playlist, .station:
            parts = [title]
        }
        return parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func normalizedCountryCode(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (trimmed.isEmpty ? "US" : trimmed).uppercased()
    }

    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
