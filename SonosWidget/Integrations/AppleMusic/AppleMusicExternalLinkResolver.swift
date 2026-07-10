import Foundation

enum AppleMusicExternalLinkResolver {
    static func currentTrackResource(
        trackURI: String?,
        nowPlayingObjectID: String?
    ) -> AppleMusicFavoriteResource? {
        let storeID = SonosAppleMusicTrackResolver.storeID(fromObjectID: nowPlayingObjectID)
            ?? SonosAppleMusicTrackResolver.storeID(fromTrackURI: trackURI)

        guard let storeID, !storeID.isEmpty else { return nil }
        return AppleMusicFavoriteResource(id: storeID, type: .songs)
    }

    static func resource(from item: BrowseItem) -> AppleMusicFavoriteResource? {
        AppleMusicFavoriteResource.fromBrowseItem(item)
    }

    @MainActor
    static func appleMusicResource(
        from item: BrowseItem,
        searchManager: SearchManager
    ) -> AppleMusicFavoriteResource? {
        guard isAppleMusicItem(item, searchManager: searchManager) else { return nil }
        return resource(from: item)
    }

    static func appleMusicURL(for resource: AppleMusicFavoriteResource) async throws -> URL? {
        let kind = AppleMusicExternalResourceKind(resource.type)
        guard let urlString = try await AppleMusicCatalogSearchClient.shared.appleMusicURLString(
            kind: kind,
            catalogID: resource.id
        ) else {
            return nil
        }
        return URL(string: urlString)
    }

    @MainActor
    static func isAppleMusicItem(
        _ item: BrowseItem,
        searchManager: SearchManager
    ) -> Bool {
        guard AppleMusicFavoriteResourceType(cloudType: item.cloudType) != nil else {
            return false
        }

        if let cloudId = searchManager.cloudServiceId(forFavorite: item),
           let account = searchManager.linkedAccounts.first(where: { $0.serviceId == cloudId }) {
            return isAppleMusicAccount(account)
        }

        if let hint = searchManager.serviceDisplayHint(forFavorite: item),
           PlaybackSource.from(serviceName: hint) == .appleMusic {
            return true
        }

        if let localSid = item.serviceId,
           let service = searchManager.musicServices.first(where: { $0.id == localSid }),
           PlaybackSource.from(serviceName: service.name) == .appleMusic {
            return true
        }

        if let localSid = item.serviceId,
           PlaybackSource.from(serviceName: SharedStorage.serviceNamesByLocalSid[String(localSid)]) == .appleMusic {
            return true
        }

        if let uri = item.playbackDescriptor.directURI,
           PlaybackSource.from(trackURI: uri) == .appleMusic {
            return true
        }

        return containsAppleMusicServiceName(item.resMD)
            || containsAppleMusicServiceName(item.metaXML)
    }

    private static func isAppleMusicAccount(_ account: SonosCloudAPI.CloudMusicServiceAccount) -> Bool {
        [
            account.displayName,
            account.name,
            account.nickname,
            account.integrationId,
            account.username
        ].contains { containsAppleMusicServiceName($0) }
    }

    private static func containsAppleMusicServiceName(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        return normalized.contains("apple music") || normalized.contains("applemusic")
    }
}

struct AppleMusicExternalLinkFallbackResolver: Sendable {
    typealias CatalogURLLookup = @Sendable (
        _ kind: AppleMusicExternalResourceKind,
        _ catalogID: String
    ) async throws -> String?
    typealias CatalogSearch = @Sendable (_ term: String, _ limit: Int) async throws -> [AppleMusicCatalogSearchItem]

    private let catalogURLLookup: CatalogURLLookup
    private let catalogSearch: CatalogSearch
    private let searchLimit: Int

    init(
        catalogURLLookup: @escaping CatalogURLLookup = { kind, catalogID in
            try await AppleMusicCatalogSearchClient.shared.appleMusicURLString(
                kind: kind,
                catalogID: catalogID
            )
        },
        catalogSearch: @escaping CatalogSearch = { term, limit in
            try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: limit)
        },
        searchLimit: Int = 8
    ) {
        self.catalogURLLookup = catalogURLLookup
        self.catalogSearch = catalogSearch
        self.searchLimit = AppleMusicCatalogSearchClient.effectiveSearchLimit(requested: searchLimit)
    }

    func songURL(
        directResource: AppleMusicFavoriteResource?,
        title: String,
        artist: String?,
        album: String?
    ) async throws -> URL? {
        try await url(
            externalKind: .song,
            catalogKind: .song,
            directResource: directResource,
            title: title,
            artist: artist,
            album: album
        )
    }

    func albumURL(
        directResource: AppleMusicFavoriteResource?,
        title: String,
        artist: String?
    ) async throws -> URL? {
        try await url(
            externalKind: .album,
            catalogKind: .album,
            directResource: directResource,
            title: title,
            artist: artist,
            album: title
        )
    }

    private func url(
        externalKind: AppleMusicExternalResourceKind,
        catalogKind: LocalServiceAppleMusicPlayable.Kind,
        directResource: AppleMusicFavoriteResource?,
        title: String,
        artist: String?,
        album: String?
    ) async throws -> URL? {
        if let directResource,
           AppleMusicExternalResourceKind(directResource.type) == externalKind {
            do {
                if let directURLString = try await catalogURLLookup(externalKind, directResource.id),
                   let directURL = URL(string: directURLString) {
                    return directURL
                }
            } catch {
                SonosLog.debug(
                    .nowPlaying,
                    "Apple Music external direct URL lookup failed id='\(directResource.id)' kind='\(externalKind)' error=\(error)"
                )
            }
        }

        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: catalogKind,
            title: title,
            artist: artist,
            album: album
        )
        guard !term.isEmpty else { return nil }

        let items = try await catalogSearch(term, searchLimit)
        let urlString = LocalMusicCatalogWebURLFallback.urlString(
            in: items,
            kind: catalogKind,
            title: title,
            artist: artist,
            album: album
        )
        return urlString.flatMap(URL.init(string:))
    }
}
