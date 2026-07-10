import Foundation
import SwiftUI

extension SearchManager {

    // MARK: - Typed BrowseItem Factories
    //
    // Single source of truth: each Cloud object kind binds together its
    // `cloudType` raw string, URI scheme, metadata prefix, and `isContainer`
    // flag. Always construct navigation/playback BrowseItems through these
    // factories so the four fields can never drift apart (which previously
    // caused artist favorites to be saved with a `x-sonosapi-radio:` URI).

    /// Build an artist BrowseItem suitable for navigation, "Add to Sonos
    /// Favorites", and `isFavorited` matching.
    func makeArtistItem(objectId: String, name: String, artURL: String? = nil,
                        cloudServiceId: String, accountId: String,
                        preserveArtworkSize: Bool = false) -> BrowseItem {
        cloudItemFactory.artistItem(
            objectId: objectId,
            name: name,
            artURL: artURL,
            cloudServiceId: cloudServiceId,
            accountId: accountId,
            preserveArtworkSize: preserveArtworkSize)
    }

    func makeAlbumItem(objectId: String, title: String, artist: String,
                       artURL: String? = nil,
                       cloudServiceId: String, accountId: String,
                       preserveArtworkSize: Bool = false) -> BrowseItem {
        cloudItemFactory.albumItem(
            objectId: objectId,
            title: title,
            artist: artist,
            artURL: artURL,
            cloudServiceId: cloudServiceId,
            accountId: accountId,
            preserveArtworkSize: preserveArtworkSize)
    }

    func makePlaylistItem(objectId: String, title: String, artist: String = "",
                          artURL: String? = nil,
                          cloudServiceId: String, accountId: String) -> BrowseItem {
        cloudItemFactory.playlistItem(
            objectId: objectId,
            title: title,
            artist: artist,
            artURL: artURL,
            cloudServiceId: cloudServiceId,
            accountId: accountId)
    }

    func makeTrackItem(objectId: String, title: String, artist: String,
                       album: String = "", artURL: String? = nil,
                       mimeType: String? = nil,
                       cloudServiceId: String, accountId: String) -> BrowseItem {
        cloudItemFactory.trackItem(
            objectId: objectId,
            title: title,
            artist: artist,
            album: album,
            artURL: artURL,
            mimeType: mimeType,
            cloudServiceId: cloudServiceId,
            accountId: accountId)
    }

    /// Build a station/radio BrowseItem (e.g. an artist radio program). Use
    /// `makeArtistItem` instead if you want to navigate to the artist page.
    func makeStationItem(objectId: String, title: String, artistName: String = "",
                         artURL: String? = nil,
                         cloudServiceId: String, accountId: String) -> BrowseItem {
        cloudItemFactory.stationItem(
            objectId: objectId,
            title: title,
            artistName: artistName,
            artURL: artURL,
            cloudServiceId: cloudServiceId,
            accountId: accountId)
    }

    func makeAlbumTrackItem(
        from track: SonosCloudAPI.AlbumTrackItem,
        fallbackAlbumTitle: String,
        fallbackArtist: String? = nil,
        fallbackArtURL: String? = nil,
        fallbackServiceId: String? = nil,
        fallbackAccountId: String? = nil
    ) -> BrowseItem {
        cloudItemFactory.albumTrackItem(
            from: track,
            fallbackAlbumTitle: fallbackAlbumTitle,
            fallbackArtist: fallbackArtist,
            fallbackArtURL: fallbackArtURL,
            fallbackServiceId: fallbackServiceId,
            fallbackAccountId: fallbackAccountId
        )
    }

    func makeAlbumTrackContainerItem(from item: SonosCloudAPI.AlbumTrackItem) -> BrowseItem {
        cloudItemFactory.albumTrackContainerItem(from: item)
    }

    typealias FavoriteCloudIds = BrowseItemPlaybackResolver.CloudIds

