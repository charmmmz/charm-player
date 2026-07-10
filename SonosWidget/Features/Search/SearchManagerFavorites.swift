import Foundation
import SwiftUI

extension SearchManager {

    func addToFavorites(item: BrowseItem, manager: SonosManager) async -> Bool {
        // Sonos Cloud Control API has no endpoint to CREATE a favorite —
        // only UPnP CreateObject does that. Surface a clear message rather
        // than letting the SOAP request time out silently.
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Adding Sonos Favorites")
                .localizedDescription
            return false
        }
        guard let ip = manager.selectedSpeaker?.playbackIP else { return false }
        guard let resolved = browseItemWithResolvedFavoriteURI(item) else { return false }
        guard let uri = resolved.playbackDescriptor.directURI else { return false }
        // Fresh inner DIDL from `resolved` avoids reusing a stale `r:resMD`
        // on an in-memory `BrowseItem` after remove → re-add.
        let meta = innerDIDLForFavoriteCreate(resolved: resolved)
        // Dispatch the correct outer-DIDL shape from `resolved` (not the
        // pre-resolution `item`) so ARTIST stays `shortcut` + empty <res>.
        let type = resolved.cloudType.flatMap { CloudObjectType(rawValue: $0) }
        let rType = type?.favoriteRType ?? "instantPlay"
        let emitRes = type?.emitsFavoriteRes ?? true
        let description: String = (type?.emitsFavoriteRes ?? true)
            ? resolved.title
            : (serviceDisplayName(for: resolved) ?? "Apple Music")

