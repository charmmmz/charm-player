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
    private static func isAppleMusicItem(
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
