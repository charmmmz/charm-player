import Foundation
import SwiftUI

extension SearchManager {

    // MARK: - Service Detection

    func probeLinkedServices() async {
        guard !hasProbed else { return }
        await ensureMusicServicesPopulated()

        if !linkedAccounts.isEmpty {
            SonosLog.debug(.search, "Using \(linkedAccounts.count) cached linked accounts")
            buildServiceIdMapping()
            hasProbed = true
            return
        }

        await fetchLinkedAccounts()
    }

    /// Opportunistically fetch the UPnP `ListAvailableServices` catalog when
    /// we have a reachable LAN IP. This is metadata only: service-name
    /// snapshots, local sid mapping, manifest URLs, and presentation maps.
    /// Linked account discovery and streaming search remain Sonos Cloud-only.
    func ensureMusicServicesPopulated() async {
        guard let ip = speakerIP,
              !ip.isEmpty else { return }
        if musicServices.isEmpty,
           let fetched = try? await SonosAPI.listMusicServices(ip: ip), !fetched.isEmpty {
            musicServices = fetched
            snapshotLocalServiceNames()
            SonosLog.debug(.search, "Fetched \(fetched.count) local music services")
        }
        buildServiceIdMapping()
    }

    /// Network call to refresh linked accounts. Called on first launch or manual refresh.
    func fetchLinkedAccounts() async {
        isProbing = true
        await ensureMusicServicesPopulated()

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            SonosLog.info(.search, "No Sonos Cloud auth; music service discovery/search unavailable")
            isProbing = false
            hasProbed = true
            return
        }