    var cloudItemFactory: CloudBrowseItemFactory {
        CloudBrowseItemFactory(
            cloudToLocalSid: cloudToLocalSid,
            appleMusicCloudServiceIds: appleMusicCloudServiceIds
        )
    }

    var appleMusicCloudServiceIds: Set<String> {
        var serviceIds: Set<String> = ["52231"]
        for account in linkedAccounts where isAppleMusicAccount(account) {
            if let serviceId = account.serviceId {
                serviceIds.insert(serviceId)
            }
        }
        return serviceIds
    }

    var playbackResolver: BrowseItemPlaybackResolver {
        BrowseItemPlaybackResolver(
            cloudToLocalSid: cloudToLocalSid,
            localToCloudSid: localToCloudSid,
            musicServices: musicServices
        )
    }

    var favoriteMatcher: BrowseItemFavoriteMatcher {
        BrowseItemFavoriteMatcher(
            cloudToLocalSid: cloudToLocalSid,
            musicServices: musicServices
        )
    }

    /// Parse Cloud API identifiers from a Sonos Favorite item's URI or resMD.
    /// URI format: `x-rincon-cpcontainer:1004206c album%3A123?sid=204&flags=8300&sn=2`
    /// or resMD `<item id="1004206c album%3A123" ...>`
    func parseCloudIds(from item: BrowseItem) -> FavoriteCloudIds? {
        playbackResolver.parseCloudIds(from: item)
    }

