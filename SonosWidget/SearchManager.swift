import Foundation
import SwiftUI

// MARK: - Sonos UPnP magic numbers

/// `flags=8300` is the Sonos-internal "third-party streaming radio /
/// container" flag set used by the official Sonos app on radio:ra.* and
/// cpcontainer URIs. Anything else (e.g. `flags=0`) makes the speaker
/// reject the URI with SOAP fault 800/801. Verified by capturing the
/// official iOS app's traffic.
let SonosRinconRadioFlags: Int = 8300

/// Apple Music live radio stations (for example Apple Music Chill) are exposed
/// by Sonos Browse as `x-sonosapi-stream:hls%3Ara...` before the speaker
/// resolves them to `x-sonosapi-hls:hls%3ara...`.
let SonosRinconLiveStationFlags: Int = 8292

/// Time we sleep after `setAVTransportURI` before issuing `Play`.
/// 800 ms is the empirical sweet spot — shorter and the speaker still
/// sometimes returns "transition pending" on Play.
let stationSetURISettleMs: Int = 800
/// Time we wait after Play before reading transport state to decide
/// if we need to retry. Stations resolve via the cloud and can take
/// 2-3 s before the transport leaves STOPPED.
let stationPlayConfirmMs: Int = 2500
/// Pause between retries when the first Play left us in STOPPED.
let stationRetryDelayMs: Int = 2000
/// After playNow, how long to wait before refreshing UI state so the
/// freshly-set track has propagated to the position-info endpoint.
let playbackSettleDelayMs: Int = 1500

struct HandoffResult: Equatable {
    let matchedTitle: String
    let targetName: String
    let seeked: Bool
    let transferredTrackCount: Int
    let skippedUnsupportedItemCount: Int
    let warningMessage: String?
    let usedAlbumQueue: Bool
}

enum HandoffTransferError: LocalizedError, Equatable {
    case noSelectedSpeaker
    case noBackend
    case sonosCloudDisconnected
    case appleMusicNotLinkedOnSonos
    case noConfidentMatch
    case sonosPlaybackFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSelectedSpeaker:
            return "Select a Sonos speaker before transferring Apple Music."
        case .noBackend:
            return "Speaker unreachable — pull to refresh."
        case .sonosCloudDisconnected:
            return "Sign in to Sonos Cloud before transferring Apple Music."
        case .appleMusicNotLinkedOnSonos:
            return "Apple Music is not linked to this Sonos household."
        case .noConfidentMatch:
            return "Sonos could not confidently match the Apple Music track."
        case .sonosPlaybackFailed(let message):
            return message
        }
    }
}

struct ReverseHandoffResult: Equatable {
    let matchedTitle: String
    let targetName: String
    let seeked: Bool
    let sonosPaused: Bool
    let warningMessage: String?
    let transferredTrackCount: Int
    let skippedUnsupportedItemCount: Int
}

enum ReverseHandoffError: LocalizedError, Equatable {
    case noSelectedSpeaker
    case noBackend
    case notAppleMusicSource
    case missingSonosTrackMetadata
    case sonosCloudDisconnected
    case appleMusicNotLinkedOnSonos
    case noConfidentMatch

    var errorDescription: String? {
        switch self {
        case .noSelectedSpeaker:
            return "Select a Sonos speaker before transferring to iPhone."
        case .noBackend:
            return "Speaker unreachable — pull to refresh."
        case .notAppleMusicSource:
            return "Only Apple Music can be transferred to iPhone."
        case .missingSonosTrackMetadata:
            return "The current Sonos track could not be identified."
        case .sonosCloudDisconnected:
            return "Sign in to Sonos Cloud before transferring to iPhone."
        case .appleMusicNotLinkedOnSonos:
            return "Apple Music is not linked to this Sonos household."
        case .noConfidentMatch:
            return "Apple Music could not confidently match the Sonos track."
        }
    }
}

@Observable
final class SearchManager {
    var favorites: [BrowseItem] = []
    var playlists: [BrowseItem] = []
    var radio: [BrowseItem] = []
    var searchResults: [ServiceSearchResult] = []
    var musicServices: [MusicService] = []
    var isLoadingBrowse = false
    var isSearching = false
    var hasSearched = false
    var isProbing = false
    var searchQuery = ""
    var errorMessage: String?

    // Station picker state
    struct RadioStationOption: Identifiable {
        let id: String // objectId e.g. "radio:ra.137938148"
        let name: String
        let artURL: String?
        let cloudServiceId: String?
        let accountId: String?
        let resMD: String?
    }

    struct StationTransportPayload: Equatable {
        let label: String
        let uri: String
        let metadata: String
    }

    enum StationTransportMetadataStyle: Equatable {
        case programRadio
        case hlsLiveRadio
    }

    private struct ForwardAlbumQueueAttempt {
        let plan: AppleMusicForwardAlbumQueuePlan
    }

    private struct ForwardCloudTrackCandidate {
        let resource: SonosCloudAPI.CloudResource
        let item: BrowseItem
    }

    var stationOptions: [RadioStationOption] = []
    var showStationPicker = false
    var pendingStationManager: SonosManager?

    /// Accounts detected via Sonos Cloud API.
    var linkedAccounts: [SonosCloudAPI.CloudMusicServiceAccount] = []
    /// Legacy local account probes are kept only for diagnostics/tests. Linked
    /// streaming services shown in the app come from Sonos Cloud accounts.
    var localMusicServiceAccounts: [LocalMusicServiceAccount] = []
    /// User's per-service search toggle. Key = Cloud serviceId string.
    var serviceEnabled: [String: Bool] = [:]

    struct ServiceSearchResult: Identifiable {
        let id: String
        let serviceName: String
        var items: [BrowseItem]
    }

    /// Per-service detailed results (loaded on demand when a service tab is selected).
    var serviceDetailResults: [String: ServiceSearchResult] = [:]
    var isLoadingServiceDetail = false

    /// Locally-tracked "Recently Played" list — populated whenever the user
    /// triggers playback through the app (tapping an item in search results,
    /// starting a station, etc). Capped to `recentlyPlayedLimit`, persisted
    /// across launches via UserDefaults so the Browse page shows history
    /// immediately on cold start.
    private(set) var recentlyPlayed: [BrowseItem] = []
    private static let recentlyPlayedLimit = 20

    private static let enabledKey = "SearchEnabledServices"
    private static let cachedAccountsKey = "CachedLinkedAccounts"
    /// Persisted `cloudToLocalSid` / `localToCloudSid` mapping. Built from
    /// the intersection of the Cloud API's linked-services list and the
    /// LAN `listMusicServices` catalog. Caching lets subsequent launches
    /// resolve cloud service ids from a local sid *before* the user opens
    /// Browse — the player's artist / album NavigationLinks need this
    /// mapping to render as tappable links.
    private static let sidMappingKey = "CloudLocalSidMapping"
    private static let recentlyPlayedKey = "RecentlyPlayedItems"

    private var speakerIP: String?
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var replaceQueueFillTask: Task<Void, Never>?
    @ObservationIgnored private var replaceQueueFillGeneration = 0
    @ObservationIgnored var localServicePlaylistArtworkLookupOverride: ((BrowseItem) async -> String?)?
    @ObservationIgnored var playbackArtworkPrewarmOverride: (([URL]) async -> Void)?
    /// The query string that produced the most recent `searchResults` /
    /// `serviceDetailResults`. Readable from views so they can react when a
    /// new search commits (e.g. to re-fetch the selected service tab).
    private(set) var lastSearchQuery = ""
    private var hasProbed = false
    /// Tracks whether `loadBrowseContent` has finished at least once during
    /// this session. Detail views (Artist / Album / Playlist) consult this so
    /// they can lazily trigger the load when the user opens a detail page
    /// without ever visiting the Browse tab — otherwise `isFavorited` always
    /// returns false because `favorites` is still empty.
    private(set) var hasLoadedBrowseContent = false
    private var lastBrowseLoadKey: String?
    private var lastBrowseLoadedAt: Date?

    var hasBrowseDisplayContent: Bool {
        hasLoadedBrowseContent || !favorites.isEmpty || !playlists.isEmpty || !radio.isEmpty || !recentlyPlayed.isEmpty
    }

    var showsBlockingBrowseLoader: Bool {
        BrowseRefreshPolicy.showsBlockingLoader(
            isLoading: isLoadingBrowse,
            hasLoadedContent: hasBrowseDisplayContent
        )
    }

    init() {
        restoreCachedAccounts()
        restoreRecentlyPlayed()
        restoreSidMapping()
    }

    func configure(speakerIP: String?) {
        self.speakerIP = speakerIP
    }

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
    private func ensureMusicServicesPopulated() async {
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
    private func fetchLinkedAccounts() async {
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

    private func persistToggles() {
        UserDefaults.standard.set(serviceEnabled, forKey: Self.enabledKey)
    }

    private func persistAccounts(_ accounts: [SonosCloudAPI.CloudMusicServiceAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.cachedAccountsKey)
        }
    }

    private func restoreCachedAccounts() {
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

    private func persistRecentlyPlayed() {
        if let data = try? JSONEncoder().encode(recentlyPlayed) {
            UserDefaults.standard.set(data, forKey: Self.recentlyPlayedKey)
        }
    }

    private func restoreRecentlyPlayed() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentlyPlayedKey),
              let items = try? JSONDecoder().decode([BrowseItem].self, from: data),
              !items.isEmpty else { return }
        recentlyPlayed = items
    }