        do {
            let accounts = try await musicServiceAccountsWithTokenRefresh(
                token: token, householdId: householdId)
            linkedAccounts = accounts
            persistAccounts(accounts)
            SonosLog.info(.search, "Cloud API detected \(accounts.count) linked services")
            for a in accounts {
                SonosLog.debug(.search, "  \(a.nickname ?? a.serviceId ?? "?") (service-id=\(a.serviceId ?? "?"))")
            }

            let saved = UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:]
            for account in accounts {
                guard let sid = account.serviceId else { continue }
                serviceEnabled[sid] = saved[sid] ?? true
            }
        } catch {
            SonosLog.error(.search, "Cloud API detection failed: \(error)")
            errorMessage = error.localizedDescription
        }

        await ensureMusicServicesPopulated()
        buildServiceIdMapping()
        hasProbed = true
        isProbing = false
    }

    func persistToggles() {
        UserDefaults.standard.set(serviceEnabled, forKey: Self.enabledKey)
    }

    func persistAccounts(_ accounts: [SonosCloudAPI.CloudMusicServiceAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.cachedAccountsKey)
        }
    }

    func restoreCachedAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedAccountsKey),
              let accounts = try? JSONDecoder().decode([SonosCloudAPI.CloudMusicServiceAccount].self, from: data),
              !accounts.isEmpty else { return }

        linkedAccounts = accounts
        let saved = UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:]
        for account in accounts {
            guard let sid = account.serviceId else { continue }
            serviceEnabled[sid] = saved[sid] ?? true
        }
        SonosLog.debug(.search, "Restored \(accounts.count) cached linked accounts")
    }

    // MARK: - Recently Played

    /// Record that the user just started playing this item. Moves the item
    /// to the front of `recentlyPlayed` (deduping), caps the list length,
    /// and persists it so the Browse page has history on next launch.
    func pushRecentlyPlayed(_ item: BrowseItem) {
        // Skip items with no id/title — placeholders / partial containers.
        guard !item.id.isEmpty, !item.title.isEmpty else { return }

        // Dedupe by id; also by title+artist as a fallback for radio stations
        // that get freshly constructed ids each playback session.
        recentlyPlayed.removeAll { existing in
            existing.id == item.id ||
            (existing.title == item.title && existing.artist == item.artist)
        }
        recentlyPlayed.insert(item, at: 0)
        if recentlyPlayed.count > Self.recentlyPlayedLimit {
            recentlyPlayed = Array(recentlyPlayed.prefix(Self.recentlyPlayedLimit))
        }
        persistRecentlyPlayed()
    }

    func persistRecentlyPlayed() {
        SharedStorage.recentlyPlayedItems = recentlyPlayed
    }

    func restoreRecentlyPlayed() {
        let sharedItems = SharedStorage.recentlyPlayedItems
        if !sharedItems.isEmpty {
            recentlyPlayed = sharedItems
            return
        }

        guard let data = UserDefaults.standard.data(forKey: Self.recentlyPlayedKey),
              let items = try? JSONDecoder().decode([BrowseItem].self, from: data),
              !items.isEmpty else { return }
        recentlyPlayed = items
        SharedStorage.recentlyPlayedItems = items
        UserDefaults.standard.removeObject(forKey: Self.recentlyPlayedKey)
    }

    func scheduleLocalServicePlaylistRecentlyPlayedAfterArtworkLookup(_ item: BrowseItem) {
        Task { [weak self] in
            _ = await self?.recordLocalServicePlaylistRecentlyPlayedAfterArtworkLookup(item)
        }
    }

    @discardableResult
    func recordLocalServicePlaylistRecentlyPlayedAfterArtworkLookup(_ item: BrowseItem) async -> Bool {
        guard item.cloudType == "PLAYLIST" else { return false }
        let artworkURLString = await localServicePlaylistArtworkURLString(for: item)
        return recordLocalServicePlaylistRecentlyPlayed(
            item,
            sonosArtworkURLString: artworkURLString)
    }

    @discardableResult
    func recordLocalServicePlaylistRecentlyPlayed(
        _ item: BrowseItem,
        sonosArtworkURLString: String?
    ) -> Bool {
        guard let artworkURLString = normalizedSonosPlaylistArtworkURLString(sonosArtworkURLString) else {
            SonosLog.debug(
                .search,
                "LocalService playlist recently played skipped title='\(item.title)' reason=no-sonos-tile")
            return false
        }

        var enrichedItem = item
        enrichedItem.albumArtURL = artworkURLString
        enrichedItem.detailArtworkURL = artworkURLString
        pushRecentlyPlayed(enrichedItem)
        SonosLog.debug(
            .search,
            "LocalService playlist recently played recorded title='\(item.title)' " +
                "artwork=\(SonosLog.playbackLinkValue(artworkURLString, maxLength: 240))")
        return true
    }

    func localServicePlaylistArtworkURLString(for item: BrowseItem) async -> String? {
        if let localServicePlaylistArtworkLookupOverride {
            return await localServicePlaylistArtworkLookupOverride(item)
        }
        return await sonosCloudPlaylistArtworkURLString(for: item)
    }

    func sonosCloudPlaylistArtworkURLString(for item: BrowseItem) async -> String? {
        guard let ids = parseCloudIds(from: item) else { return nil }
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            return nil
        }

        do {
            let response = try await SonosCloudAPI.browsePlaylist(
                token: token,
                householdId: householdId,
                serviceId: ids.cloudServiceId,
                accountId: ids.accountId,
                playlistId: ids.objectId,
                count: 1)
            return response.images?.tile1x1
        } catch SonosCloudError.httpError(let code) where (500...599).contains(code) {
            do {
                let response = try await SonosCloudAPI.browseContainer(
                    token: token,
                    householdId: householdId,
                    serviceId: ids.cloudServiceId,
                    accountId: ids.accountId,
                    containerId: ids.objectId,
                    count: 1)
                return response.images?.tile1x1
            } catch {
                SonosLog.debug(
                    .search,
                    "LocalService playlist Sonos artwork container fallback failed " +
                        "title='\(item.title)' error=\(error)")
                return nil
            }
        } catch {
            SonosLog.debug(
                .search,
                "LocalService playlist Sonos artwork lookup failed title='\(item.title)' error=\(error)")
            return nil
        }
    }

    func normalizedSonosPlaylistArtworkURLString(_ value: String?) -> String? {
        ArtworkURLNormalizer.loadableURLString(
            from: value,
            preserveExistingAppleArtworkSize: true)
    }

    func prewarmPlaybackArtwork(items: [BrowseItem]) async {
        if PlaybackArtworkCachingPolicy.isRegistryEnabled {
            PlaybackArtworkRegistry.shared.register(items: items)
        }
        if PlaybackArtworkCachingPolicy.isPlaybackURLCacheEnabled {
            let appleMusicItems = items.filter(isAppleMusicPlaybackArtworkItem)
            if !appleMusicItems.isEmpty {
                PlaybackArtworkURLCache.shared.register(
                    items: appleMusicItems,
                    service: .appleMusic,
                    source: .sonosCloud
                )
            }
        }
        if PlaybackArtworkCachingPolicy.isArtworkHintsEnabled {
            submitArtworkHintsToRelay(items)
        }
        guard PlaybackArtworkCachingPolicy.isPrewarmEnabled else {
            SonosLog.debug(
                .playbackLink,
                "Playback artwork prewarm skipped reason=cache_disabled registry=\(PlaybackArtworkCachingPolicy.isRegistryEnabled) " +
                    "urlCache=\(PlaybackArtworkCachingPolicy.isPlaybackURLCacheEnabled) " +
                    "hints=\(PlaybackArtworkCachingPolicy.isArtworkHintsEnabled) items=\(items.count)")
            return
        }
        await prewarmPlaybackArtwork(
            urls: PlaybackArtworkPrewarmPolicy.urls(from: items)
        )
    }

    func submitArtworkHintsToRelay(_ items: [BrowseItem]) {
        guard !items.isEmpty else { return }
        let itemSnapshot = items
        Task { @MainActor in
            RelayManager.shared.submitArtworkHints(itemSnapshot)
        }
    }

    func schedulePlaybackArtworkPrewarm(
        for item: BrowseItem,
        includeContainerTracks: Bool = true
    ) {
        guard PlaybackArtworkCachingPolicy.isPrewarmEnabled
                || PlaybackArtworkCachingPolicy.isRegistryEnabled
                || PlaybackArtworkCachingPolicy.isPlaybackURLCacheEnabled
                || PlaybackArtworkCachingPolicy.isArtworkHintsEnabled else { return }
        let itemSnapshot = item
        Task { [weak self] in
            guard let self else { return }
            await self.prewarmPlaybackArtwork(items: [itemSnapshot])
            guard includeContainerTracks else { return }
            await self.prewarmContainerPlaybackArtwork(for: itemSnapshot)
        }
    }

    func schedulePlaybackArtworkPrewarm(for items: [BrowseItem]) {
        guard PlaybackArtworkCachingPolicy.isPrewarmEnabled
                || PlaybackArtworkCachingPolicy.isRegistryEnabled
                || PlaybackArtworkCachingPolicy.isPlaybackURLCacheEnabled
                || PlaybackArtworkCachingPolicy.isArtworkHintsEnabled else { return }
        let itemSnapshot = items
        Task { [weak self] in
            await self?.prewarmPlaybackArtwork(items: itemSnapshot)
        }
    }

    func prewarmPlaybackArtwork(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        if let playbackArtworkPrewarmOverride {
            await playbackArtworkPrewarmOverride(urls)
        } else {
            await RemoteArtworkImageLoader.shared.prefetch(urls: urls)
        }
        SonosLog.debug(
            .playbackLink,
            "Playback artwork prewarm urls=\(urls.count) " +
                "first=\(SonosLog.playbackLinkValue(urls.first?.absoluteString, maxLength: 240))")
    }

    func prewarmContainerPlaybackArtwork(for item: BrowseItem) async {
        guard PlaybackArtworkCachingPolicy.isPrewarmEnabled else { return }
        guard item.isContainer else { return }
        guard ["ALBUM", "PLAYLIST", "COLLECTION"].contains(item.cloudType ?? "") else { return }
        guard let ids = parseCloudIds(from: item),
              let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            return
        }

        do {
            let response: SonosCloudAPI.AlbumBrowseResponse
            switch item.cloudType {
            case "ALBUM":
                response = try await SonosCloudAPI.browseAlbum(
                    token: token,
                    householdId: householdId,
                    serviceId: ids.cloudServiceId,
                    accountId: ids.accountId,
                    albumId: ids.objectId,
                    count: PlaybackArtworkPrewarmPolicy.defaultLimit)
            case "COLLECTION":
                response = try await SonosCloudAPI.browseContainer(
                    token: token,
                    householdId: householdId,
                    serviceId: ids.cloudServiceId,
                    accountId: ids.accountId,
                    containerId: ids.objectId,
                    count: PlaybackArtworkPrewarmPolicy.defaultLimit)
            default:
                response = try await SonosCloudAPI.browsePlaylist(
                    token: token,
                    householdId: householdId,
                    serviceId: ids.cloudServiceId,
                    accountId: ids.accountId,
                    playlistId: ids.objectId,
                    count: PlaybackArtworkPrewarmPolicy.defaultLimit)
            }

            let tracks = response.tracks?.items ?? response.section?.items ?? []
            let trackItems = tracks.map {
                makeAlbumTrackItem(
                    from: $0,
                    fallbackAlbumTitle: item.title,
                    fallbackArtist: item.artist,
                    fallbackArtURL: item.thumbnailArtworkURL,
                    fallbackServiceId: ids.cloudServiceId,
                    fallbackAccountId: ids.accountId)
            }
            PlaybackArtworkRegistry.shared.register(items: trackItems)
            let appleMusicTrackItems = trackItems.filter(isAppleMusicPlaybackArtworkItem)
            if !appleMusicTrackItems.isEmpty {
                PlaybackArtworkURLCache.shared.register(
                    items: appleMusicTrackItems,
                    service: .appleMusic,
                    source: .sonosCloud
                )
            }
            if PlaybackArtworkCachingPolicy.isArtworkHintsEnabled {
                submitArtworkHintsToRelay(trackItems)
            }
            let urls = PlaybackArtworkPrewarmPolicy.urls(
                from: trackItems,
                limit: PlaybackArtworkPrewarmPolicy.defaultLimit)
            await prewarmPlaybackArtwork(urls: urls)
            SonosLog.debug(
                .playbackLink,
                "Playback container artwork prewarm title='\(item.title)' " +
                    "cloudType=\(item.cloudType ?? "nil") tracks=\(tracks.count) urls=\(urls.count)")
        } catch {
            SonosLog.debug(
                .playbackLink,
                "Playback container artwork prewarm skipped title='\(item.title)' " +
                    "cloudType=\(item.cloudType ?? "nil") error=\(error)")
        }
    }

    func setServiceEnabled(serviceId: String, enabled: Bool) {
        serviceEnabled[serviceId] = enabled
        persistToggles()
    }

    /// Service IDs enabled for search.
    var activeServiceIds: [String] {
        linkedAccounts.compactMap { account in
            guard let sid = account.serviceId,
                  serviceEnabled[sid] ?? true else { return nil }
            return sid
        }
    }

    var localSearchServices: [MusicService] {
        []
    }

    var activeLocalSearchServices: [MusicService] {
        []
    }

    nonisolated static func localServiceKey(for service: MusicService) -> String {
        "local:\(service.id)"
    }

    var hasFinishedProbing: Bool { hasProbed }

    func resetProbe() {
        hasProbed = false
        cloudToLocalSid.removeAll()
        localToCloudSid.removeAll()
        cloudServiceUsername.removeAll()
    }

    /// Re-run the local-sid ↔ cloud-sid build step using the current
    /// `speakerIP`. Safe to call any number of times — no-ops when the
    /// mapping is already populated and the LAN catalog has been loaded.
    /// Used when the selected speaker's IP becomes available *after* the
    /// initial `probeLinkedServices()` run, which would otherwise leave
    /// the mapping empty until the user visits the Browse tab.
    func refreshServiceIdMappingIfNeeded() async {
        if !cloudToLocalSid.isEmpty { return }
        await ensureMusicServicesPopulated()
        buildServiceIdMapping()
    }

    func forceReprobe() async {
        hasProbed = false
        linkedAccounts = []
        localMusicServiceAccounts = []
        musicServices = []
        cloudToLocalSid.removeAll()
        localToCloudSid.removeAll()
        cloudServiceUsername.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.cachedAccountsKey)
        await fetchLinkedAccounts()
    }

    // MARK: - Grouped Favorites

    struct FavoriteGroup {
        let category: BrowseItem.FavoriteCategory
        let items: [BrowseItem]
    }

    var groupedFavorites: [FavoriteGroup] {
        let order: [BrowseItem.FavoriteCategory] = [.playlist, .album, .song, .artist, .station, .collection]
        var dict: [BrowseItem.FavoriteCategory: [BrowseItem]] = [:]
        for item in favorites {
            let cat = item.favoriteCategory
            dict[cat, default: []].append(item)
        }
        return order.compactMap { cat in
            guard let items = dict[cat], !items.isEmpty else { return nil }
            return FavoriteGroup(category: cat, items: items)
        }
    }

    // MARK: - Cloud → Local Service ID Mapping

    func buildServiceIdMapping() {
        snapshotLocalServiceNames()
        cloudToLocalSid.removeAll()
        localToCloudSid.removeAll()
        cloudServiceUsername.removeAll()
        guard !linkedAccounts.isEmpty, !musicServices.isEmpty else {
            persistSidMapping()
            return
        }

        for account in linkedAccounts {
            guard let cloudId = account.serviceId else { continue }
            let cloudName = (account.name ?? account.nickname ?? "").lowercased()
                .trimmingCharacters(in: .whitespaces)

            if let match = musicServices.first(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespaces) == cloudName
            }) {
                cloudToLocalSid[cloudId] = match.id
                localToCloudSid[match.id] = cloudId
                SonosLog.debug(.search, "Mapped Cloud \(cloudId) (\(account.displayName)) → local sid \(match.id)")
            }

            if let username = account.username, !username.isEmpty {
                cloudServiceUsername[cloudId] = username
                SonosLog.debug(.search, "Username for \(cloudId): \(username)")
            }
        }
        persistSidMapping()
        persistAppleMusicShareCredentialIfAvailable()
    }

    func rebuildLocalServiceIdMapping() {
        snapshotLocalServiceNames()
        buildServiceIdMapping()
    }

    func snapshotLocalServiceNames() {
        guard !musicServices.isEmpty else {
            SharedStorage.serviceNamesByLocalSid = [:]
            SharedStorage.musicServiceCatalogByLocalSid = [:]
            return
        }

        SharedStorage.serviceNamesByLocalSid = Dictionary(
            musicServices.map { (String($0.id), $0.name) },
            uniquingKeysWith: { first, _ in first })
        SharedStorage.musicServiceCatalogByLocalSid = Dictionary(
            musicServices.map {
                (
                    String($0.id),
                    MusicServiceCatalogMetadata(
                        name: $0.name,
                        serviceType: $0.serviceType,
                        manifestURI: $0.manifestURI,
                        presentationMapURI: $0.presentationMapURI)
                )
            },
            uniquingKeysWith: { first, _ in first })
    }

    func persistSidMapping() {
        guard !cloudToLocalSid.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.sidMappingKey)
            return
        }
        // Shape: { "<cloudSid>": <localSid> } — identical to cloudToLocalSid,
        // just string-keyed for plist-safe UserDefaults storage.
        let encodable = Dictionary(uniqueKeysWithValues:
            cloudToLocalSid.map { ($0.key, $0.value) })
        UserDefaults.standard.set(encodable, forKey: Self.sidMappingKey)
    }

    func restoreSidMapping() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.sidMappingKey)
                as? [String: Int], !dict.isEmpty else { return }
        cloudToLocalSid = dict
        localToCloudSid = Dictionary(uniqueKeysWithValues: dict.map { ($0.value, $0.key) })
        persistAppleMusicShareCredentialIfAvailable()
        SonosLog.debug(.search, "Restored \(dict.count) cached sid mappings")
    }

    func persistAppleMusicShareCredentialIfAvailable() {
        guard
            let account = linkedAccounts.first(where: { isAppleMusicAccount($0) }),
            let cloudServiceId = account.serviceId,
            let localServiceId = cloudToLocalSid[cloudServiceId],
            let accountId = account.accountId
        else {
            return
        }

        SharedStorage.appleMusicSonosServiceCredential = AppleMusicSonosServiceCredential(
            cloudServiceId: cloudServiceId,
            localServiceId: localServiceId,
            accountId: accountId,
            username: account.username,
            displayName: account.displayName
        )
    }

    func localSid(forCloudServiceId cloudId: String) -> Int? {
        cloudToLocalSid[cloudId]
    }

    func cloudServiceId(forLocalSid sid: Int) -> String? {
        localToCloudSid[sid]
    }

    /// Best-effort resolution of which streaming service a favorite belongs to.
    /// `browseFavorites` does not populate `BrowseItem.serviceId`, and "shortcut"
    /// favorites (artist / library collection) often ship with an empty `<res>`
    /// and a `<desc>` that's just the plain service name — none of the full
    /// `parseCloudIds` paths (which require sid+sn+objectId) succeed on them.
    ///
    /// This resolver only needs *which service*, not a playable URI, so it
    /// tries every light signal in order:
    ///   1. `BrowseItem.serviceId` (local sid) → cloud
    ///   2. Full `parseCloudIds` path (sid+sn+objectId)
    ///   3. Lone `sid=<N>` in uri / resMD / metaXML
    ///   4. `SA_RINCON<N>_` in any DIDL text
    ///   5. Any linked account's display name appearing in resMD / metaXML
    ///      (e.g. `<r:description>Apple Music</r:description>`)
    func cloudServiceId(forFavorite item: BrowseItem) -> String? {
        if let local = item.serviceId,
           let cloud = cloudServiceId(forLocalSid: local) {
            return cloud
        }
        if let cloud = parseCloudIds(from: item)?.cloudServiceId {
            return cloud
        }
        if let sid = sniffLocalServiceId(from: item),
           let cloud = cloudServiceId(forLocalSid: sid) {
            return cloud
        }
        return sniffCloudServiceIdByAccountName(from: item)
    }

    /// Display name of the linked account for a favorite's service (e.g.
    /// "Apple Music · Charm"). Used as `displayNameHint` so YouTube Music
    /// and Amazon Music — which we recognize by name rather than service-id —
    /// pick up the right brand glyph.
    func serviceDisplayHint(forFavorite item: BrowseItem) -> String? {
        guard let cloudId = cloudServiceId(forFavorite: item) else { return nil }
        return linkedAccounts.first { $0.serviceId == cloudId }?.displayName
    }

    /// Look for a local Sonos `sid` in any DIDL-bearing field. Matches both
    /// the query-string form (`?sid=204&…`) and the SMAPI binding form
    /// (`SA_RINCON204_…`) seen in shortcut favorites' `<desc>` tag.
    func sniffLocalServiceId(from item: BrowseItem) -> Int? {
        let sources = [item.playbackDescriptor.directURI, item.resMD, item.metaXML].compactMap { $0 }
        for src in sources {
            if let range = src.range(of: "[?&]sid=(\\d+)", options: .regularExpression) {
                let token = src[range]
                if let eq = token.firstIndex(of: "="),
                   let n = Int(token[token.index(after: eq)...]) {
                    return n
                }
            }
            if let range = src.range(of: "SA_RINCON(\\d+)_", options: .regularExpression) {
                let token = src[range].dropFirst("SA_RINCON".count).dropLast("_".count)
                if let n = Int(token) { return n }
            }
        }
        return nil
    }

    /// If a linked account's brand/display name (e.g. "Apple Music") appears
    /// anywhere in the favorite's metadata, treat that as the owning service.
    /// This is the final fallback for Apple Music artist / collection favorites
    /// whose DIDL often reduces to `<r:description>Apple Music</r:description>`.
    func sniffCloudServiceIdByAccountName(from item: BrowseItem) -> String? {
        let haystack = [item.resMD, item.metaXML]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !haystack.isEmpty else { return nil }

        for account in linkedAccounts {
            guard let cloudId = account.serviceId else { continue }
            let candidates = [account.name, account.nickname]
                .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 4 } // avoid ultra-short false positives
            if candidates.contains(where: haystack.contains) {
                return cloudId
            }
        }
        return nil
    }

    /// **Prefer the typed factory methods** (`makeArtistItem`, `makeAlbumItem`,
    /// `makePlaylistItem`, `makeTrackItem`, `makeStationItem`) over calling this
    /// directly — they guarantee `uri` / `cloudType` / `isContainer` agree.
    /// This wrapper exists only for low-level callers that already have a raw
    /// `type` string (e.g. tests, dynamic dispatch, internal helpers).
    func buildPlayableURIPublic(objectId: String, serviceId: String,
                                accountId: String, type: String,
                                mimeType: String? = nil) -> String? {
        cloudItemFactory.playableURI(
            objectId: objectId,
            serviceId: serviceId,
            accountId: accountId,
            type: type,
            mimeType: mimeType)
    }

}