    /// Extract the `id` attribute value from the first <item> or <container> in DIDL XML.
    func extractDIDLItemId(from xml: String) -> String? {
        let pattern = "<(?:item|container)\\s+id=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    // MARK: - Browse

    /// Populate the Browse tab's Favorites / Playlists / Radio sections.
    ///
    /// When the caller hints we're in remote mode (`cloudMode == true`), the
    /// LAN UPnP `ContentDirectory/Browse` calls would just time out — instead
    /// we pull favorites from the Sonos Cloud Control API. Playlists and
    /// radio don't have first-class Cloud endpoints in the app yet, so those
    /// sections stay empty in remote mode (the UI hides them).
    func loadBrowseContent(cloudMode: Bool = false,
                           cloudContext: CloudContext? = nil,
                           forceRefresh: Bool = false) async {
        let loadKey = browseLoadKey(cloudMode: cloudMode, cloudContext: cloudContext)
        if BrowseRefreshPolicy.shouldSkipLoad(
            forceRefresh: forceRefresh,
            isLoading: isLoadingBrowse,
            currentKey: loadKey,
            lastLoadedKey: lastBrowseLoadKey,
            lastLoadedAt: lastBrowseLoadedAt
        ) {
            return
        }

        isLoadingBrowse = true
        errorMessage = nil
        defer {
            isLoadingBrowse = false
            hasLoadedBrowseContent = true
        }

        if cloudMode, let ctx = cloudContext {
            // Log the failure path explicitly — silently swallowing the
            // error is why off-LAN users see a blank Browse tab with
            // zero diagnostic breadcrumbs.
            do {
                favorites = try await cloudFavoritesWithTokenRefresh(context: ctx)
                SonosLog.info(.favorites, "Cloud favorites: \(favorites.count) loaded")
            } catch {
                SonosLog.error(.favorites, "Cloud favorites load failed: \(error)")
                errorMessage = error.localizedDescription
                favorites = []
            }
            playlists = []
            radio = []
        } else if let ip = speakerIP, !ip.isEmpty {
            async let favs = tryBrowse { try await SonosAPI.browseFavorites(ip: ip) }
            async let lists = tryBrowse { try await SonosAPI.browsePlaylists(ip: ip) }
            async let stations = tryBrowse { try await SonosAPI.browseRadio(ip: ip) }
            favorites = await favs
            playlists = await lists
            radio = await stations

            if musicServices.isEmpty {
                musicServices = (try? await SonosAPI.listMusicServices(ip: ip)) ?? []
                buildServiceIdMapping()
            }
        }

        if errorMessage == nil {
            lastBrowseLoadKey = loadKey
            lastBrowseLoadedAt = Date()
        }
    }

    func browseLoadKey(cloudMode: Bool, cloudContext: CloudContext?) -> String? {
        if cloudMode {
            guard let cloudContext else { return nil }
            return "cloud|\(cloudContext.householdId)|\(cloudContext.groupId)"
        }

        guard let speakerIP, !speakerIP.isEmpty else { return nil }
        return "lan|\(speakerIP)"
    }

    /// One-shot Browse content loader for callers outside the Search/Browse
    /// tab. Detail views call this on appear so the heart icon picks up the
    /// real Sonos Favorites state without forcing the user to open Browse
    /// first. No-ops once the browse content has been loaded for the session;
    /// SearchView's own `loadBrowseForCurrentBackend` keeps providing the
    /// reactive refresh path on backend / speaker changes.
    func ensureBrowseContentLoaded(manager: SonosManager) async {
        if hasLoadedBrowseContent || isLoadingBrowse { return }
        switch manager.transportBackend {
        case .cloud:
            guard let token = await SonosAuth.shared.validAccessToken(),
                  let householdId = SonosAuth.shared.householdId else { return }
            if manager.currentCloudGroupId == nil {
                await manager.resolveCloudGroupId()
            }
            guard let gid = manager.currentCloudGroupId else { return }
            await loadBrowseContent(
                cloudMode: true,
                cloudContext: .init(token: token, householdId: householdId, groupId: gid))
        case .lan:
            await loadBrowseContent()
        case .unknown:
            return
        }
    }

    /// What SearchManager needs from SonosManager when in cloud / remote mode.
    /// Kept decoupled from `SonosControl.Backend` so SearchManager doesn't
    /// grow a hard dep on the router internals.
    struct CloudContext {
        let token: String
        let householdId: String
        let groupId: String
    }

    /// Fetch favorites from the Sonos Cloud Control API and convert them to
    /// the same `BrowseItem` shape the rest of the Browse UI expects. We tag
    /// each with `cloudFavoriteId` so the tap handler knows to dispatch via
    /// `SonosCloudAPI.loadFavorite` rather than UPnP.
    func cloudFavoritesAsBrowseItems(context: CloudContext) async throws -> [BrowseItem] {
        let cloudFavs = try await SonosCloudAPI.listFavorites(
            token: context.token, householdId: context.householdId)
        return cloudFavs.map { cloudItemFactory.cloudFavoriteItem(from: $0) }
    }

    func tryBrowse(_ block: () async throws -> [BrowseItem]) async -> [BrowseItem] {
        (try? await block()) ?? []
    }

    func refreshCloudTokenForRetry() async throws -> String {
        guard await SonosAuth.shared.refreshAccessToken(),
              let token = await SonosAuth.shared.validAccessToken() else {
            SonosAuth.shared.markSessionExpired()
            throw SonosCloudError.unauthorized
        }
        return token
    }

    func musicServiceAccountsWithTokenRefresh(
        token: String,
        householdId: String
    ) async throws -> [SonosCloudAPI.CloudMusicServiceAccount] {
        do {
            return try await SonosCloudAPI.getMusicServiceAccounts(
                token: token, householdId: householdId)
        } catch SonosCloudError.unauthorized {
            let refreshed = try await refreshCloudTokenForRetry()
            return try await SonosCloudAPI.getMusicServiceAccounts(
                token: refreshed, householdId: householdId)
        }
    }

    func cloudFavoritesWithTokenRefresh(context: CloudContext) async throws -> [BrowseItem] {
        do {
            return try await cloudFavoritesAsBrowseItems(context: context)
        } catch SonosCloudError.unauthorized {
            let refreshed = try await refreshCloudTokenForRetry()
            let refreshedContext = CloudContext(
                token: refreshed,
                householdId: context.householdId,
                groupId: context.groupId)
            return try await cloudFavoritesAsBrowseItems(context: refreshedContext)
        }
    }

    func searchCatalogWithTokenRefresh(
        token: String,
        householdId: String,
        term: String,
        serviceIds: [String]
    ) async throws -> SonosCloudAPI.CloudSearchResponse {
        do {
            return try await SonosCloudAPI.searchCatalog(
                token: token, householdId: householdId,
                term: term, serviceIds: serviceIds)
        } catch SonosCloudError.unauthorized {
            let refreshed = try await refreshCloudTokenForRetry()
            return try await SonosCloudAPI.searchCatalog(
                token: refreshed, householdId: householdId,
                term: term, serviceIds: serviceIds)
        }
    }

    func searchServiceWithTokenRefresh(
        token: String,
        householdId: String,
        serviceId: String,
        accountId: String,
        term: String
    ) async throws -> SonosCloudAPI.ServiceSearchResponse {
        do {
            return try await SonosCloudAPI.searchService(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId, term: term)
        } catch SonosCloudError.unauthorized {
            let refreshed = try await refreshCloudTokenForRetry()
            return try await SonosCloudAPI.searchService(
                token: refreshed, householdId: householdId,
                serviceId: serviceId, accountId: accountId, term: term)
        }
    }

    // MARK: - Search via Cloud API

    func search(query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            isSearching = false
            hasSearched = false
            errorMessage = nil
            return
        }

        hasSearched = true
        isSearching = true
        errorMessage = nil
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            if !hasProbed { await probeLinkedServices() }
            guard !Task.isCancelled else { return }

            let serviceIds = activeServiceIds
            guard !serviceIds.isEmpty else {
                SonosLog.info(.search, "No active services to search")
                searchResults = []
                isSearching = false
                return
            }

            lastSearchQuery = query
            serviceDetailResults = [:]

            guard let token = await SonosAuth.shared.validAccessToken(),
                  let householdId = SonosAuth.shared.householdId else {
                SonosLog.info(.search, "No Cloud auth for search")
                errorMessage = SonosCloudError.unauthorized.localizedDescription
                searchResults = []
                isSearching = false
                return
            }

            var results: [ServiceSearchResult] = []
            var cloudServiceIds = serviceIds
            let appleMusicServiceIds = activeAppleMusicServiceIds(in: serviceIds)
            if let appleMusicAccount = appleMusicAccountForSearch(in: serviceIds) {
                do {
                    if let appleMusicResult = try await appleMusicSearchResult(
                        term: query,
                        account: appleMusicAccount,
                        limit: 8
                    ), !appleMusicResult.items.isEmpty {
                        results.append(appleMusicResult)
                        cloudServiceIds.removeAll { appleMusicServiceIds.contains($0) }
                    }
                } catch {
                    SonosLog.error(.search, "MusicKit Apple Music search failed: \(error)")
                }
            }

            do {
                if !cloudServiceIds.isEmpty {
                    let response = try await searchCatalogWithTokenRefresh(
                        token: token, householdId: householdId,
                        term: query, serviceIds: cloudServiceIds)

                    guard !Task.isCancelled else { return }

                    for serviceResult in response.services ?? [] {
                        guard let resources = serviceResult.resources, !resources.isEmpty else { continue }

                        let serviceName = resources.first?.id?.serviceName
                            ?? accountName(for: serviceResult.serviceId)
                            ?? "Unknown"

                        let items = resources.compactMap { resource -> BrowseItem? in
                            convertToBrowseItem(resource, serviceId: serviceResult.serviceId,
                                                accountId: serviceResult.accountId)
                        }

                        if !items.isEmpty {
                            let sid = serviceResult.serviceId ?? UUID().uuidString
                            results.append(ServiceSearchResult(
                                id: sid, serviceName: serviceName, items: items))
                        }
                    }
                }

                let total = results.reduce(0) { $0 + $1.items.count }
                SonosLog.debug(.search, "search '\(query)' across \(serviceIds.count) cloud services → \(total) results in \(results.count) groups")

                guard !Task.isCancelled else { return }
                errorMessage = nil
                searchResults = results
            } catch {
                if !Task.isCancelled {
                    SonosLog.error(.search, "Cloud search failed: \(error)")
                    if results.isEmpty {
                        errorMessage = error.localizedDescription
                        searchResults = []
                    } else {
                        errorMessage = nil
                        searchResults = results
                    }
                }
            }

            isSearching = false
        }
    }

    /// Load full results for a specific service (albums, playlists, etc.).
    /// Called when user taps a service tab for the first time.
    func loadServiceDetail(serviceId: String) async {
        guard serviceDetailResults[serviceId] == nil,
              !isLoadingServiceDetail,
              !lastSearchQuery.isEmpty else { return }

        guard let account = linkedAccounts.first(where: { $0.serviceId == serviceId }),
              let aid = account.accountId else { return }

        isLoadingServiceDetail = true
        defer { isLoadingServiceDetail = false }

        if isAppleMusicAccount(account) {
            do {
                if let result = try await appleMusicSearchResult(
                    term: lastSearchQuery,
                    account: account,
                    limit: 24
                ), !result.items.isEmpty {
                    serviceDetailResults[serviceId] = result
                    errorMessage = nil
                    return
                }
            } catch {
                SonosLog.error(.search, "MusicKit detail search failed for Apple Music: \(error)")
            }
        }

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else { return }

        do {
            let response = try await searchServiceWithTokenRefresh(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: aid, term: lastSearchQuery)

            let allResources = response.allResources
            let serviceName = allResources.first?.id?.serviceName ?? account.displayName
            let items = allResources.compactMap { resource -> BrowseItem? in
                convertToBrowseItem(resource, serviceId: serviceId, accountId: aid)
            }
            SonosLog.debug(.search, "detail \(serviceName) → \(items.count) results")

            serviceDetailResults[serviceId] = ServiceSearchResult(
                id: serviceId, serviceName: serviceName, items: items)
            errorMessage = nil
        } catch {
            SonosLog.error(.search, "Detail search failed for \(serviceId): \(error)")
            errorMessage = error.localizedDescription
        }
    }

    func accountName(for serviceId: String?) -> String? {
        guard let sid = serviceId else { return nil }
        return linkedAccounts.first { $0.serviceId == sid }?.displayName
    }

    func activeAppleMusicServiceIds(in serviceIds: [String]) -> Set<String> {
        let activeIds = Set(serviceIds)
        return Set(linkedAccounts.compactMap { account in
            guard let serviceId = account.serviceId,
                  activeIds.contains(serviceId),
                  isAppleMusicAccount(account) else { return nil }
            return serviceId
        })
    }

    func appleMusicAccountForSearch(
        in serviceIds: [String]
    ) -> SonosCloudAPI.CloudMusicServiceAccount? {
        let activeIds = Set(serviceIds)
        return linkedAccounts.first { account in
            guard let serviceId = account.serviceId else { return false }
            return activeIds.contains(serviceId) && isAppleMusicAccount(account)
        }
    }

    func appleMusicSearchResult(
        term: String,
        account: SonosCloudAPI.CloudMusicServiceAccount,
        limit: Int,
        resultId: String? = nil
    ) async throws -> ServiceSearchResult? {
        guard let serviceId = account.serviceId,
              let accountId = account.accountId else { return nil }

        let start = Date()
        let catalogItems = try await AppleMusicCatalogSearchClient.shared.search(
            term: term,
            limit: limit)
        let items = catalogItems.map { catalogItem -> BrowseItem in
            let uri = cloudItemFactory.playableURI(
                objectId: catalogItem.sonosPlayableObjectID,
                serviceId: serviceId,
                accountId: accountId,
                type: catalogItem.type.cloudType,
                mimeType: catalogItem.sonosPlayableMimeType)
            return catalogItem.browseItem(
                localServiceId: cloudToLocalSid[serviceId],
                uri: uri)
        }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        SonosLog.debug(
            .search,
            "MusicKit Apple Music search '\(term)' → \(items.count) results in \(elapsed)ms")

        return ServiceSearchResult(
            id: resultId ?? serviceId,
            serviceName: account.displayName,
            items: items)
    }

    func playLocalAppleMusic(
        _ playable: LocalServiceAppleMusicPlayable,
        manager: SonosManager
    ) async -> Bool {
        guard let item = await resolveLocalAppleMusicBrowseItem(playable, manager: manager) else {
            return false
        }

        schedulePlaybackArtworkPrewarm(for: item)

        if playable.kind == .station {
            guard let ids = parseCloudIds(from: item) else {
                errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
                return false
            }
            guard let ip = manager.selectedSpeaker?.playbackIP else {
                SonosLog.error(.station, "LocalService station: no speaker IP")
                return false
            }
            pushRecentlyPlayed(item)
            SonosLog.info(
                .station,
                "LocalService station direct title='\(playable.title)' radioId=\(playable.catalogID) " +
                    "playbackKind=\(playable.stationPlaybackKind?.diagnosticName ?? "nil") " +
                    "streamObjectID=\(playable.stationStreamObjectID ?? "nil")")
            return await playRadioStation(
                ip: ip,
                radioId: playable.catalogID,
                stationName: playable.title,
                streamObjectID: playable.stationStreamObjectID,
                isLiveStreamStation: playable.stationPlaybackKind == .stream,
                cloudServiceId: ids.cloudServiceId,
                accountId: ids.accountId,
                artURL: playable.artworkURLString,
                resMD: item.resMD,
                manager: manager)
        }

        if playable.kind == .playlist {
            scheduleLocalServicePlaylistRecentlyPlayedAfterArtworkLookup(item)
            return await playNowInternal(
                item: item,
                manager: manager,
                recordRecentlyPlayed: false)
        }

        return await playNowInternal(item: item, manager: manager)
    }

    func resolveLocalAppleMusicBrowseItem(
        _ playable: LocalServiceAppleMusicPlayable,
        manager: SonosManager
    ) async -> BrowseItem? {
        guard let selectedSpeaker = manager.selectedSpeaker else {
            errorMessage = HandoffTransferError.noSelectedSpeaker.localizedDescription
            return nil
        }
        let selectedSpeakerID = selectedSpeaker.id
        let selectedPlaybackIP = selectedSpeaker.playbackIP
        configure(speakerIP: selectedPlaybackIP)

        if manager.transportBackend == .unknown {
            _ = await manager.probeBackend()
        }

        if manager.transportBackend == .cloud {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Playing Local Service items")
                .localizedDescription
            return nil
        }

        if !hasProbed {
            await probeLinkedServices()
        }
        await refreshServiceIdMappingIfNeeded()

        guard manager.selectedSpeaker?.id == selectedSpeakerID,
              manager.selectedSpeaker?.playbackIP == selectedPlaybackIP else {
            errorMessage = "Selected speaker changed. Try again."
            return nil
        }

        guard let account = linkedAccounts.first(where: { isAppleMusicAccount($0) }),
              let serviceId = account.serviceId,
              let accountId = account.accountId else {
            errorMessage = LocalServiceSonosPlaybackError.appleMusicAccountMissing.localizedDescription
            return nil
        }

        guard cloudToLocalSid[serviceId] != nil else {
            errorMessage = LocalServiceSonosPlaybackError.localServiceMappingMissing.localizedDescription
            return nil
        }

        guard let item = localServiceBrowseItem(
            for: playable,
            cloudServiceId: serviceId,
            accountId: accountId
        ), item.playbackDescriptor.isPlayable else {
            errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
            return nil
        }

        SonosLog.info(
            .playback,
            "LocalService play kind=\(playable.kind) catalogID=\(playable.catalogID) " +
            "objectID=\(item.id) localSid=\(item.serviceId.map(String.init) ?? "nil") " +
            "cloudServiceId=\(serviceId) accountId=\(accountId) uri=\(item.uri ?? "nil")")
        SonosLog.debug(
            .playbackLink,
            "LocalService resolved kind=\(playable.kind.cloudType) title='\(playable.title)' " +
                "catalogID=\(SonosLog.playbackLinkValue(playable.catalogID, maxLength: 640)) " +
                "browseId=\(SonosLog.playbackLinkValue(item.id, maxLength: 640)) " +
                "cloudType=\(item.cloudType ?? "nil") localSid=\(item.serviceId.map(String.init) ?? "nil") " +
                "uri=\(SonosLog.playbackLinkValue(item.uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(playbackMetadata(for: item)))")

        return item
    }

    func localServiceBrowseItem(
        for playable: LocalServiceAppleMusicPlayable,
        cloudServiceId: String,
        accountId: String
    ) -> BrowseItem? {
        var item: BrowseItem
        switch playable.kind {
        case .song:
            item = makeTrackItem(
                objectId: playable.catalogID,
                title: playable.title,
                artist: playable.artist,
                album: playable.album,
                artURL: playable.artworkURLString,
                mimeType: playable.sonosMimeType,
                cloudServiceId: cloudServiceId,
                accountId: accountId)
        case .album:
            item = makeAlbumItem(
                objectId: playable.sonosObjectID,
                title: playable.title,
                artist: playable.artist,
                artURL: playable.artworkURLString,
                cloudServiceId: cloudServiceId,
                accountId: accountId)
        case .artist:
            item = makeArtistItem(
                objectId: playable.sonosObjectID,
                name: playable.title,
                artURL: playable.artworkURLString,
                cloudServiceId: cloudServiceId,
                accountId: accountId)
        case .playlist:
            item = makePlaylistItem(
                objectId: playable.sonosObjectID,
                title: playable.title,
                artist: playable.artist,
                artURL: playable.artworkURLString,
                cloudServiceId: cloudServiceId,
                accountId: accountId)
            item.includeAlbumArtInCloudMetadata = false
        case .station:
            item = makeStationItem(
                objectId: playable.sonosObjectID,
                title: playable.title,
                artistName: playable.artist,
                artURL: playable.artworkURLString,
                cloudServiceId: cloudServiceId,
                accountId: accountId)
        }
        item.duration = playable.duration ?? 0
        return item
    }

    /// Convert a Cloud API resource into a BrowseItem for playback.
    func convertToBrowseItem(_ resource: SonosCloudAPI.CloudResource,
                                     serviceId: String?,
                                     accountId: String?) -> BrowseItem? {
        cloudItemFactory.browseItem(
            from: resource,
            serviceId: serviceId,
            accountId: accountId)
    }

    func forwardAlbumCandidate(
        from albumTrack: SonosCloudAPI.AlbumTrackItem,
        fallbackAlbumTitle: String,
        fallbackArtURL: String?,
        serviceId: String,
        accountId: String
    ) -> AppleMusicForwardAlbumTrackCandidate? {
        guard AppleMusicForwardAlbumQueuePlanner.isSupportedAlbumTrackType(
            itemType: albumTrack.type,
            resourceType: albumTrack.resource?.type) else {
            return nil
        }

        let item = makeAlbumTrackItem(
            from: albumTrack,
            fallbackAlbumTitle: fallbackAlbumTitle,
            fallbackArtURL: fallbackArtURL,
            fallbackServiceId: serviceId,
            fallbackAccountId: accountId
        )
        guard !item.id.isEmpty,
              !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return AppleMusicForwardAlbumTrackCandidate(
            item: item,
            ordinal: albumTrack.ordinal)
    }

    func appleMusicCatalogTrackId(from objectId: String) -> String {
        let decodedObjectId = objectId.removingPercentEncoding ?? objectId
        if let storeID = SonosAppleMusicTrackResolver.storeID(fromObjectID: decodedObjectId) {
            return "song%3a\(storeID)"
        }
        return objectId
    }

}