        do {
            try await SonosAPI.addToFavorites(
                ip: ip, title: resolved.title, uri: uri, metadata: meta,
                albumArtURI: resolved.includeAlbumArtInCloudMetadata ? resolved.albumArtURL : nil,
                rType: rType, description: description, emitRes: emitRes)
            SonosLog.info(.favorites, "Added '\(resolved.title)' to Sonos Favorites")
            try? await Task.sleep(for: .milliseconds(500))
            await refreshFavorites(ip: ip)
            return true
        } catch {
            SonosLog.error(.favorites, "Failed to add: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Inner `r:resMD` for `ContentDirectory#CreateObject`. For cloud-typed
    /// items, always build from the resolved row so it matches a fresh add
    /// from the factory. Otherwise fall back to stored `r:resMD` / generic
    /// builders (legacy UPnP-only items).
    func innerDIDLForFavoriteCreate(resolved: BrowseItem) -> String {
        if let ct = resolved.cloudType, !ct.isEmpty, let sid = resolved.serviceId {
            let accountId = accountIdForLocalSid(sid) ?? "0"
            return buildCloudDIDLMetadata(
                item: resolved, localSid: sid, accountId: accountId)
        }
        if let r = resolved.resMD, !r.isEmpty, resolved.cloudType == nil {
            return r
        }
        return playbackMetadata(for: resolved)
    }

    /// Display name of the music service a BrowseItem belongs to (e.g.
    /// "Apple Music", "Spotify") — used as `<r:description>` for shortcut-
    /// type favorites like artists. Returns nil if the service isn't linked.
    func serviceDisplayName(for item: BrowseItem) -> String? {
        guard let localSid = item.serviceId else { return nil }
        return musicServices.first { $0.id == localSid }?.name
    }

    func removeFromFavorites(item: BrowseItem, manager: SonosManager) async -> Bool {
        // Cloud API has no "destroy favorite" endpoint — same UPnP-only
        // constraint as `addToFavorites`.
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Removing Sonos Favorites")
                .localizedDescription
            return false
        }
        guard let ip = manager.selectedSpeaker?.playbackIP else { return false }
        guard let favItem = findFavorite(matching: item) else {
            SonosLog.info(.favorites, "Item '\(item.title)' not found in favorites")
            return false
        }
        do {
            try await SonosAPI.removeFromFavorites(ip: ip, objectId: favItem.id)
            SonosLog.info(.favorites, "Removed '\(item.title)' from Sonos Favorites")
            await refreshFavorites(ip: ip)
            return true
        } catch {
            SonosLog.error(.favorites, "Failed to remove: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Check if an item is already in Sonos Favorites by matching URI or
    /// title, scoped to the same streaming service. The user can favorite
    /// "Taylor Swift" from Apple Music and Spotify as two separate
    /// entries, and we must not conflate them.
    func isFavorited(_ item: BrowseItem) -> Bool {
        findFavorite(matching: item) != nil
    }

    func appleMusicFavoriteResource(for item: BrowseItem) -> AppleMusicFavoriteResource? {
        guard isAppleMusicItem(item) else { return nil }
        let resolved = browseItemWithResolvedFavoriteURI(item) ?? item
        return AppleMusicFavoriteResource.fromBrowseItem(resolved)
    }

    func appleMusicFavoriteStatus(for resource: AppleMusicFavoriteResource) async throws -> Bool {
        try await AppleMusicFavoritesClient.shared.favoriteStatus(for: resource)
    }

    func addToAppleMusicFavorites(resource: AppleMusicFavoriteResource) async throws {
        try await AppleMusicFavoritesClient.shared.addToFavorites(resource)
    }

    func removeFromAppleMusicFavorites(resource: AppleMusicFavoriteResource) async throws {
        try await AppleMusicFavoritesClient.shared.removeFromFavorites(resource)
    }

    func toggleAppleMusicFavorites(resource: AppleMusicFavoriteResource) async -> Bool {
        do {
            let isFavorited = (try? await appleMusicFavoriteStatus(for: resource)) ?? false
            if isFavorited {
                try await removeFromAppleMusicFavorites(resource: resource)
            } else {
                try await addToAppleMusicFavorites(resource: resource)
            }
            SonosLog.info(
                .favorites,
                "Apple Music Favorites updated resource='\(resource.id)' isFavorited=\(!isFavorited)")
            return true
        } catch {
            SonosLog.error(.favorites, "Apple Music Favorites update failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleAppleMusicFavorites(for item: BrowseItem) async -> Bool {
        guard let resource = appleMusicFavoriteResource(for: item) else {
            SonosLog.info(.favorites, "Apple Music Favorites unavailable for '\(item.title)'")
            return false
        }
        return await toggleAppleMusicFavorites(resource: resource)
    }

    func isAppleMusicItem(_ item: BrowseItem) -> Bool {
        guard AppleMusicFavoriteResourceType(cloudType: item.cloudType) != nil else {
            return false
        }

        if let cloudId = cloudServiceId(forFavorite: item),
           let account = linkedAccounts.first(where: { $0.serviceId == cloudId }) {
            return isAppleMusicAccount(account)
        }

        if let hint = serviceDisplayHint(forFavorite: item),
           PlaybackSource.from(serviceName: hint) == .appleMusic {
            return true
        }

        if let localSid = item.serviceId,
           let service = musicServices.first(where: { $0.id == localSid }) {
            return PlaybackSource.from(serviceName: service.name) == .appleMusic
        }

        return false
    }

    func isAppleMusicPlaybackArtworkItem(_ item: BrowseItem) -> Bool {
        if isAppleMusicItem(item) { return true }
        if let uri = item.uri,
           PlaybackSource.from(trackURI: uri) == .appleMusic {
            return true
        }
        if let serviceId = item.serviceId,
           let service = musicServices.first(where: { $0.id == serviceId }),
           PlaybackSource.from(serviceName: service.name) == .appleMusic {
            return true
        }
        return false
    }

    func findFavorite(matching item: BrowseItem) -> BrowseItem? {
        favoriteMatcher.favorite(matching: item, in: favorites)
    }

    func refreshFavorites(ip: String) async {
        do {
            let items = try await SonosAPI.browseFavorites(ip: ip)
            SonosLog.info(.favorites, "Refresh: \(items.count) items loaded")
            favorites = items
        } catch {
            SonosLog.error(.favorites, "Refresh failed: \(error)")
        }
    }
}
