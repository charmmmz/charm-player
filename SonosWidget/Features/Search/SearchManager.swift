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

enum ReplaceQueueBackgroundFillCancellationPolicy {
    enum Transport {
        case localUPnP
        case cloud
    }

    static func shouldCancelBeforeForegroundPlayback(transport: Transport) -> Bool {
        transport == .localUPnP
    }
}

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

    struct ForwardAlbumQueueAttempt {
        let plan: AppleMusicForwardAlbumQueuePlan
    }

    struct ForwardCloudTrackCandidate {
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
    var recentlyPlayed: [BrowseItem] = []
    static let recentlyPlayedLimit = 20

    static let enabledKey = "SearchEnabledServices"
    static let cachedAccountsKey = "CachedLinkedAccounts"
    /// Persisted `cloudToLocalSid` / `localToCloudSid` mapping. Built from
    /// the intersection of the Cloud API's linked-services list and the
    /// LAN `listMusicServices` catalog. Caching lets subsequent launches
    /// resolve cloud service ids from a local sid *before* the user opens
    /// Browse — the player's artist / album NavigationLinks need this
    /// mapping to render as tappable links.
    static let sidMappingKey = "CloudLocalSidMapping"
    static let recentlyPlayedKey = "RecentlyPlayedItems"

    var speakerIP: String?
    var searchTask: Task<Void, Never>?
    @ObservationIgnored var replaceQueueFillTask: Task<Void, Never>?
    @ObservationIgnored var replaceQueueFillGeneration = 0
    @ObservationIgnored var localServicePlaylistArtworkLookupOverride: ((BrowseItem) async -> String?)?
    @ObservationIgnored var playbackArtworkPrewarmOverride: (([URL]) async -> Void)?
    /// The query string that produced the most recent `searchResults` /
    /// `serviceDetailResults`. Readable from views so they can react when a
    /// new search commits (e.g. to re-fetch the selected service tab).
    var lastSearchQuery = ""
    var hasProbed = false
    /// Tracks whether `loadBrowseContent` has finished at least once during
    /// this session. Detail views (Artist / Album / Playlist) consult this so
    /// they can lazily trigger the load when the user opens a detail page
    /// without ever visiting the Browse tab — otherwise `isFavorited` always
    /// returns false because `favorites` is still empty.
    var hasLoadedBrowseContent = false
    var lastBrowseLoadKey: String?
    var lastBrowseLoadedAt: Date?
    let appleMusicLibraryTrackPlaybackResolver: AppleMusicLibraryTrackPlaybackResolver

    /// Maps Cloud API service IDs to local Sonos service IDs and back.
    var cloudToLocalSid: [String: Int] = [:]
    var localToCloudSid: [Int: String] = [:]
    /// Cloud service ID to account username used when constructing DIDL metadata.
    var cloudServiceUsername: [String: String] = [:]

    var hasBrowseDisplayContent: Bool {
        hasLoadedBrowseContent || !favorites.isEmpty || !playlists.isEmpty || !radio.isEmpty || !recentlyPlayed.isEmpty
    }

    var showsBlockingBrowseLoader: Bool {
        BrowseRefreshPolicy.showsBlockingLoader(
            isLoading: isLoadingBrowse,
            hasLoadedContent: hasBrowseDisplayContent
        )
    }

    init(
        appleMusicLibraryTrackPlaybackResolver: AppleMusicLibraryTrackPlaybackResolver = AppleMusicLibraryTrackPlaybackResolver()
    ) {
        self.appleMusicLibraryTrackPlaybackResolver = appleMusicLibraryTrackPlaybackResolver
        restoreCachedAccounts()
        restoreRecentlyPlayed()
        restoreSidMapping()
    }

    func configure(speakerIP: String?) {
        self.speakerIP = speakerIP
    }

}