    private func scheduleLocalServicePlaylistRecentlyPlayedAfterArtworkLookup(_ item: BrowseItem) {
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
    private func recordLocalServicePlaylistRecentlyPlayed(
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

    private func localServicePlaylistArtworkURLString(for item: BrowseItem) async -> String? {
        if let localServicePlaylistArtworkLookupOverride {
            return await localServicePlaylistArtworkLookupOverride(item)
        }
        return await sonosCloudPlaylistArtworkURLString(for: item)
    }

    private func sonosCloudPlaylistArtworkURLString(for item: BrowseItem) async -> String? {
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

    private func normalizedSonosPlaylistArtworkURLString(_ value: String?) -> String? {
        ArtworkURLNormalizer.loadableURLString(
            from: value,
            preserveExistingAppleArtworkSize: true)
    }

    func prewarmPlaybackArtwork(items: [BrowseItem]) async {
        PlaybackArtworkRegistry.shared.register(items: items)
        let appleMusicItems = items.filter(isAppleMusicPlaybackArtworkItem)
        if !appleMusicItems.isEmpty {
            PlaybackArtworkURLCache.shared.register(
                items: appleMusicItems,
                service: .appleMusic,
                source: .sonosCloud
            )
        }
        submitArtworkHintsToRelay(items)
        await prewarmPlaybackArtwork(
            urls: PlaybackArtworkPrewarmPolicy.urls(from: items)
        )
    }

    private func submitArtworkHintsToRelay(_ items: [BrowseItem]) {
        guard !items.isEmpty else { return }
        let itemSnapshot = items
        Task { @MainActor in
            RelayManager.shared.submitArtworkHints(itemSnapshot)
        }
    }

    private func schedulePlaybackArtworkPrewarm(
        for item: BrowseItem,
        includeContainerTracks: Bool = true
    ) {
        let itemSnapshot = item
        Task { [weak self] in
            guard let self else { return }
            await self.prewarmPlaybackArtwork(items: [itemSnapshot])
            guard includeContainerTracks else { return }
            await self.prewarmContainerPlaybackArtwork(for: itemSnapshot)
        }
    }

    private func schedulePlaybackArtworkPrewarm(for items: [BrowseItem]) {
        let itemSnapshot = items
        Task { [weak self] in
            await self?.prewarmPlaybackArtwork(items: itemSnapshot)
        }
    }

    private func prewarmPlaybackArtwork(urls: [URL]) async {
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

    private func prewarmContainerPlaybackArtwork(for item: BrowseItem) async {
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
            submitArtworkHintsToRelay(trackItems)
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

    /// Maps Cloud API serviceId (e.g. "52231") to local Sonos sid (e.g. 204).
    private var cloudToLocalSid: [String: Int] = [:]
    /// Reverse: local Sonos sid → Cloud API serviceId.
    private var localToCloudSid: [Int: String] = [:]
    /// Maps Cloud API serviceId to the account username (e.g. "X_#Svc52231-408f19a7-Token").
    private var cloudServiceUsername: [String: String] = [:]

    private func buildServiceIdMapping() {
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

    private func snapshotLocalServiceNames() {
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

    private func persistSidMapping() {
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

    private func restoreSidMapping() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.sidMappingKey)
                as? [String: Int], !dict.isEmpty else { return }
        cloudToLocalSid = dict
        localToCloudSid = Dictionary(uniqueKeysWithValues: dict.map { ($0.value, $0.key) })
        persistAppleMusicShareCredentialIfAvailable()
        SonosLog.debug(.search, "Restored \(dict.count) cached sid mappings")
    }

    private func persistAppleMusicShareCredentialIfAvailable() {
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
    private func sniffLocalServiceId(from item: BrowseItem) -> Int? {
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
    private func sniffCloudServiceIdByAccountName(from item: BrowseItem) -> String? {
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

    private var cloudItemFactory: CloudBrowseItemFactory {
        CloudBrowseItemFactory(
            cloudToLocalSid: cloudToLocalSid,
            appleMusicCloudServiceIds: appleMusicCloudServiceIds
        )
    }

    private var appleMusicCloudServiceIds: Set<String> {
        var serviceIds: Set<String> = ["52231"]
        for account in linkedAccounts where isAppleMusicAccount(account) {
            if let serviceId = account.serviceId {
                serviceIds.insert(serviceId)
            }
        }
        return serviceIds
    }

    private var playbackResolver: BrowseItemPlaybackResolver {
        BrowseItemPlaybackResolver(
            cloudToLocalSid: cloudToLocalSid,
            localToCloudSid: localToCloudSid,
            musicServices: musicServices
        )
    }

    private var favoriteMatcher: BrowseItemFavoriteMatcher {
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
    private func extractDIDLItemId(from xml: String) -> String? {
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

    private func browseLoadKey(cloudMode: Bool, cloudContext: CloudContext?) -> String? {
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
    private func cloudFavoritesAsBrowseItems(context: CloudContext) async throws -> [BrowseItem] {
        let cloudFavs = try await SonosCloudAPI.listFavorites(
            token: context.token, householdId: context.householdId)
        return cloudFavs.map { cloudItemFactory.cloudFavoriteItem(from: $0) }
    }

    private func tryBrowse(_ block: () async throws -> [BrowseItem]) async -> [BrowseItem] {
        (try? await block()) ?? []
    }

    private func refreshCloudTokenForRetry() async throws -> String {
        guard await SonosAuth.shared.refreshAccessToken(),
              let token = await SonosAuth.shared.validAccessToken() else {
            SonosAuth.shared.markSessionExpired()
            throw SonosCloudError.unauthorized
        }
        return token
    }

    private func musicServiceAccountsWithTokenRefresh(
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

    private func cloudFavoritesWithTokenRefresh(context: CloudContext) async throws -> [BrowseItem] {
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

    private func searchCatalogWithTokenRefresh(
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

    private func searchServiceWithTokenRefresh(
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

    private func accountName(for serviceId: String?) -> String? {
        guard let sid = serviceId else { return nil }
        return linkedAccounts.first { $0.serviceId == sid }?.displayName
    }

    private func activeAppleMusicServiceIds(in serviceIds: [String]) -> Set<String> {
        let activeIds = Set(serviceIds)
        return Set(linkedAccounts.compactMap { account in
            guard let serviceId = account.serviceId,
                  activeIds.contains(serviceId),
                  isAppleMusicAccount(account) else { return nil }
            return serviceId
        })
    }

    private func appleMusicAccountForSearch(
        in serviceIds: [String]
    ) -> SonosCloudAPI.CloudMusicServiceAccount? {
        let activeIds = Set(serviceIds)
        return linkedAccounts.first { account in
            guard let serviceId = account.serviceId else { return false }
            return activeIds.contains(serviceId) && isAppleMusicAccount(account)
        }
    }

    private func appleMusicSearchResult(
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
    private func convertToBrowseItem(_ resource: SonosCloudAPI.CloudResource,
                                     serviceId: String?,
                                     accountId: String?) -> BrowseItem? {
        cloudItemFactory.browseItem(
            from: resource,
            serviceId: serviceId,
            accountId: accountId)
    }

    private func forwardAlbumCandidate(
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

    private func appleMusicCatalogTrackId(from objectId: String) -> String {
        let decodedObjectId = objectId.removingPercentEncoding ?? objectId
        if let storeID = SonosAppleMusicTrackResolver.storeID(fromObjectID: decodedObjectId) {
            return "song%3a\(storeID)"
        }
        return objectId
    }

    // MARK: - Playback Actions

    private func playbackMetadata(for item: BrowseItem) -> String {
        if let resMD = item.resMD, !resMD.isEmpty {
            return resMD
        }

        // For Cloud search results, build metadata with correct service account
        if item.cloudType != nil, let sid = item.serviceId {
            let accountId = accountIdForLocalSid(sid) ?? "0"
            return buildCloudDIDLMetadata(item: item, localSid: sid, accountId: accountId)
        }

        // UPnP-browsed items (Sonos system playlist children `SQ:<n>`, local
        // library, queue, etc.) ship their track-level DIDL fragment in
        // `metaXML` — title / artist / album / service `<desc>` already set
        // by Sonos. Without a `<DIDL-Lite>` envelope Sonos rejects it and
        // synthesises a bare stub from the URI, which is why individual
        // tracks from a Sonos Playlist showed up as "Unknown" on the player.
        if let metaXML = item.metaXML, !metaXML.isEmpty,
           metaXML.contains("<item") || metaXML.contains("<container") {
            return wrapInDIDLLiteIfNeeded(metaXML)
        }

        return SonosAPI.buildDIDLMetadata(item: item)
    }

    /// Add the DIDL-Lite envelope around a raw `<item>` / `<container>`
    /// fragment so Sonos will accept it as enqueue metadata.
    private func wrapInDIDLLiteIfNeeded(_ xml: String) -> String {
        if xml.contains("<DIDL-Lite") { return xml }
        return "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
            "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " +
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" +
            xml +
            "</DIDL-Lite>"
    }

    /// Find the Cloud account-id (sn) for a given local service ID.
    private func accountIdForLocalSid(_ localSid: Int) -> String? {
        for (cloudId, sid) in cloudToLocalSid {
            if sid == localSid {
                return linkedAccounts.first { $0.serviceId == cloudId }?.accountId
            }
        }
        return nil
    }

    /// Build DIDL metadata for Cloud items, matching the exact field sets the
    /// official Sonos app produces for each `cloudType`. Sonos validates the
    /// inner DIDL strictly when used as `<r:resMD>` for favorites — including
    /// fields that don't belong (e.g. `<upnp:albumArtURI>` inside an ARTIST
    /// item, or empty `<dc:creator>` tags) causes SOAP fault 803.
    ///
    /// Per-type field whitelist (verified by dumping existing favorites):
    ///   - ARTIST   → title, class, desc                          (minimal)
    ///   - PROGRAM  → title, class, desc                          (radio station)
    ///   - ALBUM    → title, class, albumArtURI, creator, albumArtist, desc
    ///   - PLAYLIST → title, class, albumArtURI, creator, desc
    ///   - TRACK    → title, class, albumArtURI, creator, album, albumArtist, desc
    func buildCloudDIDLMetadata(item: BrowseItem, localSid: Int, accountId: String) -> String {
        let cloudSid = localToCloudSid[localSid] ?? String(localSid)
        let username = cloudServiceUsername(for: cloudSid, accountId: accountId)
        let desc = "SA_RINCON\(cloudSid)_\(username)"

        let encodedObjId = item.id.replacingOccurrences(of: ":", with: "%3a")
        let cloudType = item.cloudType ?? "TRACK"

        let (itemId, upnpClass, xmlTag) = metadataComponents(
            cloudType: cloudType, objectId: encodedObjId, uri: item.playbackDescriptor.directURI)

        // Only TRACK/ALBUM/PLAYLIST carry rich metadata in their inner DIDL.
        // ARTIST and PROGRAM use a bare-minimum item (title + class + desc).
        let wantsRichMetadata = (cloudType == "TRACK" ||
                                 cloudType == "ALBUM" ||
                                 cloudType == "PLAYLIST")
        let artist = wantsRichMetadata && !item.artist.isEmpty ? item.artist : nil
        let albumArtist = wantsRichMetadata && cloudType != "PLAYLIST" ? artist : nil
        let album = (cloudType == "TRACK" && !item.album.isEmpty) ? item.album : nil
        let albumArtURI = wantsRichMetadata &&
            item.includeAlbumArtInCloudMetadata &&
            item.albumArtURL?.isEmpty == false ? item.albumArtURL : nil

        return SonosDIDLBuilder.document([
            SonosDIDLElement(
                tag: xmlTag,
                id: itemId,
                title: item.title,
                upnpClass: upnpClass,
                creator: artist,
                album: album,
                albumArtist: albumArtist,
                albumArtURI: albumArtURI,
                desc: desc)
        ])
    }

    private func cloudServiceUsername(for cloudSid: String, accountId: String) -> String {
        if let username = cloudServiceUsername[cloudSid], !username.isEmpty {
            return username
        }
        if let username = linkedAccounts.first(where: { $0.serviceId == cloudSid })?.username,
           !username.isEmpty {
            return username
        }
        return "X_#Svc\(cloudSid)-\(accountId)-Token"
    }

    /// Returns (itemId, upnpClass, xmlTag) based on cloudType.
    /// Format derived from Wireshark capture of official Sonos app.
    private func metadataComponents(cloudType: String, objectId: String,
                                    uri: String?) -> (String, String, String) {
        switch cloudType {
        case "TRACK":
            let flags = extractFlagsFromURI(uri)
            let flagsHex = String(format: "%04x", flags)
            return (trackMetadataObjectId(objectId: objectId, flagsHex: flagsHex),
                    "object.item.audioItem.musicTrack",
                    "item")
        case "ALBUM":
            return ("1004206c\(objectId)",
                    "object.container.album.musicAlbum.#AlbumView",
                    "item")
        case "PLAYLIST":
            return ("1006206c\(objectId)",
                    "object.container.playlistContainer",
                    "item")
        case "PROGRAM":
            return ("000c206c\(objectId)",
                    "object.item.audioItem.audioBroadcast.#programRadio",
                    "item")
        case "ARTIST":
            // Sonos Apple Music artist favorites use prefix `10052064` and
            // wrap the metadata in <item> (not <container>) — verified by
            // dumping existing artist favorites added via the official app.
            return ("10052064\(objectId)",
                    "object.container.person.musicArtist",
                    "item")
        default:
            return (objectId, "object.item.audioItem.musicTrack", "item")
        }
    }

    private func trackMetadataObjectId(objectId: String, flagsHex: String) -> String {
        let catalogTrackId = appleMusicCatalogTrackId(from: objectId)
        return "1003\(flagsHex)\(catalogTrackId)"
    }

    private func extractFlagsFromURI(_ uri: String?) -> Int {
        guard let uri = uri,
              let range = uri.range(of: "flags=") else { return 0 }
        let after = uri[range.upperBound...]
        let flagStr: Substring
        if let ampIdx = after.firstIndex(of: "&") {
            flagStr = after[..<ampIdx]
        } else {
            flagStr = after
        }
        return Int(flagStr) ?? 0
    }

    /// Inject `upnp:albumArtURI` into DIDL metadata when not already present.
    /// Sonos Favorites store the art URL in the outer browse item, but the inner
    /// `r:resMD` DIDL often omits it — which leaves "recently played" without cover art.
    private func enrichMetadataWithArt(_ metadata: String, artURL: String?) -> String {
        guard let artURL = artURL, !artURL.isEmpty else { return metadata }
        if metadata.contains("albumArtURI") { return metadata }
        let artTag = "<upnp:albumArtURI>\(SonosAPI.escapeXML(artURL))</upnp:albumArtURI>"
        if metadata.contains("</item>") {
            return metadata.replacingOccurrences(of: "</item>", with: "\(artTag)</item>")
        }
        if metadata.contains("</container>") {
            return metadata.replacingOccurrences(of: "</container>", with: "\(artTag)</container>")
        }
        return metadata
    }

    private func extractServiceParams() -> BrowseItemPlaybackResolver.ServiceParams? {
        playbackResolver.serviceParams(from: favorites + radio)
    }

    private func constructFavoriteURI(resMD: String) -> String? {
        playbackResolver.favoriteTransportURI(
            resMD: resMD,
            seedItems: favorites + radio,
            defaultFlags: SonosRinconRadioFlags
        )
    }

    private func forwardAlbumQueueAttempt(
        sourceTrack: AppleMusicHandoffTrack,
        matchedCandidate: ForwardCloudTrackCandidate,
        token: String,
        householdId: String,
        serviceId: String,
        accountId: String,
        backend: SonosControl.Backend
    ) async -> ForwardAlbumQueueAttempt? {
        guard case .lan = backend else {
            SonosLog.info(.playback, "Forward album handoff skipped: backend is not LAN")
            return nil
        }

        SonosLog.info(
            .playback,
            "Forward album handoff attempt: source='\(sourceTrack.title)' artist='\(sourceTrack.artist)' " +
            "match='\(matchedCandidate.item.title)' matchId='\(matchedCandidate.item.id)' " +
            "resourceId='\(matchedCandidate.resource.id?.objectId ?? "nil")' " +
            "container='\(matchedCandidate.resource.container?.name ?? "nil")' " +
            "containerId='\(matchedCandidate.resource.container?.id?.objectId ?? "nil")'")

        guard let albumId = await forwardAlbumId(
            from: matchedCandidate.resource,
            matchedItem: matchedCandidate.item,
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId) else {
            SonosLog.info(.playback, "Forward album handoff fallback: album id could not be resolved")
            return nil
        }
        SonosLog.info(.playback, "Forward album handoff resolved albumId='\(albumId)'")

        do {
            let response = try await SonosCloudAPI.browseAlbum(
                token: token,
                householdId: householdId,
                serviceId: serviceId,
                accountId: accountId,
                albumId: albumId,
                count: AppleMusicForwardAlbumQueuePlanner.defaultMaxItems)
            let albumTitle = response.title ?? matchedCandidate.item.album
            let fallbackArtURL = response.images?.tile1x1
                ?? matchedCandidate.item.albumArtURL
                ?? matchedCandidate.resource.container?.images?.first?.url
                ?? matchedCandidate.resource.images?.first?.url
            let albumTracks = response.tracks?.items ?? response.section?.items ?? []
            let candidates = albumTracks.compactMap {
                forwardAlbumCandidate(
                    from: $0,
                    fallbackAlbumTitle: albumTitle,
                    fallbackArtURL: fallbackArtURL,
                    serviceId: serviceId,
                    accountId: accountId)
            }
            SonosLog.info(
                .playback,
                "Forward album handoff browsed album='\(albumTitle)' " +
                "rawTracks=\(albumTracks.count) candidates=\(candidates.count)")

            guard let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
                albumTracks: candidates,
                matchedItem: matchedCandidate.item,
                sourceTrack: sourceTrack) else {
                let matchedStoreID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: matchedCandidate.item) ?? "nil"
                let preview = candidates.prefix(5).map {
                    "\($0.ordinal.map(String.init) ?? "?"):\($0.item.title):" +
                    "\(SonosAppleMusicTrackResolver.storeID(fromBrowseItem: $0.item) ?? "nil")"
                }.joined(separator: " | ")
                SonosLog.info(
                    .playback,
                    "Forward album handoff fallback: planner returned nil " +
                    "matchedStoreID=\(matchedStoreID) candidatesPreview=\(preview)")
                return nil
            }

            SonosLog.info(
                .playback,
                "Forward album handoff plan ready: tracks=\(plan.transferredTrackCount) " +
                "target=\(plan.targetTrackNumber) skipped=\(plan.skippedUnsupportedItemCount)")
            return ForwardAlbumQueueAttempt(plan: plan)
        } catch {
            SonosLog.error(.cloudAPI, "Forward handoff album browse failed: \(error)")
            return nil
        }
    }

    private func playForwardAlbumQueue(
        _ plan: AppleMusicForwardAlbumQueuePlan,
        sourceTrack: AppleMusicHandoffTrack,
        selectedSpeaker: SonosPlayer,
        backend: SonosControl.Backend,
        manager: SonosManager
    ) async throws -> (played: Bool, seeked: Bool) {
        guard case .lan(let ip, _, let speakerUUID) = backend else { return (false, false) }

        do {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            let currentPlayMode = try? await SonosAPI.getPlayMode(ip: ip)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            if currentPlayMode?.shuffle == true {
                do {
                    try await SonosAPI.setPlayMode(
                        ip: ip,
                        shuffle: false,
                        repeat: currentPlayMode?.repeat ?? .off)
                } catch {
                    SonosLog.error(.playback, "Forward album queue shuffle disable failed: \(error)")
                }
                try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            }

            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.removeAllTracksFromQueue(ip: ip)

            let queueItems = plan.items.compactMap { item in
                item.playbackDescriptor.queuePayload(metadata: playbackMetadata(for: item))
            }

            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            do {
                try await SonosAPI.addMultipleURIsToQueue(ip: ip, items: queueItems)
            } catch {
                let fallbackItems = batchQueueFallbackItems(
                    from: queueItems,
                    after: error,
                    context: "Forward album")
                SonosLog.error(
                    .playback,
                    "Forward album batch queue failed, falling back " +
                        "retryCount=\(fallbackItems.count): \(error)")
                for item in fallbackItems {
                    try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                    _ = try await SonosAPI.addURIToQueue(
                        ip: ip,
                        uri: item.uri,
                        metadata: item.metadata)
                }
            }

            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.setAVTransportToQueue(
                ip: ip,
                speakerUUID: speakerUUID)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.seekToTrack(
                ip: ip,
                trackNumber: plan.targetTrackNumber)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.play(ip: ip)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

            var didSeek = false
            if sourceTrack.position > 3 {
                try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                let maxPosition = sourceTrack.duration.map {
                    max(0, min(sourceTrack.position, $0 - 2))
                } ?? sourceTrack.position
                do {
                    try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                    try await SonosAPI.seek(
                        ip: ip,
                        position: SonosTime.apiFormat(maxPosition))
                    didSeek = true
                } catch {
                    SonosLog.error(.playback, "Forward album queue seek failed: \(error)")
                }
            }

            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            try await refreshForwardHandoffState(
                selectedSpeaker: selectedSpeaker,
                backend: backend,
                manager: manager,
                loadQueue: true)
            return (true, didSeek)
        } catch let error as HandoffTransferError {
            throw error
        } catch {
            SonosLog.error(.playback, "Forward album queue handoff failed: \(error)")
            errorMessage = error.localizedDescription
            return (false, false)
        }
    }

    private func batchQueueFallbackItems(from queueItems: [SonosQueuedURI],
                                         after error: Error,
                                         context: String) -> [SonosQueuedURI] {
        guard let batchError = error as? SonosQueueBatchAddError else {
            SonosLog.info(
                .playback,
                "\(context) batch queue fallback path=fullRetry count=\(queueItems.count) " +
                    "errorType=\(type(of: error))")
            return queueItems
        }

        SonosLog.info(
            .playback,
            "\(context) batch queue fallback path=remainingRetry originalCount=\(queueItems.count) " +
                "retryCount=\(batchError.remainingItems.count) failedChunkStart=\(batchError.failedChunkStart)")
        return batchError.remainingItems
    }

    private func replaceQueueAndPlayAudioFirst(ip: String,
                                               speakerUUID: String,
                                               plan: SonosQueueReplacementPlaybackPlan,
                                               manager: SonosManager,
                                               context: String) async throws {
        replaceQueueFillTask?.cancel()
        replaceQueueFillGeneration += 1
        let generation = replaceQueueFillGeneration

        SonosLog.info(
            .playback,
            "\(context) replaceQueue audioFirst start total=\(plan.totalCount) " +
                "remaining=\(plan.remaining.count) firstURI=\(SonosLog.playbackLinkValue(plan.first.uri))")

        let removeStart = Date()
        try await SonosAPI.removeAllTracksFromQueue(ip: ip)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=remove-queue " +
                "ms=\(Int(Date().timeIntervalSince(removeStart) * 1000))")

        let addFirstStart = Date()
        let firstTrack = try await SonosAPI.addURIToQueue(
            ip: ip,
            uri: plan.first.uri,
            metadata: plan.first.metadata)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=add-first " +
                "track=\(firstTrack) ms=\(Int(Date().timeIntervalSince(addFirstStart) * 1000))")

        let setQueueStart = Date()
        try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: speakerUUID)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=set-transport-queue " +
                "ms=\(Int(Date().timeIntervalSince(setQueueStart) * 1000))")

        let seekStart = Date()
        try await SonosAPI.seekToTrack(ip: ip, trackNumber: firstTrack)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=seek-first " +
                "track=\(firstTrack) ms=\(Int(Date().timeIntervalSince(seekStart) * 1000))")

        let playStart = Date()
        try await SonosAPI.play(ip: ip)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=play-first " +
                "ms=\(Int(Date().timeIntervalSince(playStart) * 1000))")

        startReplaceQueueBackgroundFill(
            ip: ip,
            speakerUUID: speakerUUID,
            items: plan.remaining,
            manager: manager,
            generation: generation,
            context: context)
    }

    private func startReplaceQueueBackgroundFill(ip: String,
                                                 speakerUUID: String,
                                                 items: [SonosQueuedURI],
                                                 manager: SonosManager,
                                                 generation: Int,
                                                 context: String) {
        guard !items.isEmpty else {
            SonosLog.info(.playback, "\(context) replaceQueue backgroundFill skipped empty")
            replaceQueueFillTask = nil
            return
        }

        replaceQueueFillTask = Task { [weak self, weak manager] in
            guard let self, let manager else { return }
            try? await Task.sleep(for: .milliseconds(300))
            await self.fillReplaceQueueInBackground(
                ip: ip,
                speakerUUID: speakerUUID,
                items: items,
                manager: manager,
                generation: generation,
                context: context)
        }
    }

    private func fillReplaceQueueInBackground(ip: String,
                                              speakerUUID: String,
                                              items: [SonosQueuedURI],
                                              manager: SonosManager,
                                              generation: Int,
                                              context: String) async {
        guard isReplaceQueueBackgroundFillCurrent(
            ip: ip,
            generation: generation,
            speakerUUID: speakerUUID,
            manager: manager
        ) else {
            SonosLog.info(.playback, "\(context) replaceQueue backgroundFill cancelled before start")
            return
        }

        SonosLog.info(
            .playback,
            "\(context) replaceQueue backgroundFill start count=\(items.count) generation=\(generation)")

        do {
            try await SonosAPI.addMultipleURIsToQueue(ip: ip, items: items)
            SonosLog.info(
                .playback,
                "\(context) replaceQueue backgroundFill bulk success count=\(items.count)")
        } catch {
            let fallbackItems = batchQueueFallbackItems(
                from: items,
                after: error,
                context: "\(context) backgroundFill")
            SonosLog.error(
                .playback,
                "\(context) replaceQueue backgroundFill bulk failed, falling back " +
                    "retryCount=\(fallbackItems.count): \(error)")
            var addedCount = 0
            for item in fallbackItems {
                guard isReplaceQueueBackgroundFillCurrent(
                    ip: ip,
                    generation: generation,
                    speakerUUID: speakerUUID,
                    manager: manager
                ) else {
                    SonosLog.info(
                        .playback,
                        "\(context) replaceQueue backgroundFill cancelled during fallback " +
                            "added=\(addedCount)")
                    return
                }
                do {
                    _ = try await SonosAPI.addURIToQueue(
                        ip: ip,
                        uri: item.uri,
                        metadata: item.metadata)
                    addedCount += 1
                } catch {
                    SonosLog.error(
                        .playback,
                        "\(context) replaceQueue backgroundFill fallback item failed " +
                            "uri=\(SonosLog.playbackLinkValue(item.uri)) error=\(error)")
                }
            }
            SonosLog.info(
                .playback,
                "\(context) replaceQueue backgroundFill fallback finished " +
                    "added=\(addedCount)/\(fallbackItems.count)")
        }

        guard isReplaceQueueBackgroundFillCurrent(
            ip: ip,
            generation: generation,
            speakerUUID: speakerUUID,
            manager: manager
        ) else {
            SonosLog.info(.playback, "\(context) replaceQueue backgroundFill cancelled after fill")
            return
        }
        await manager.loadQueue()
    }

    private func isReplaceQueueBackgroundFillCurrent(ip: String,
                                                     generation: Int,
                                                     speakerUUID: String,
                                                     manager: SonosManager) -> Bool {
        !Task.isCancelled
            && replaceQueueFillGeneration == generation
            && manager.selectedSpeaker?.id == speakerUUID
            && manager.selectedSpeaker?.playbackIP == ip
    }

    private func playCloudForwardTrack(
        item: BrowseItem,
        token: String,
        groupId: String,
        backend: SonosControl.Backend,
        selectedSpeaker: SonosPlayer,
        manager: SonosManager
    ) async throws -> Bool {
        pushRecentlyPlayed(item)
        guard let uri = item.playbackDescriptor.directURI else {
            SonosLog.error(.playback, "Cloud forward handoff: no URI for '\(item.title)'")
            errorMessage = "The Apple Music track could not be loaded remotely."
            return false
        }

        do {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            SonosLog.debug(.playback, "remote forward handoff -> loadStreamUrl(\(item.id))")
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosCloudAPI.loadStreamUrl(
                token: token,
                groupId: groupId,
                streamUrl: uri,
                itemId: item.id)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            try await refreshForwardHandoffState(
                selectedSpeaker: selectedSpeaker,
                backend: backend,
                manager: manager,
                loadQueue: false)
            return true
        } catch let error as HandoffTransferError {
            throw error
        } catch {
            SonosLog.error(.playback, "Cloud forward handoff loadStreamUrl failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func playForwardSingleTrack(
        item: BrowseItem,
        selectedSpeaker: SonosPlayer,
        backend: SonosControl.Backend,
        manager: SonosManager
    ) async throws -> Bool {
        guard case .lan(let ip, _, let speakerUUID) = backend else { return false }

        pushRecentlyPlayed(item)
        let metadata = playbackMetadata(for: item)
        guard let payload = item.playbackDescriptor.queuePayload(metadata: metadata) else {
            SonosLog.error(.playback, "Forward handoff: no URI for '\(item.title)'")
            return false
        }

        do {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try? await SonosAPI.removeAllTracksFromQueue(ip: ip)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            let trackNr = try await SonosAPI.addURIToQueue(
                ip: ip,
                uri: payload.uri,
                metadata: payload.metadata)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: speakerUUID)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.seekToTrack(ip: ip, trackNumber: trackNr)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.play(ip: ip)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            SonosLog.info(.playback, "forward handoff queue '\(item.title)' -> track \(trackNr)")

            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            try await refreshForwardHandoffState(
                selectedSpeaker: selectedSpeaker,
                backend: backend,
                manager: manager,
                loadQueue: true)
            return true
        } catch let error as HandoffTransferError {
            throw error
        } catch {
            SonosLog.error(.playback, "Forward handoff play failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    func transferAppleMusicTrack(
        _ track: AppleMusicHandoffTrack,
        manager: SonosManager
    ) async throws -> HandoffResult {
        guard let selectedSpeaker = manager.selectedSpeaker else {
            throw HandoffTransferError.noSelectedSpeaker
        }
        configure(speakerIP: selectedSpeaker.playbackIP)

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            throw HandoffTransferError.sonosCloudDisconnected
        }
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        if !hasProbed {
            await probeLinkedServices()
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        }
        await refreshServiceIdMappingIfNeeded()
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        guard let appleMusicAccount = linkedAccounts.first(where: { isAppleMusicAccount($0) }),
              let serviceId = appleMusicAccount.serviceId,
              let accountId = appleMusicAccount.accountId else {
            throw HandoffTransferError.appleMusicNotLinkedOnSonos
        }

        let term = "\(track.title) \(track.artist)"
        let response = try await searchServiceWithTokenRefresh(
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId,
            term: term)
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        let cloudCandidates = response.allResources.compactMap { resource -> ForwardCloudTrackCandidate? in
            guard resource.type == "TRACK",
                  let item = convertToBrowseItem(resource, serviceId: serviceId, accountId: accountId) else {
                return nil
            }
            return ForwardCloudTrackCandidate(resource: resource, item: item)
        }
        let candidates = cloudCandidates.map(\.item)

        guard !candidates.isEmpty else {
            throw HandoffTransferError.noConfidentMatch
        }

        guard let match = HandoffMatcher.bestMatch(for: track, candidates: candidates),
              let matchedCloudCandidate = cloudCandidates.first(where: { $0.item == match.item }) else {
            throw HandoffTransferError.noConfidentMatch
        }

        let previousError = errorMessage
        errorMessage = nil
        let transferControlBackend = try await forwardHandoffControlBackend(
            selectedSpeaker: selectedSpeaker,
            manager: manager)
        var albumPlaybackError: String?
        if let albumAttempt = await forwardAlbumQueueAttempt(
            sourceTrack: track,
            matchedCandidate: matchedCloudCandidate,
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId,
            backend: transferControlBackend) {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            let albumPlayback = try await playForwardAlbumQueue(
                albumAttempt.plan,
                sourceTrack: track,
                selectedSpeaker: selectedSpeaker,
                backend: transferControlBackend,
                manager: manager)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            if albumPlayback.played {
                return HandoffResult(
                    matchedTitle: match.item.title,
                    targetName: selectedSpeaker.name,
                    seeked: albumPlayback.seeked,
                    transferredTrackCount: albumAttempt.plan.transferredTrackCount,
                    skippedUnsupportedItemCount: albumAttempt.plan.skippedUnsupportedItemCount,
                    warningMessage: nil,
                    usedAlbumQueue: true)
            }

            // Album queue sync is best-effort; do not leave its error visible if single-track fallback succeeds.
            albumPlaybackError = errorMessage
            errorMessage = nil
        }

        let played: Bool
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        switch transferControlBackend {
        case .cloud(let groupId, let cloudToken, _, _):
            played = try await playCloudForwardTrack(
                item: match.item,
                token: cloudToken,
                groupId: groupId,
                backend: transferControlBackend,
                selectedSpeaker: selectedSpeaker,
                manager: manager)
        case .lan:
            played = try await playForwardSingleTrack(
                item: match.item,
                selectedSpeaker: selectedSpeaker,
                backend: transferControlBackend,
                manager: manager)
        }
        guard played else {
            throw HandoffTransferError.sonosPlaybackFailed(
                errorMessage ?? albumPlaybackError ?? previousError ?? "Couldn’t start playback on Sonos.")
        }

        var didSeek = false
        if track.position > 3 {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            let maxPosition = track.duration.map {
                max(0, min(track.position, $0 - 2))
            } ?? track.position
            do {
                switch transferControlBackend {
                case .cloud(let groupId, let cloudToken, _, _):
                    try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                    try await SonosCloudAPI.seek(
                        token: cloudToken, groupId: groupId,
                        positionMillis: Int((maxPosition * 1000.0).rounded()))
                case .lan(let ip, _, _):
                    try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                    try await SonosAPI.seek(
                        ip: ip,
                        position: SonosTime.apiFormat(maxPosition))
                }
                didSeek = true
            } catch {
                SonosLog.error(.playback, "Forward single-track handoff seek failed: \(error)")
            }
        }

        try await refreshForwardHandoffState(
            selectedSpeaker: selectedSpeaker,
            backend: transferControlBackend,
            manager: manager,
            loadQueue: false)
        let warningMessage: String?
        switch transferControlBackend {
        case .cloud:
            warningMessage = "Queue sync requires the same network"
        case .lan:
            warningMessage = nil
        }

        return HandoffResult(
            matchedTitle: match.item.title,
            targetName: selectedSpeaker.name,
            seeked: didSeek,
            transferredTrackCount: 1,
            skippedUnsupportedItemCount: 0,
            warningMessage: warningMessage,
            usedAlbumQueue: false)
    }

    func transferSonosAppleMusicToPhone(
        manager: SonosManager
    ) async throws -> ReverseHandoffResult {
        guard let selectedSpeaker = manager.selectedSpeaker else {
            throw ReverseHandoffError.noSelectedSpeaker
        }
        configure(speakerIP: selectedSpeaker.playbackIP)

        if let trackInfo = manager.trackInfo,
           isKnownNonAppleSource(trackInfo) {
            throw ReverseHandoffError.notAppleMusicSource
        }

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            throw ReverseHandoffError.sonosCloudDisconnected
        }
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        guard let backend = await manager.controlBackendEnsured() else {
            throw ReverseHandoffError.noBackend
        }
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        if !hasProbed {
            await probeLinkedServices()
            try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        }
        await refreshServiceIdMappingIfNeeded()
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        await manager.refreshState()
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        guard let trackInfo = manager.trackInfo else {
            throw ReverseHandoffError.missingSonosTrackMetadata
        }

        guard isAppleMusicTrack(trackInfo) else {
            throw ReverseHandoffError.notAppleMusicSource
        }

        let track = try reverseSourceTrack(from: trackInfo)
        let storeID = try await resolveAppleMusicStoreID(
            for: track,
            trackInfo: trackInfo,
            token: token,
            householdId: householdId)

        let queuePlan = await reverseHandoffQueuePlan(
            manager: manager,
            selectedSpeaker: selectedSpeaker,
            currentTrackInfo: trackInfo,
            currentStoreID: storeID)
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        let playbackStoreIDs = queuePlan?.storeIDs ?? [storeID]
        try await AppleMusicHandoffManager.shared.playAppleMusicQueue(
            storeIDs: playbackStoreIDs,
            position: track.position)

        var paused = true
        var warning: String?
        do {
            try await SonosControl.pause(backend)
        } catch {
            paused = false
            warning = "Playing on iPhone. Couldn’t pause Sonos."
            SonosLog.error(.playback, "Reverse handoff Sonos pause failed: \(error)")
        }

        await manager.refreshState()
        return ReverseHandoffResult(
            matchedTitle: track.title,
            targetName: selectedSpeaker.name,
            seeked: track.position > 3,
            sonosPaused: paused,
            warningMessage: warning,
            transferredTrackCount: queuePlan?.transferredTrackCount ?? 1,
            skippedUnsupportedItemCount: queuePlan?.skippedUnsupportedItemCount ?? 0)
    }

    private func reverseHandoffQueuePlan(
        manager: SonosManager,
        selectedSpeaker: SonosPlayer,
        currentTrackInfo: TrackInfo,
        currentStoreID: String
    ) async -> AppleMusicQueueHandoffPlan? {
        guard manager.isPlayingFromQueue else { return nil }

        async let queueResultTask = reverseHandoffQueueResult(ip: selectedSpeaker.playbackIP)
        async let currentTrackNumberTask = reverseHandoffCurrentTrackNumber(
            ip: selectedSpeaker.playbackIP)
        let (queueResult, currentTrackNumber) = await (queueResultTask, currentTrackNumberTask)

        guard let queue = queueResult?.items, !queue.isEmpty else { return nil }
        return AppleMusicQueueHandoffPlanner.makePlan(
            queue: queue,
            currentTrackNumber: currentTrackNumber,
            currentTrackInfo: currentTrackInfo,
            currentStoreID: currentStoreID)
    }

    private func reverseHandoffQueueResult(ip: String) async -> QueueResult? {
        do {
            return try await SonosAPI.getQueue(ip: ip)
        } catch {
            SonosLog.error(.playback, "Reverse handoff queue lookup failed: \(error)")
            return nil
        }
    }

    private func reverseHandoffCurrentTrackNumber(ip: String) async -> Int? {
        do {
            return try await SonosAPI.getCurrentTrackNumber(ip: ip)
        } catch {
            SonosLog.error(.playback, "Reverse handoff queue track number lookup failed: \(error)")
            return nil
        }
    }

    private func isAppleMusicAccount(_ account: SonosCloudAPI.CloudMusicServiceAccount) -> Bool {
        let values = [
            account.name,
            account.nickname,
            account.integrationId,
            account.username
        ]
        return values.contains { value in
            guard let value else { return false }
            let normalized = value
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            return normalized.contains("apple music") || normalized.contains("applemusic")
        }
    }

    private func ensureReverseHandoffTargetStillSelected(
        _ selectedSpeaker: SonosPlayer,
        manager: SonosManager
    ) throws {
        guard manager.selectedSpeaker?.id == selectedSpeaker.id else {
            throw ReverseHandoffError.noSelectedSpeaker
        }
    }

    private func ensureForwardHandoffTargetStillSelected(
        _ selectedSpeaker: SonosPlayer,
        manager: SonosManager
    ) throws {
        guard manager.selectedSpeaker?.id == selectedSpeaker.id else {
            throw HandoffTransferError.noSelectedSpeaker
        }
    }

    private func refreshForwardHandoffState(
        selectedSpeaker: SonosPlayer,
        backend: SonosControl.Backend,
        manager: SonosManager,
        loadQueue: Bool
    ) async throws {
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        let stillSelected = await manager.refreshState(
            usingLockedBackend: backend,
            expectedSpeakerID: selectedSpeaker.id,
            loadQueue: loadQueue)
        guard stillSelected else {
            throw HandoffTransferError.noSelectedSpeaker
        }
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
    }

    private func forwardHandoffControlBackend(
        selectedSpeaker: SonosPlayer,
        manager: SonosManager
    ) async throws -> SonosControl.Backend {
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        if manager.transportBackend == .unknown {
            _ = await manager.probeBackend()
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        }

        if manager.transportBackend == .cloud, manager.currentCloudGroupId == nil {
            await manager.resolveCloudGroupId()
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        }

        if let backend = manager.currentControlBackend() {
            return backend
        }

        if let backend = await manager.controlBackendEnsured() {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            return backend
        }

        throw HandoffTransferError.noBackend
    }

    private func reverseSourceTrack(from trackInfo: TrackInfo) throws -> AppleMusicHandoffTrack {
        let title = trackInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = trackInfo.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            throw ReverseHandoffError.missingSonosTrackMetadata
        }

        let album = trackInfo.album.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppleMusicHandoffTrack(
            title: title,
            artist: artist,
            album: album.isEmpty ? nil : album,
            duration: trackInfo.durationSeconds > 0 ? trackInfo.durationSeconds : nil,
            position: max(0, trackInfo.positionSeconds),
            playbackStoreID: directAppleMusicStoreID(from: trackInfo.trackURI),
            persistentID: nil)
    }

    private func directAppleMusicStoreID(from trackURI: String?) -> String? {
        guard let objectID = SonosAppleMusicTrackResolver
            .trackObjectIDForNowPlaying(fromTrackURI: trackURI),
              let storeID = SonosAppleMusicTrackResolver.storeID(fromObjectID: objectID) else {
            return nil
        }

        guard storeID != objectID else {
            return nil
        }
        return storeID
    }

    private func isKnownNonAppleSource(_ trackInfo: TrackInfo) -> Bool {
        trackInfo.source != .unknown && trackInfo.source != .appleMusic
    }

    private func isAppleMusicTrack(_ trackInfo: TrackInfo) -> Bool {
        if trackInfo.source == .appleMusic {
            return true
        }

        guard let trackURI = trackInfo.trackURI else { return false }
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(trackURI)
        guard let localServiceID = parsed.localServiceID,
              let cloudServiceID = cloudServiceId(forLocalSid: localServiceID),
              let account = linkedAccounts.first(where: { $0.serviceId == cloudServiceID }) else {
            return false
        }
        return isAppleMusicAccount(account)
    }

    private func sourceAppleMusicAccount(
        from trackInfo: TrackInfo
    ) -> SonosCloudAPI.CloudMusicServiceAccount? {
        guard let trackURI = trackInfo.trackURI else { return nil }
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(trackURI)
        guard let localServiceID = parsed.localServiceID,
              let cloudServiceID = cloudServiceId(forLocalSid: localServiceID) else {
            return nil
        }

        if let accountID = parsed.accountID,
           let exactAccount = linkedAccounts.first(where: {
               $0.serviceId == cloudServiceID &&
               $0.accountId == accountID &&
               isAppleMusicAccount($0)
           }) {
            return exactAccount
        }

        return linkedAccounts.first {
            $0.serviceId == cloudServiceID && isAppleMusicAccount($0)
        }
    }

    private func resolveAppleMusicStoreID(
        for track: AppleMusicHandoffTrack,
        trackInfo: TrackInfo,
        token: String,
        householdId: String
    ) async throws -> String {
        if let storeID = track.playbackStoreID {
            return storeID
        }

        if let nowPlayingStoreID = try await nowPlayingStoreID(
            trackInfo: trackInfo,
            token: token,
            householdId: householdId) {
            return nowPlayingStoreID
        }

        return try await searchMatchedStoreID(
            for: track,
            token: token,
            householdId: householdId,
            preferredAccount: sourceAppleMusicAccount(from: trackInfo))
    }

    private func nowPlayingStoreID(
        trackInfo: TrackInfo,
        token: String,
        householdId: String
    ) async throws -> String? {
        guard let trackURI = trackInfo.trackURI else { return nil }
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(trackURI)
        guard let localServiceID = parsed.localServiceID,
              let serviceId = cloudServiceId(forLocalSid: localServiceID),
              let accountId = parsed.accountID,
              let trackObjectID = SonosAppleMusicTrackResolver
                .cloudTrackObjectIDForNowPlaying(fromTrackURI: trackURI) else {
            return nil
        }

        do {
            let response = try await SonosCloudAPI.nowPlaying(
                token: token,
                householdId: householdId,
                serviceId: serviceId,
                accountId: accountId,
                trackObjectId: trackObjectID)
            let objectID = response.item?.resource?.id?.objectId ?? response.item?.id
            return SonosAppleMusicTrackResolver.storeID(fromObjectID: objectID)
        } catch {
            SonosLog.error(.nowPlaying, "Reverse handoff nowPlaying lookup failed: \(error)")
            return nil
        }
    }

    private func forwardAlbumId(
        from matchedResource: SonosCloudAPI.CloudResource,
        matchedItem: BrowseItem,
        token: String,
        householdId: String,
        serviceId: String,
        accountId: String
    ) async -> String? {
        if let containerId = browseAlbumId(from: matchedResource.container?.id?.objectId),
           !containerId.isEmpty {
            SonosLog.info(.playback, "Forward album id from search container: \(containerId)")
            return containerId
        }

        let trackObjectId = SonosAppleMusicTrackResolver
            .cloudTrackObjectIDForNowPlaying(fromTrackURI: matchedItem.uri)
            ?? matchedResource.id?.objectId
            ?? matchedItem.id
        let cleanedTrackObjectId = browseTrackId(from: trackObjectId)
        guard !cleanedTrackObjectId.isEmpty else { return nil }

        do {
            let response = try await SonosCloudAPI.nowPlaying(
                token: token,
                householdId: householdId,
                serviceId: serviceId,
                accountId: accountId,
                trackObjectId: cleanedTrackObjectId)
            let albumId = browseAlbumId(from: response.item?.albumId)
            SonosLog.info(
                .playback,
                "Forward album id from nowPlaying trackId='\(cleanedTrackObjectId)': \(albumId ?? "nil")")
            return albumId
        } catch {
            SonosLog.error(.nowPlaying, "Forward handoff album lookup failed: \(error)")
            return nil
        }
    }

    private func browseAlbumId(from rawId: String?) -> String? {
        guard let rawId else { return nil }
        let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.firstIndex(of: "#").map { String(trimmed[..<$0]) } ?? trimmed
        let parts = base.components(separatedBy: ":")
        guard let albumIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("album") == .orderedSame }),
              albumIndex < parts.index(before: parts.endIndex) else {
            return base
        }
        return parts[albumIndex...].joined(separator: ":")
    }

    private func browseTrackId(from rawId: String?) -> String {
        guard let rawId else { return "" }
        let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let base = trimmed.firstIndex(of: "#").map { String(trimmed[..<$0]) } ?? trimmed
        let parts = base.components(separatedBy: ":")
        guard let trackIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("track") == .orderedSame }),
              trackIndex < parts.index(before: parts.endIndex) else {
            return base
        }
        return parts[trackIndex...].joined(separator: ":")
    }

    private func searchMatchedStoreID(
        for track: AppleMusicHandoffTrack,
        token: String,
        householdId: String,
        preferredAccount: SonosCloudAPI.CloudMusicServiceAccount?
    ) async throws -> String {
        let account = preferredAccount ?? linkedAccounts.first(where: { isAppleMusicAccount($0) })
        guard let appleMusicAccount = account,
              let serviceId = appleMusicAccount.serviceId,
              let accountId = appleMusicAccount.accountId else {
            throw ReverseHandoffError.appleMusicNotLinkedOnSonos
        }

        let term = "\(track.title) \(track.artist)"
        let response = try await searchServiceWithTokenRefresh(
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId,
            term: term)

        let candidates = response.allResources.compactMap { resource -> BrowseItem? in
            guard resource.type == "TRACK" else { return nil }
            return convertToBrowseItem(resource, serviceId: serviceId, accountId: accountId)
        }

        guard let match = HandoffMatcher.bestMatch(for: track, candidates: candidates),
              let storeID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: match.item) else {
            throw ReverseHandoffError.noConfidentMatch
        }
        return storeID
    }

    func playNow(item: BrowseItem, manager: SonosManager) async {
        _ = await playNowInternal(item: item, manager: manager)
    }

    @discardableResult
    func playNow(
        items: [BrowseItem],
        manager: SonosManager,
        displayTitle: String
    ) async -> Bool {
        let queueableItems = items.filter { item in
            item.playbackDescriptor.isQueueable
        }
        guard !queueableItems.isEmpty else {
            errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
            return false
        }

        guard !manager.isRemoteMode else {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Playing this item")
                .localizedDescription
            return false
        }
        guard let speaker = manager.selectedSpeaker else {
            errorMessage = HandoffTransferError.noSelectedSpeaker.localizedDescription
            return false
        }

        let ip = speaker.playbackIP
        let speakerUUID = speaker.id
        let queueItems = queueableItems.compactMap {
            $0.playbackDescriptor.queuePayload(metadata: playbackMetadata(for: $0))
        }
        guard let replacementPlan = SonosQueueReplacementPlaybackPlan(items: queueItems) else {
            errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
            return false
        }
        schedulePlaybackArtworkPrewarm(for: queueableItems)
        SonosLog.debug(
            .playbackLink,
            "playNow displayed-tracks start title='\(displayTitle)' count=\(queueItems.count) " +
                "speaker=\(ip) firstURI=\(SonosLog.playbackLinkValue(queueItems.first?.uri)) " +
                "lastURI=\(SonosLog.playbackLinkValue(queueItems.last?.uri)) " +
                "firstMetadata=\(queueItems.first.map { SonosLog.playbackMetadataSummary($0.metadata) } ?? "nil")")

        if let first = queueableItems.first {
            pushRecentlyPlayed(first)
        }

        do {
            try await replaceQueueAndPlayAudioFirst(
                ip: ip,
                speakerUUID: speakerUUID,
                plan: replacementPlan,
                manager: manager,
                context: "playNow '\(displayTitle)'")
            SonosLog.info(
                .playback,
                "playNow displayed tracks '\(displayTitle)' count=\(queueItems.count) " +
                    "mode=audioFirst remaining=\(replacementPlan.remaining.count)")
            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            await manager.refreshState()
            return true
        } catch {
            SonosLog.error(.playback, "playNow displayed tracks failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func playNowInternal(
        item: BrowseItem,
        manager: SonosManager,
        lockedTarget: SonosPlayer? = nil,
        recordRecentlyPlayed: Bool = true
    ) async -> Bool {
        // Push to recents before any await so a failed play still records
        // intent (mirrors Apple Music's "attempted plays" behaviour).
        if recordRecentlyPlayed {
            pushRecentlyPlayed(item)
        }
        schedulePlaybackArtworkPrewarm(for: item)
        let activeSpeaker = lockedTarget ?? manager.selectedSpeaker
        let activeBackend = manager.transportBackend
        let activeCloudGroupId = manager.currentCloudGroupId

        // Remote mode: if the item is a cloud-sourced favorite, use the
        // Control API's `loadFavorite` instead of the UPnP SetAVTransportURI
        // / queue path (which doesn't work off-LAN).
        if activeBackend == .cloud,
           let favId = item.cloudFavoriteId,
           let token = await SonosAuth.shared.validAccessToken(),
           let gid = activeCloudGroupId {
            do {
                SonosLog.debug(.playback, "remote playNow → loadFavorite(\(favId))")
                try await SonosCloudAPI.loadFavorite(token: token, groupId: gid,
                                                    favoriteId: favId)
                try? await Task.sleep(for: .milliseconds(800))
                await manager.refreshState()
                return true
            } catch {
                SonosLog.error(.playback, "loadFavorite failed: \(error)")
                errorMessage = error.localizedDescription
                return false
            }
        }

        if item.isArtist {
            return await startStation(item: item, manager: manager)
        }

        // Everything below this line uses UPnP — gate on .cloud mode so users
        // get a friendly "Requires LAN" error instead of a silent timeout.
        if activeBackend == .cloud {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Playing this item")
                .localizedDescription
            return false
        }

        guard let ip = activeSpeaker?.playbackIP else {
            SonosLog.error(.playback, "playNow: no speaker IP")
            return false
        }

        var playMeta = playbackMetadata(for: item)

        // For favorites, the resMD DIDL often lacks albumArtURI — inject it from
        // the browse item so Sonos records proper cover art in "recently played".
        if item.id.hasPrefix("FV:") {
            playMeta = enrichMetadataWithArt(playMeta, artURL: item.albumArtURL)
        }

        let fallbackURI: String?
        if item.playbackDescriptor.directURI == nil, let resMD = item.resMD {
            fallbackURI = constructFavoriteURI(resMD: resMD)
        } else {
            fallbackURI = nil
        }

        guard let playPayload = item.playbackDescriptor.transportPayload(
            metadata: playMeta,
            fallbackURI: fallbackURI
        ) else {
            SonosLog.error(.playback, "playNow: no URI for '\(item.title)'")
            return false
        }
        let uri = playPayload.uri
        playMeta = playPayload.metadata

        let metadataId = extractDIDLItemId(from: playMeta) ?? "nil"
        let metadataDesc = SonosAPI.extractTag("desc", from: playMeta) ?? "nil"
        SonosLog.info(
            .playback,
            "playNow enqueue title='\(item.title)' cloudType=\(item.cloudType ?? "nil") " +
            "itemId=\(item.id) serviceId=\(item.serviceId.map(String.init) ?? "nil") " +
            "uri=\(uri) metadataId=\(metadataId) desc=\(metadataDesc)")
        SonosLog.debug(
            .playbackLink,
            "playNow resolved title='\(item.title)' cloudType=\(item.cloudType ?? "nil") " +
                "itemId=\(SonosLog.playbackLinkValue(item.id, maxLength: 640)) " +
                "serviceId=\(item.serviceId.map(String.init) ?? "nil") " +
                "isContainer=\(item.isContainer) uri=\(SonosLog.playbackLinkValue(uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(playMeta))")
        let playNowStart = Date()

        do {
            guard let uuid = activeSpeaker?.id else {
                SonosLog.error(.playback, "playNow: no speaker UUID")
                return false
            }

            let isRadio = uri.contains("x-sonosapi-radio:")
                || uri.contains("x-sonosapi-stream:")
                || uri.contains("x-sonosapi-hls:")

            if isRadio {
                let setURIStart = Date()
                try await SonosAPI.setAVTransportURI(ip: ip, uri: uri, metadata: playMeta)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=set-radio-uri " +
                    "ms=\(Int(Date().timeIntervalSince(setURIStart) * 1000))")
                let playStart = Date()
                try await SonosAPI.play(ip: ip)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=radio-play " +
                    "ms=\(Int(Date().timeIntervalSince(playStart) * 1000))")
                SonosLog.info(.playback, "playNow radio '\(item.title)'")
            } else {
                // Both container and single-track paths take the same shape
                // — only the source URI differs. Fold them to keep the log
                // story simple ("playNow queue → track N").
                let removeStart = Date()
                try? await SonosAPI.removeAllTracksFromQueue(ip: ip)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=remove-queue " +
                    "ms=\(Int(Date().timeIntervalSince(removeStart) * 1000))")
                let addStart = Date()
                let trackNr = try await SonosAPI.addURIToQueue(ip: ip, uri: uri, metadata: playMeta)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=add-uri-to-queue " +
                    "ms=\(Int(Date().timeIntervalSince(addStart) * 1000))")
                let setQueueStart = Date()
                try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: uuid)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=set-transport-queue " +
                    "ms=\(Int(Date().timeIntervalSince(setQueueStart) * 1000))")
                let seekStart = Date()
                try await SonosAPI.seekToTrack(ip: ip, trackNumber: trackNr)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=seek-track " +
                    "ms=\(Int(Date().timeIntervalSince(seekStart) * 1000))")
                let playStart = Date()
                try await SonosAPI.play(ip: ip)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=queue-play " +
                    "ms=\(Int(Date().timeIntervalSince(playStart) * 1000))")
                SonosLog.info(.playback, "playNow queue '\(item.title)' → track \(trackNr)")
            }

            let settleStart = Date()
            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            SonosLog.info(
                .playback,
                "playNow timing title='\(item.title)' step=settle-delay " +
                "ms=\(Int(Date().timeIntervalSince(settleStart) * 1000))")
            let refreshStart = Date()
            await manager.refreshState()
            SonosLog.info(
                .playback,
                "playNow timing title='\(item.title)' step=refresh-state " +
                "ms=\(Int(Date().timeIntervalSince(refreshStart) * 1000)) " +
                "totalMs=\(Int(Date().timeIntervalSince(playNowStart) * 1000))")
            return true
        } catch {
            SonosLog.error(.playback, "playNow failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }


    @discardableResult
    func playNext(item: BrowseItem, manager: SonosManager) async -> Bool {
        schedulePlaybackArtworkPrewarm(for: item)
        // Queue insertion is LAN-only (Cloud Control API has no per-track
        // queue API). Show a friendly message instead of a stale timeout.
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Adding to the queue")
                .localizedDescription
            return false
        }
        let metadata = playbackMetadata(for: item)
        guard let payload = item.playbackDescriptor.queuePayload(metadata: metadata) else {
            errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
            return false
        }
        SonosLog.debug(
            .playbackLink,
            "playNext item title='\(item.title)' cloudType=\(item.cloudType ?? "nil") " +
                "itemId=\(SonosLog.playbackLinkValue(item.id, maxLength: 640)) " +
                "serviceId=\(item.serviceId.map(String.init) ?? "nil") " +
                "isContainer=\(item.isContainer) uri=\(SonosLog.playbackLinkValue(payload.uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(payload.metadata))")
        return await manager.playNext(uri: payload.uri, metadata: payload.metadata)
    }

    /// Start a personalized radio station from an artist.
    /// Searches Cloud API for the artist's Apple Music ID, then constructs radio:ra.{id}
    /// — the same format the official Sonos app uses for "Start Station".
    @discardableResult
    func startStation(item: BrowseItem, manager: SonosManager) async -> Bool {
        // Push to recents before network work so Browse shows the entry
        // even if cloud search below fails. Dedupes by id — safe to repeat.
        pushRecentlyPlayed(item)

        guard let ip = manager.selectedSpeaker?.playbackIP else {
            SonosLog.error(.station, "startStation: no speaker IP")
            return false
        }

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            SonosLog.error(.station, "startStation: no Cloud auth")
            errorMessage = "Not logged in to Sonos Cloud"
            return false
        }

        if !hasProbed { await probeLinkedServices() }
        let serviceIds = activeServiceIds
        guard !serviceIds.isEmpty else {
            SonosLog.error(.station, "startStation: no active services")
            errorMessage = "No music services linked"
            return false
        }

        do {
            let response = try await SonosCloudAPI.searchCatalog(
                token: token, householdId: householdId,
                term: item.title, serviceIds: serviceIds)

            // Find the ARTIST result to get the Apple Music artist ID
            var artistId: String?
            var cloudServiceId: String?
            var cloudAccountId: String?
            var artistArtURL: String?

            for svc in response.services ?? [] {
                for resource in svc.resources ?? [] {
                    let type = resource.type ?? ""
                    let objId = resource.id?.objectId ?? ""
                    let name = resource.name ?? ""

                    if type == "ARTIST" && name.localizedCaseInsensitiveCompare(item.title) == .orderedSame {
                        // Extract the numeric ID: "artist:137938148" → "137938148"
                        artistId = objId.replacingOccurrences(of: "artist:", with: "")
                        cloudServiceId = svc.serviceId
                        cloudAccountId = svc.accountId
                        artistArtURL = resource.images?.first?.url ?? item.albumArtURL
                        break
                    }
                }
                if artistId != nil { break }
            }

            // Fallback: take any ARTIST result if exact name match failed
            if artistId == nil {
                for svc in response.services ?? [] {
                    for resource in svc.resources ?? [] {
                        if resource.type == "ARTIST", let objId = resource.id?.objectId,
                           objId.hasPrefix("artist:") {
                            artistId = objId.replacingOccurrences(of: "artist:", with: "")
                            cloudServiceId = svc.serviceId
                            cloudAccountId = svc.accountId
                            artistArtURL = resource.images?.first?.url ?? item.albumArtURL
                            break
                        }
                    }
                    if artistId != nil { break }
                }
            }

            guard let amArtistId = artistId else {
                SonosLog.error(.station, "No artist found in search results")
                errorMessage = "Could not find artist \(item.title)"
                return false
            }

            // Construct radio:ra.{artist_id} — this is the "Start Station" format
            let radioId = "radio:ra.\(amArtistId)"
            let stationName = "\(item.title) Radio"

            return await playRadioStation(
                ip: ip, radioId: radioId, stationName: stationName,
                cloudServiceId: cloudServiceId, accountId: cloudAccountId,
                artURL: artistArtURL, resMD: item.resMD, manager: manager)

        } catch {
            SonosLog.error(.station, "startStation failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Play a selected radio station option (from station picker).
    func playStationOption(_ option: RadioStationOption, manager: SonosManager) async {
        guard let ip = manager.selectedSpeaker?.playbackIP else { return }
        _ = await playRadioStation(
            ip: ip, radioId: option.id, stationName: option.name,
            cloudServiceId: option.cloudServiceId, accountId: option.accountId,
            artURL: option.artURL, resMD: option.resMD, manager: manager)
    }

    /// Play a resolved radio station via UPnP.
    private func playRadioStation(ip: String, radioId: String, stationName: String,
                                  streamObjectID: String? = nil,
                                  isLiveStreamStation: Bool = false,
                                  cloudServiceId: String?, accountId: String?,
                                  artURL: String?, resMD: String?,
                                  manager: SonosManager) async -> Bool {
        let payloads = stationTransportPayloads(
            radioId: radioId,
            streamObjectID: streamObjectID,
            isLiveStreamStation: isLiveStreamStation,
            stationName: stationName,
            cloudServiceId: cloudServiceId,
            accountId: accountId,
            artURL: artURL,
            resMD: resMD)
        var lastError: Error?

        for (index, payload) in payloads.enumerated() {
            let metadataId = extractDIDLItemId(from: payload.metadata) ?? "nil"
            let metadataDesc = extractDescTag(from: payload.metadata) ?? "nil"
            let hasArt = payload.metadata.contains("<upnp:albumArtURI>")
            SonosLog.info(
                .station,
                "playRadioStation request title='\(stationName)' label=\(payload.label) " +
                    "attempt=\(index + 1)/\(payloads.count) radioId=\(radioId) " +
                    "streamObjectID=\(streamObjectID ?? "nil") uri=\(payload.uri) " +
                    "metadataId=\(metadataId) desc=\(metadataDesc) art=\(hasArt)")

            do {
                try await SonosAPI.setAVTransportURI(ip: ip, uri: payload.uri, metadata: payload.metadata)
                try? await Task.sleep(for: .milliseconds(stationSetURISettleMs))
                try await SonosAPI.play(ip: ip)

                try? await Task.sleep(for: .milliseconds(stationPlayConfirmMs))
                let state = try? await SonosAPI.getTransportInfo(ip: ip)

                if state == .stopped {
                    // Some stations need a second nudge: first Play is acked,
                    // but Sonos sits in STOPPED until the cloud resolves the
                    // actual stream URL.
                    SonosLog.info(.station, "still STOPPED, retrying play label=\(payload.label)")
                    try? await Task.sleep(for: .milliseconds(stationRetryDelayMs))
                    try await SonosAPI.play(ip: ip)
                    try? await Task.sleep(for: .milliseconds(stationRetryDelayMs))
                }

                SonosLog.info(
                    .station,
                    "playRadioStation '\(stationName)' label=\(payload.label) uri=\(payload.uri)")
                await manager.refreshState()
                return true
            } catch {
                lastError = error
                SonosLog.error(
                    .station,
                    "playRadioStation failed label=\(payload.label) uri=\(payload.uri): \(error)")
            }
        }

        errorMessage = lastError?.localizedDescription
        return false
    }

    func stationTransportPayloads(
        radioId: String,
        streamObjectID: String?,
        isLiveStreamStation: Bool = false,
        stationName: String,
        cloudServiceId: String?,
        accountId: String?,
        artURL: String?,
        resMD: String?
    ) -> [StationTransportPayload] {
        var payloads: [StationTransportPayload] = []

        if isLiveStreamStation,
           let hlsObjectID = hlsStationObjectID(from: radioId) {
            payloads.append(
                stationTransportPayload(
                    radioId: hlsObjectID,
                    stationName: stationName,
                    cloudServiceId: cloudServiceId,
                    accountId: accountId,
                    artURL: artURL,
                    resMD: resMD,
                    uriScheme: "x-sonosapi-stream",
                    flags: SonosRinconLiveStationFlags,
                    metadataStyle: .hlsLiveRadio,
                    label: "hlsLiveRadio"))
        }

        payloads.append(
            stationTransportPayload(
                radioId: radioId,
                stationName: stationName,
                cloudServiceId: cloudServiceId,
                accountId: accountId,
                artURL: artURL,
                resMD: resMD,
                uriScheme: "x-sonosapi-radio",
                metadataStyle: .programRadio,
                label: "radioID"))

        return payloads
    }

    func stationTransportPayload(
        radioId: String,
        stationName: String,
        cloudServiceId: String?,
        accountId: String?,
        artURL: String?,
        resMD: String?,
        uriScheme: String = "x-sonosapi-radio",
        flags: Int = SonosRinconRadioFlags,
        metadataStyle: StationTransportMetadataStyle = .programRadio,
        label: String = "radioID"
    ) -> StationTransportPayload {
        let localSid = cloudServiceId.flatMap { cloudToLocalSid[$0] }
        let params = extractServiceParams()
        let sidInt = localSid ?? Int(params?.sid ?? "") ?? 204
        let sid = String(sidInt)
        let sn = accountId ?? params?.sn ?? "0"

        let encodedId = SonosPlayableURIBuilder.encodedObjectID(radioId)
        let radioURI = SonosPlayableURIBuilder.serviceURI(
            scheme: uriScheme,
            objectID: radioId,
            localSid: sidInt,
            flags: flags,
            accountID: sn)

        let descTag: String
        if let fromMD = extractDescTag(from: resMD ?? "") {
            descTag = fromMD
        } else if let cloudServiceId {
            descTag = "SA_RINCON\(cloudServiceId)_\(cloudServiceUsername(for: cloudServiceId, accountId: sn))"
        } else if let sidInt = localSid,
                  let cloudSid = localToCloudSid[sidInt] {
            descTag = "SA_RINCON\(cloudSid)_\(cloudServiceUsername(for: cloudSid, accountId: sn))"
        } else {
            descTag = "SA_RINCON\(sid)_X_#Svc\(sid)-\(sn)-Token"
        }
        let metadataPrefix: String
        let parentID: String
        let upnpClass: String
        let albumArtURI: String?
        switch metadataStyle {
        case .programRadio:
            metadataPrefix = "000c206c"
            parentID = ""
            upnpClass = "object.item.audioItem.audioBroadcast.#programRadio"
            albumArtURI = nil
        case .hlsLiveRadio:
            metadataPrefix = "10092064"
            parentID = ""
            upnpClass = "object.item.audioItem.audioBroadcast"
            albumArtURI = (artURL?.isEmpty == false) ? artURL : nil
        }
        let radioMeta = SonosDIDLBuilder.document([
            SonosDIDLElement(
                id: "\(metadataPrefix)\(encodedId)",
                parentID: parentID,
                title: stationName,
                upnpClass: upnpClass,
                albumArtURI: albumArtURI,
                desc: descTag)
        ])

        return StationTransportPayload(label: label, uri: radioURI, metadata: radioMeta)
    }

    private func hlsStationObjectID(from radioId: String) -> String? {
        guard var stationID = normalizedStreamObjectID(radioId) else { return nil }
        if stationID.hasPrefix("hls:") {
            return stationID
        }
        if stationID.hasPrefix("radio:") {
            stationID.removeFirst("radio:".count)
        }
        guard stationID.hasPrefix("ra."), stationID.count > 3 else { return nil }
        return "hls:\(stationID)"
    }

    private func normalizedStreamObjectID(_ streamObjectID: String?) -> String? {
        guard var streamObjectID = streamObjectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !streamObjectID.isEmpty else {
            return nil
        }
        streamObjectID = streamObjectID.removingPercentEncoding ?? streamObjectID
        if let fragmentStart = streamObjectID.firstIndex(of: "#") {
            streamObjectID = String(streamObjectID[..<fragmentStart])
        }
        if let queryStart = streamObjectID.firstIndex(of: "?") {
            streamObjectID = String(streamObjectID[..<queryStart])
        }
        streamObjectID = streamObjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        return streamObjectID.isEmpty ? nil : streamObjectID
    }

    private func extractDescTag(from xml: String) -> String? {
        guard let start = xml.range(of: "<desc"),
              let contentStart = xml.range(of: ">", range: start.upperBound..<xml.endIndex),
              let end = xml.range(of: "</desc>", range: contentStart.upperBound..<xml.endIndex) else { return nil }
        return String(xml[contentStart.upperBound..<end.lowerBound])
    }

    @discardableResult
    func addToQueue(item: BrowseItem, manager: SonosManager) async -> Bool {
        schedulePlaybackArtworkPrewarm(for: item)
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Adding to the queue")
                .localizedDescription
            return false
        }
        guard let ip = manager.selectedSpeaker?.playbackIP else {
            errorMessage = HandoffTransferError.noSelectedSpeaker.localizedDescription
            return false
        }
        let meta = playbackMetadata(for: item)
        guard let payload = item.playbackDescriptor.queuePayload(metadata: meta) else {
            errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
            return false
        }
        SonosLog.debug(
            .playbackLink,
            "addToQueue item title='\(item.title)' cloudType=\(item.cloudType ?? "nil") " +
                "itemId=\(SonosLog.playbackLinkValue(item.id, maxLength: 640)) " +
                "serviceId=\(item.serviceId.map(String.init) ?? "nil") " +
                "isContainer=\(item.isContainer) uri=\(SonosLog.playbackLinkValue(payload.uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(payload.metadata))")
        do {
            try await SonosAPI.addURIToQueue(ip: ip, uri: payload.uri, metadata: payload.metadata)
            await manager.loadQueue()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Cloud `listFavorites` and UPnP shortcut favorites (artists, some
    /// collections) often ship **without** a top-level `<res>` URI, while
    /// `r:resMD` or DIDL `id` still has everything needed to build the
    /// `x-rincon-cpcontainer:…?sid=…&sn=…` form. `addToFavorites` and navigation
    /// into detail views need that resolved shape or the heart action fails
    /// (`guard` on `uri`) even though the entry is a valid favorite.
    func browseItemWithResolvedFavoriteURI(
        _ item: BrowseItem,
        preserveArtworkSize: Bool = false
    ) -> BrowseItem? {
        if item.playbackDescriptor.directURI != nil {
            guard preserveArtworkSize,
                  item.detailArtworkURL == nil,
                  let detailArtworkURL = item.preferredDetailArtworkURL else {
                return item
            }
            var enriched = item
            enriched.albumArtURL = ArtworkURLNormalizer.loadableURLString(
                from: detailArtworkURL,
                shortSidePixels: 400
            ) ?? item.albumArtURL
            enriched.detailArtworkURL = detailArtworkURL
            return enriched
        }
        guard let ids = parseCloudIds(from: item) else { return nil }
        let typeString: String? = item.cloudType ?? favoriteCategoryAsCloudType(item)
        guard let ts = typeString, let kind = CloudObjectType(rawValue: ts) else { return nil }
        let oid = ids.objectId
        let cloudSid = ids.cloudServiceId
        let aid = ids.accountId
        switch kind {
        case .artist:
            return makeArtistItem(
                objectId: oid, name: item.title, artURL: item.preferredDetailArtworkURL,
                cloudServiceId: cloudSid, accountId: aid,
                preserveArtworkSize: preserveArtworkSize)
        case .album:
            return makeAlbumItem(
                objectId: oid, title: item.title, artist: item.artist,
                artURL: item.preferredDetailArtworkURL,
                cloudServiceId: cloudSid, accountId: aid,
                preserveArtworkSize: preserveArtworkSize)
        case .playlist:
            return makePlaylistItem(
                objectId: oid, title: item.title, artist: item.artist,
                artURL: item.albumArtURL,
                cloudServiceId: cloudSid, accountId: aid)
        case .track:
            return makeTrackItem(
                objectId: oid, title: item.title, artist: item.artist,
                album: item.album, artURL: item.albumArtURL,
                mimeType: nil,
                cloudServiceId: cloudSid, accountId: aid)
        case .program:
            return makeStationItem(
                objectId: oid, title: item.title, artistName: item.artist,
                artURL: item.albumArtURL,
                cloudServiceId: cloudSid, accountId: aid)
        case .collection:
            return nil
        }
    }

    private func favoriteCategoryAsCloudType(_ item: BrowseItem) -> String? {
        switch item.favoriteCategory {
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .playlist: return "PLAYLIST"
        case .collection: return "COLLECTION"
        case .station: return "PROGRAM"
        case .song: return "TRACK"
        }
    }

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
    private func innerDIDLForFavoriteCreate(resolved: BrowseItem) -> String {
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
    private func serviceDisplayName(for item: BrowseItem) -> String? {
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

    private func isAppleMusicItem(_ item: BrowseItem) -> Bool {
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

    private func isAppleMusicPlaybackArtworkItem(_ item: BrowseItem) -> Bool {
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

    private func findFavorite(matching item: BrowseItem) -> BrowseItem? {
        favoriteMatcher.favorite(matching: item, in: favorites)
    }

    private func refreshFavorites(ip: String) async {
        do {
            let items = try await SonosAPI.browseFavorites(ip: ip)
            SonosLog.info(.favorites, "Refresh: \(items.count) items loaded")
            favorites = items
        } catch {
            SonosLog.error(.favorites, "Refresh failed: \(error)")
        }
    }
}
