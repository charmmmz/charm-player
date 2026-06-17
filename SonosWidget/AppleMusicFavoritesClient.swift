import Foundation
import MusicKit

enum AppleMusicFavoriteResourceType: String, Codable, Equatable, Sendable {
    case songs
    case albums
    case artists
    case playlists

    init?(cloudType: String?) {
        switch cloudType {
        case "TRACK": self = .songs
        case "ALBUM": self = .albums
        case "ARTIST": self = .artists
        case "PLAYLIST": self = .playlists
        default: return nil
        }
    }

    var objectNamespaces: Set<String> {
        switch self {
        case .songs: return ["song", "songs", "track", "tracks"]
        case .albums: return ["album", "albums"]
        case .artists: return ["artist", "artists"]
        case .playlists: return ["playlist", "playlists"]
        }
    }

    var sonosDIDLObjectPrefixes: [String] {
        switch self {
        case .songs: return ["10032020", "10032064", "1003206c"]
        case .albums: return ["1004206c"]
        case .artists: return ["10052064"]
        case .playlists: return ["1006206c"]
        }
    }
}

struct AppleMusicFavoriteResource: Codable, Equatable, Sendable {
    let id: String
    let type: AppleMusicFavoriteResourceType

    static func fromLocalServicePlayable(_ playable: LocalServiceAppleMusicPlayable?) -> AppleMusicFavoriteResource? {
        guard let playable else { return nil }

        let type: AppleMusicFavoriteResourceType
        let catalogID: String?

        switch playable.kind {
        case .song:
            type = .songs
            catalogID = SonosAppleMusicTrackResolver.storeID(fromObjectID: playable.catalogID)
        case .album:
            type = .albums
            catalogID = LocalMusicAppleMusicURL.publicCatalogID(from: playable.catalogID, kind: .album)
        case .artist:
            type = .artists
            catalogID = LocalMusicAppleMusicURL.publicCatalogID(from: playable.catalogID, kind: .artist)
        case .playlist:
            type = .playlists
            catalogID = LocalMusicAppleMusicURL.publicCatalogID(from: playable.catalogID, kind: .playlist)
        case .station:
            return nil
        }

        guard let catalogID, !catalogID.isEmpty else { return nil }
        return AppleMusicFavoriteResource(id: catalogID, type: type)
    }

    static func fromBrowseItem(_ item: BrowseItem) -> AppleMusicFavoriteResource? {
        guard let type = AppleMusicFavoriteResourceType(cloudType: item.cloudType) else {
            return nil
        }

        let catalogID: String?
        switch type {
        case .songs:
            catalogID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: item)
        case .albums, .artists, .playlists:
            catalogID = normalizedCatalogID(
                candidates: [item.id, objectIDFromURI(item.uri)],
                type: type)
        }

        guard let catalogID, !catalogID.isEmpty else { return nil }
        return AppleMusicFavoriteResource(id: catalogID, type: type)
    }

    private static func normalizedCatalogID(
        candidates: [String?],
        type: AppleMusicFavoriteResourceType
    ) -> String? {
        for candidate in candidates {
            guard var value = trimmed(candidate) else { continue }
            value = value.removingPercentEncoding ?? value
            value = stripKnownDIDLObjectPrefix(from: value, type: type)
            if let namespaced = catalogIDFromNamespacedObjectID(value, type: type) {
                return namespaced
            }
            if isBareCatalogID(value) { return value }
        }
        return nil
    }

    private static func objectIDFromURI(_ uri: String?) -> String? {
        guard let uri = trimmed(uri) else { return nil }
        let pathPart = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        guard let colon = pathPart.firstIndex(of: ":") else { return pathPart }
        return String(pathPart[pathPart.index(after: colon)...])
    }

    private static func stripKnownDIDLObjectPrefix(
        from value: String,
        type: AppleMusicFavoriteResourceType
    ) -> String {
        let lowercased = value.lowercased()
        for prefix in type.sonosDIDLObjectPrefixes where lowercased.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    private static func catalogIDFromNamespacedObjectID(
        _ objectID: String,
        type: AppleMusicFavoriteResourceType
    ) -> String? {
        let parts = objectID.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2,
              let namespace = parts.dropLast().last?.lowercased(),
              type.objectNamespaces.contains(namespace) else {
            return nil
        }
        let suffix = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return suffix.isEmpty ? nil : suffix
    }

    private static func isBareCatalogID(_ value: String) -> Bool {
        value.allSatisfy(\.isNumber) || value.hasPrefix("pl.")
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AppleMusicFavoritesError: LocalizedError, Equatable {
    case authorizationDenied
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Apple Music access is not allowed."
        case .invalidResponse:
            return "Apple Music favorite status could not be read."
        }
    }
}

struct AppleMusicFavoritesClient: Sendable {
    static let shared = AppleMusicFavoritesClient()

    static func catalogURL(
        storefront: String,
        resource: AppleMusicFavoriteResource
    ) -> URL {
        URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/\(resource.type.rawValue)/\(resource.id)")!
    }

    static var favoritesURL: URL {
        URL(string: "https://api.music.apple.com/v1/me/favorites")!
    }

    static func addFavoritesRequest(for resource: AppleMusicFavoriteResource) throws -> URLRequest {
        try favoritesRequest(for: resource, method: "POST")
    }

    static func removeFavoritesRequest(for resource: AppleMusicFavoriteResource) throws -> URLRequest {
        try favoritesRequest(for: resource, method: "DELETE")
    }

    func favoriteStatus(for resource: AppleMusicFavoriteResource) async throws -> Bool {
        try await ensureAuthorized()
        let storefront = try await MusicDataRequest.currentCountryCode
        let urlRequest = URLRequest(url: Self.catalogURL(storefront: storefront, resource: resource))
        let response = try await MusicDataRequest(urlRequest: urlRequest).response()
        let decoded = try JSONDecoder().decode(AppleMusicFavoriteLookupResponse.self, from: response.data)
        guard let status = decoded.data.first?.attributes?.inFavorites else {
            throw AppleMusicFavoritesError.invalidResponse
        }
        return status
    }

    func addToFavorites(_ resource: AppleMusicFavoriteResource) async throws {
        try await ensureAuthorized()
        let request = try Self.addFavoritesRequest(for: resource)

        let response = try await MusicDataRequest(urlRequest: request).response()
        guard (200...299).contains(response.urlResponse.statusCode) else {
            throw AppleMusicFavoritesError.invalidResponse
        }
    }

    func removeFromFavorites(_ resource: AppleMusicFavoriteResource) async throws {
        try await ensureAuthorized()
        let request = try Self.removeFavoritesRequest(for: resource)

        let response = try await MusicDataRequest(urlRequest: request).response()
        guard (200...299).contains(response.urlResponse.statusCode) else {
            throw AppleMusicFavoritesError.invalidResponse
        }
    }

    private func ensureAuthorized() async throws {
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            throw AppleMusicFavoritesError.authorizationDenied
        }
    }

    private static func favoritesRequest(
        for resource: AppleMusicFavoriteResource,
        method: String
    ) throws -> URLRequest {
        guard var components = URLComponents(url: favoritesURL, resolvingAgainstBaseURL: false) else {
            throw AppleMusicFavoritesError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "ids[\(resource.type.rawValue)]", value: resource.id)
        ]
        guard let url = components.url else {
            throw AppleMusicFavoritesError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }
}

private struct AppleMusicFavoriteLookupResponse: Decodable {
    struct Resource: Decodable {
        struct Attributes: Decodable {
            let inFavorites: Bool?
        }

        let attributes: Attributes?
    }

    let data: [Resource]
}
