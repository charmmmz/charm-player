import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

enum LiveActivityArtworkThumbnail {
    static let maxBytes = 1_200

    static let candidates: [(edge: CGFloat, quality: CGFloat)] = [
        (48, 0.50),
        (42, 0.42),
        (36, 0.34),
        (30, 0.28),
        (24, 0.22)
    ]

    static func make(from image: UIImage?) -> Data? {
        guard let image else { return nil }

        for candidate in candidates {
            let size = CGSize(width: candidate.edge, height: candidate.edge)
            guard let thumbnail = image.preparingThumbnail(of: size),
                  let data = thumbnail.jpegData(compressionQuality: candidate.quality)
            else { continue }

            if data.count <= maxBytes {
                return data
            }
        }

        return nil
    }
}

enum SonosAreaApplyError: Error, LocalizedError {
    case localControlUnavailable
    case noReachableAreaPlayers

    var errorDescription: String? {
        switch self {
        case .localControlUnavailable:
            return "Local Sonos control is unavailable."
        case .noReachableAreaPlayers:
            return "No reachable speakers were found for this saved group."
        }
    }
}

@MainActor
final class RefreshRequestGate {
    var generation = 0
    var inFlight: (generation: Int, task: Task<Void, Never>)?

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        if let current = inFlight {
            await current.task.value
            return
        }

        generation += 1
        let currentGeneration = generation
        let task = Task { @MainActor in
            await operation()
        }
        inFlight = (currentGeneration, task)
        await task.value

        if inFlight?.generation == currentGeneration {
            inFlight = nil
        }
    }
}

struct QueueArtworkPrefetchRequest: Sendable {
    let urlString: String
    let siblingURLStrings: [String]
}

struct QueueArtworkPrefetchResult: @unchecked Sendable {
    let urlString: String
    let siblingURLStrings: [String]
    let image: UIImage
    let imageCost: Int
    let color: Color?
    let source: String
}

nonisolated enum AlbumArtDataFetchPolicy {
    static func shouldUseRelayArtworkProxy(sourceURLString _: String) -> Bool {
        false
    }

    static func validateDirectResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(
                .badServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
        }
    }
}

nonisolated enum HomeSpeakerCardsRefreshPolicy {
    static let defaultMinimumRefreshInterval: TimeInterval = 2

    static func showsBlockingLoader(
        hasLoadedCards: Bool,
        groupStatusesIsEmpty: Bool
    ) -> Bool {
        !hasLoadedCards && groupStatusesIsEmpty
    }

    static func shouldRefreshOnAppear(
        lastRefreshAt: Date?,
        isRefreshing: Bool,
        now: Date = Date(),
        minimumInterval: TimeInterval = defaultMinimumRefreshInterval
    ) -> Bool {
        guard !isRefreshing else { return false }
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= minimumInterval
    }
}

@Observable
final class SonosManager {
    struct SpeakerSelectionCachedArtwork {
        let urlString: String
        let image: UIImage
    }

    var speakers: [SonosPlayer] = []
    var allSpeakers: [SonosPlayer] = []
    var groupStatuses: [SpeakerGroupStatus] = []
    var savedAreas: [SonosArea] = []
    var hasLoadedHomeSpeakerCards = false
    var isRefreshingHomeSpeakerCards = false
    var selectedSpeaker: SonosPlayer?
    var trackInfo: TrackInfo?
    var transportState: TransportState = .stopped
    var volume: Int = 0
    var isLoading = false
    var errorMessage: String?
    var albumArtImage: UIImage?
    var albumArtDominantColor: Color?
    /// Average colour of the cover's bottom ~12% strip. Drives the player
    /// background so the gradient starts from whatever the cover actually
    /// ends with (e.g. white snow on a Christmas tree cover) instead of the
    /// dominant tint, which would otherwise leave a hard edge at the seam.
    var albumArtBottomEdgeColor: Color?
    var showingAddSpeaker = false
    var showingQueue = false
    var isPlayingFromQueue = true
    var showingSpeakerPicker = false
    var showFullPlayer = true
    var memberVolumes: [String: Int] = [:]
    var groupAlbumColors: [String: Color] = [:]
    var groupAlbumImages: [String: UIImage] = [:]
    var groupLastArtURL: [String: String] = [:]
    var localControlHouseholdId: String?

    var positionSeconds: TimeInterval = 0
    var durationSeconds: TimeInterval = 0
    var isShuffling: Bool = false
    var repeatMode: RepeatMode = .off
    var queue: [QueueItem] = []
    var queueReorderStatusByItemID: [String: QueueReorderStatus] = [:]
    var connectionState: ConnectionState = .disconnected

    /// Soundbar TV-mode EQ flags. Sonos exposes these as `RenderingControl`
    /// `EQType` toggles; we only fetch them when the active source is `.tv`
    /// so we don't waste SOAP calls on music sessions where they're hidden.
    var nightMode: Bool = false
    /// Sonos calls this "Speech Enhancement" in the consumer app. The UPnP
    /// field is `DialogLevel` — historically a 0/1 toggle, but Arc Ultra
    /// widened it to a 5-step scale (Off / Low / Medium / High / Max).
    var speechEnhancement: SpeechEnhancementLevel = .off
    /// Short window after a user toggle during which we ignore polled values
    /// — keeps the UI from flickering back to the old state if a poll lands
    /// before the speaker reflects the SetEQ.
    var soundbarEQLockUntil: Date = .distantPast

    let discovery = SonosDiscovery()

    /// Main refresh loop. When LAN events are subscribed this becomes a
    /// low-frequency watchdog; otherwise it keeps the historical polling
    /// cadence so Cloud mode and pre-subscription LAN still stay fresh.
    var refreshTask: Task<Void, Never>?
    var positionTask: Task<Void, Never>?
    var eventSubscriptionTask: Task<Void, Never>?
    var eventDrivenRefreshTask: Task<Void, Never>?
    @ObservationIgnored let lanRefreshGate = RefreshRequestGate()
    @ObservationIgnored let groupRefreshGate = RefreshRequestGate()
    var eventListener: SonosEventListener?
    var eventSubscriptions = SonosEventSubscriptionRegistry()
    var eventSubscriptionIP: String?
    var lastAlbumArtURL: String?
    var loadingAlbumArtURL: String?
    var displayedAlbumArtTrackIdentity: String?
    var deferredMissingAlbumArtTrackIdentity: String?
    var delayedAudioQualityRetryTask: Task<Void, Never>?
    var delayedAudioQualityRetryTrackKey: String?
    var delayedAudioQualityRetryExhaustedTrackKey: String?
    var lastWidgetTrackTitle: String?
    var lastEnrichedTrackKey: String?
    var lastCloudQualityAttempt: Date = .distantPast
    /// Cloud audio-quality enrichment is best-effort and round-trips a
    /// real HTTP call. Keep it gated to ~once every 15 s so a burst of
    /// `refreshState` ticks (e.g. user scrubbing) doesn't fan out to a
    /// burst of `nowplaying` requests.
    static let cloudQualityRefreshCooldown: TimeInterval = 15
    static let localPlaybackMetadataQualityRetryDelayNanoseconds: UInt64 = 350_000_000
    static let delayedAudioQualityRetryIntervalsNanoseconds: [UInt64] = [
        1_500_000_000,
        3_500_000_000
    ]
    static let albumArtColorTransitionDuration: TimeInterval = 0.45
    static let fastRefreshIntervalSeconds = 3
    static let lanEventWatchdogRefreshIntervalSeconds = 30
    static let sonosEventSubscriptionTimeout = 600
    static let sonosEventServices: [SonosEventService] = [
        .avTransport,
        .renderingControl,
        .zoneGroupTopology,
        .contentDirectory
    ]

    /// Number of back-to-back `refreshState` failures before we drop the
    /// LAN connection, surface a "pull to refresh" banner, and re-probe
    /// the backend (lets us auto-fall-over to Cloud when the user walks
    /// off Wi-Fi).
    static let maxConsecutiveRefreshFailures = 3
    var consecutiveFailures = 0
    var currentActivity: Activity<SonosActivityAttributes>?
    /// Mirrors the `pushType` we asked for when creating `currentActivity`.
    /// Used for diagnostics and relay token cleanup only; an existing Live
    /// Activity keeps being updated locally even if relay availability changes.
    var currentActivityUsesRelay: Bool = false
    /// Long-lived task draining `Activity.pushTokenUpdates` for the relay.
    /// Cancelled on activity end / mode switch so we don't double-register
    /// stale tokens with the NAS.
    var pushTokenTask: Task<Void, Never>?
    var pushToStartTokenTask: Task<Void, Never>?
    var activityUpdatesTask: Task<Void, Never>?
    var activityStateTask: Task<Void, Never>?
    var remoteLiveActivitiesByGroupID: [String: Activity<SonosActivityAttributes>] = [:]
    var liveActivityResumeFallbackTask: Task<Void, Never>?
    var liveActivityResumeFallbackGroupId: String?
    var pushTokenTasksByActivityID: [String: Task<Void, Never>] = [:]
    var activityStateTasksByActivityID: [String: Task<Void, Never>] = [:]
    var registeredPushTokensByActivityID: [String: String] = [:]
    var inFlightPushToStartRegistrationKey: String?
    /// Most recent Live Activity push token we successfully POSTed to the
    /// relay. We keep this around so `stopLiveActivity` can fire a DELETE
    /// even after the underlying activity is gone.
    var lastRegisteredPushToken: String?
    /// True only after the relay has accepted the current Live Activity token.
    /// Kept separate from `lastRegisteredPushToken` so token rotation failures
    /// can temporarily fall back to local updates without losing the old token
    /// needed for unregister cleanup.
    var liveActivityRelayWriterReady: Bool = false
    /// Last Live Activity preference packet POSTed to the NAS relay, keyed so
    /// polling and repeated style writes do not spam the LAN.
    var lastLiveActivityRelayPreferencesSignature: String?
    static let liveActivityDismissSuppressForSeconds = 30 * 60
    static let liveActivityResumeFallbackDelayNanoseconds: UInt64 = 2_500_000_000
    var albumArtTask: Task<Void, Never>?
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    var backgroundKeepaliveTask: Task<Void, Never>?
    /// Timestamp of the last real Sonos position fetch, used to keep timerInterval accurate.
    var positionFetchedAt: Date = .now
    var lastHomeSpeakerCardsRefreshAt: Date?

    /// Cloud API group ID resolved for the currently selected speaker.
    var cloudGroupId: String?
    /// Cloud API player ID for the currently selected speaker — used by
    /// `setPlayerVolume` via the Control API. May be nil if the player isn't
    /// in the resolved household / hasn't been seen via `getGroups` yet.
    var cloudPlayerId: String?
    /// Cached cloud-sourced audio quality keyed by the current track signature
    /// to survive UPnP refreshes without leaking the badge to same-title tracks.
    var cachedCloudQuality: (trackKey: String, quality: AudioQuality)?
    var localControlGroupIdsByPlayerId: [String: String] = [:]
    var isEnrichingQuality = false
    /// When set, refreshState() will not overwrite isShuffling/repeatMode until this date.
    var playModeLockUntil: Date = .distantPast

    var queueUpdateID: String = "0"
    /// Observable set of URLs whose images have been persisted to disk.
    var cachedArtURLs: Set<String> = []
    let queueArtCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 150
        cache.totalCostLimit = 30 * 1024 * 1024
        return cache
    }()
    var dominantColorCache: [String: Color] = [:]
    var queueLoaded = false
    var prefetchTask: Task<Void, Never>?
    @ObservationIgnored var queueReorderGeneration = 0
    var groupRefreshCounter = 0

    // MARK: - Transport Backend (LAN vs Cloud routing)

    /// Which pipeline — direct UPnP on the LAN (`SonosAPI`) or the Sonos
    /// Cloud Control API (`SonosCloudAPI`) — we dispatch control commands
    /// through. `.unknown` means we haven't probed yet or the speaker is
    /// totally unreachable.
    enum TransportBackend: Equatable { case unknown, lan, cloud }
    enum QueueReorderStatus: Equatable { case syncing, confirmed }

    /// Current routing decision. Exposed so UI can show a "Remote" pill / gray
    /// out LAN-only controls when on cloud.
    var transportBackend: TransportBackend = .unknown
    /// Serializes probes so concurrent callers (app foreground + manual
    /// refresh + selectSpeaker) coalesce into a single TCP check.
    var probeTask: (speakerID: String, task: Task<TransportBackend, Never>)?

    nonisolated static let albumArtSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    enum ConnectionState { case connected, disconnected, reconnecting }
    enum SpeakerGroupDropIntent: Equatable { case reorderBefore, merge, reorderAfter }
    enum SpeakerGroupReorderPlacement: Equatable { case before, after }

    struct AutoRefreshPlan: Equatable {
        var refreshState: Bool
        var refreshGroups: Bool
        var sleepSeconds: Int
    }

    var isPlaying: Bool { transportState == .playing }
    var isConfigured: Bool { selectedSpeaker != nil }
    var currentCloudGroupId: String? { cloudGroupId }
    var showsHomeSpeakerCardsBlockingLoader: Bool {
        HomeSpeakerCardsRefreshPolicy.showsBlockingLoader(
            hasLoadedCards: hasLoadedHomeSpeakerCards,
            groupStatusesIsEmpty: groupStatuses.isEmpty
        )
    }

    func shouldRefreshHomeSpeakerCardsOnAppear(now: Date = Date()) -> Bool {
        HomeSpeakerCardsRefreshPolicy.shouldRefreshOnAppear(
            lastRefreshAt: lastHomeSpeakerCardsRefreshAt,
            isRefreshing: isRefreshingHomeSpeakerCards,
            now: now
        )
    }

    func refreshHomeSpeakerCardsOnAppear() {
        guard shouldRefreshHomeSpeakerCardsOnAppear() else { return }
        Task { await refreshAllGroupStatuses() }
    }

    func albumArtTransitionID(hasDisplayedArtwork: Bool? = nil) -> String {
        AlbumArtTransitionIdentity.id(
            displayedTrackIdentity: displayedAlbumArtTrackIdentity,
            currentTrackIdentity: AlbumArtTrackIdentity.make(from: trackInfo),
            hasDisplayedArtwork: hasDisplayedArtwork ?? (albumArtImage != nil)
        )
    }

    /// Apply a freshly-read transport state, suppressing the brief
    /// `TRANSITIONING` window Sonos returns immediately after a
    /// Play/Pause command. Without this guard the play/pause button
    /// flickers through "playing → transitioning → playing" because
    /// `isPlaying` flips false during the ~300-800 ms transition.
    /// Falls through to a normal write whenever the prior state isn't
    /// already a stable playing/paused, so we still make progress on
    /// first refresh after launch (when prior is `.stopped`/`.unknown`).
    func applyIncomingTransportState(_ incoming: TransportState) {
        if incoming == .transitioning,
           transportState == .playing || transportState == .paused {
            return
        }
        transportState = incoming
    }

    /// True when the app is controlling the speaker via the Sonos Cloud
    /// Control API (user is off-LAN). Views use this to render the "Remote"
    /// pill and to pre-emptively hide LAN-only affordances (queue mutations,
    /// add-to-favorites).
    var isRemoteMode: Bool { transportBackend == .cloud }

    /// True when we've probed and neither LAN nor Cloud gave us a usable
    /// path — speaker is likely powered off, user isn't signed into Sonos,
    /// or the internet is completely gone.
    var isSpeakerUnreachable: Bool {
        isConfigured && transportBackend == .unknown && !isProbing
    }

    /// Exposed so views can show a subtle spinner while the 1 s probe runs.
    var isProbing: Bool { probeTask != nil }

    /// IP to send playback commands (group coordinator)
    var playbackIP: String? { selectedSpeaker?.playbackIP }
    /// IP for volume commands (individual speaker)
    var volumeIP: String? { selectedSpeaker?.ipAddress }

    nonisolated static func speakerSelectionMatches(
        _ selectedSpeaker: SonosPlayer?,
        expectedSpeakerID: String
    ) -> Bool {
        selectedSpeaker?.id == expectedSpeakerID
    }

    func speakerSelectionMatches(expectedSpeakerID: String) -> Bool {
        Self.speakerSelectionMatches(selectedSpeaker, expectedSpeakerID: expectedSpeakerID)
    }

    func currentGroupStatusIndex() -> Int? {
        guard let selected = selectedSpeaker else { return nil }
        let selectedGroupID = selected.groupId ?? selected.id
        return groupStatuses.firstIndex {
            $0.id == selectedGroupID || $0.coordinator.id == selected.id
        }
    }

    func syncCurrentGroupStatusFromPlaybackState() {
        guard let idx = currentGroupStatusIndex() else { return }
        groupStatuses[idx].trackInfo = trackInfo
        groupStatuses[idx].transportState = transportState
        groupStatuses[idx].volume = volume
    }

    func setCurrentTransportState(_ state: TransportState) {
        transportState = state
        syncCurrentGroupStatusFromPlaybackState()
    }

    func setGroupTransportState(_ state: TransportState, forGroupID groupID: String) {
        guard let idx = groupStatuses.firstIndex(where: { Self.speakerGroupStatus($0, matches: groupID) }) else {
            return
        }

        groupStatuses[idx].transportState = state
        if currentGroupStatusIndex() == idx {
            transportState = state
        }
    }

    nonisolated static func sortedSpeakerGroups(
        _ statuses: [SpeakerGroupStatus],
        preferredOrder: [String] = SharedStorage.homeSpeakerGroupOrder
    ) -> [SpeakerGroupStatus] {
        let orderRanks = Dictionary(
            preferredOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        return statuses.sorted { lhs, rhs in
            let leftRank = speakerOrderRank(for: lhs, orderRanks: orderRanks)
            let rightRank = speakerOrderRank(for: rhs, orderRanks: orderRanks)

            switch (leftRank, rightRank) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftName = lhs.coordinator.name.lowercased()
                let rightName = rhs.coordinator.name.lowercased()
                if leftName != rightName { return leftName < rightName }
                return lhs.id < rhs.id
            }
        }
    }

    nonisolated static func homeSpeakerCoordinatorCandidates(
        in speakers: [SonosPlayer]
    ) -> [SonosPlayer] {
        speakers.filter { $0.isCoordinator && !$0.isInvisible }
    }

    nonisolated static func speakerOrderRank(
        for status: SpeakerGroupStatus,
        orderRanks: [String: Int]
    ) -> Int? {
        let keys = [
            status.id,
            status.coordinator.id,
            status.coordinator.groupId
        ].compactMap { $0 }

        return keys.compactMap { orderRanks[$0] }.min()
    }

    nonisolated static func speakerOrderStorageID(for status: SpeakerGroupStatus) -> String {
        status.coordinator.groupId ?? status.id
    }

    nonisolated static func musicAmbienceSnapshot(
        selectedSpeaker: SonosPlayer?,
        currentGroupMembers: [SonosPlayer],
        trackInfo: TrackInfo?,
        isPlaying: Bool,
        albumArtData: Data?
    ) -> HueAmbiencePlaybackSnapshot {
        let visibleMembers = currentGroupMembers.filter { !$0.isInvisible }
        let members = visibleMembers.isEmpty
            ? selectedSpeaker.map { [$0] } ?? []
            : visibleMembers

        return HueAmbiencePlaybackSnapshot(
            selectedSonosID: selectedSpeaker?.id,
            selectedSonosName: selectedSpeaker?.name,
            groupMemberIDs: members.map(\.id),
            groupMemberNamesByID: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.name) }),
            trackTitle: trackInfo?.title,
            artist: trackInfo?.artist,
            albumArtURL: trackInfo?.albumArtURL,
            isPlaying: isPlaying,
            albumArtImage: albumArtData,
            artworkThemeColors: trackInfo?.artworkThemeColors
        )
    }

    nonisolated static func speakerGroupDropIntent(
        locationY: CGFloat,
        targetHeight: CGFloat
    ) -> SpeakerGroupDropIntent {
        guard targetHeight > 0 else { return .merge }

        let clampedY = min(max(locationY, 0), targetHeight)
        let reorderZoneHeight = targetHeight * 0.25

        if clampedY < reorderZoneHeight { return .reorderBefore }
        if clampedY > targetHeight - reorderZoneHeight { return .reorderAfter }
        return .merge
    }

    func moveSpeakerGroup(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = groupStatuses
        reordered.move(fromOffsets: source, toOffset: destination)
        groupStatuses = reordered
        SharedStorage.homeSpeakerGroupOrder = reordered.map(Self.speakerOrderStorageID)
    }

    func reorderSpeakerGroup(
        sourceID: String,
        relativeTo targetID: String,
        placement: SpeakerGroupReorderPlacement
    ) {
        guard sourceID != targetID,
              let sourceIndex = groupStatuses.firstIndex(where: { Self.speakerGroupStatus($0, matches: sourceID) })
        else { return }

        var reordered = groupStatuses
        let source = reordered.remove(at: sourceIndex)

        guard let targetIndex = reordered.firstIndex(where: { Self.speakerGroupStatus($0, matches: targetID) }) else {
            reordered.insert(source, at: sourceIndex)
            return
        }

        let insertionIndex = placement == .before ? targetIndex : targetIndex + 1
        reordered.insert(source, at: insertionIndex)
        groupStatuses = reordered
        SharedStorage.homeSpeakerGroupOrder = reordered.map(Self.speakerOrderStorageID)
    }

    nonisolated static func speakerGroupStatus(
        _ status: SpeakerGroupStatus,
        matches id: String
    ) -> Bool {
        status.id == id
            || status.coordinator.id == id
            || status.coordinator.groupId == id
    }

    func applyPreferredSpeakerOrder(to statuses: [SpeakerGroupStatus]) {
        groupStatuses = Self.homeSpeakerStatusesAfterRefresh(
            existing: groupStatuses,
            incoming: statuses
        )
        if !statuses.isEmpty {
            hasLoadedHomeSpeakerCards = true
            lastHomeSpeakerCardsRefreshAt = Date()
        }
    }

    nonisolated static func homeSpeakerStatusesAfterRefresh(
        existing: [SpeakerGroupStatus],
        incoming: [SpeakerGroupStatus],
        preferredOrder: [String] = SharedStorage.homeSpeakerGroupOrder
    ) -> [SpeakerGroupStatus] {
        let displayableExisting = existing.filter(Self.isHomeSpeakerStatusDisplayable)
        let displayableIncoming = incoming.filter(Self.isHomeSpeakerStatusDisplayable)
        let sortedIncoming = Self.sortedSpeakerGroups(
            displayableIncoming,
            preferredOrder: preferredOrder
        )
        if sortedIncoming.isEmpty, !displayableExisting.isEmpty {
            return displayableExisting
        }
        return sortedIncoming.map { incomingStatus in
            guard let existingStatus = displayableExisting.first(where: {
                Self.speakerGroupStatus($0, matches: incomingStatus.id)
                    || Self.speakerGroupStatus(incomingStatus, matches: $0.id)
            }) else {
                return incomingStatus
            }
            return Self.homeSpeakerStatus(
                existing: existingStatus,
                mergingIncoming: incomingStatus
            )
        }
    }

    nonisolated static func homeSpeakerStatus(
        existing: SpeakerGroupStatus,
        mergingIncoming incoming: SpeakerGroupStatus
    ) -> SpeakerGroupStatus {
        guard shouldPreserveExistingAppleMusicLiveStatus(existing: existing, incoming: incoming) else {
            return incoming
        }
        var merged = incoming
        merged.trackInfo = existing.trackInfo
        if isPlaceholderTransportState(incoming.transportState) {
            merged.transportState = existing.transportState
        }
        return merged
    }

    nonisolated static func shouldPreserveExistingAppleMusicLiveStatus(
        existing: SpeakerGroupStatus,
        incoming: SpeakerGroupStatus
    ) -> Bool {
        guard let existingTrack = existing.trackInfo,
              existingTrack.source == .appleMusic,
              isLiveStreamTrack(existingTrack),
              homeSpeakerTrackHasUsefulMetadata(existingTrack) else {
            return false
        }

        guard let incomingTrack = incoming.trackInfo else { return true }
        if !homeSpeakerTrackHasDisplayTitle(incomingTrack) {
            return true
        }
        return incomingTrack.source == .appleMusic
            && isLiveStreamTrack(incomingTrack)
            && isPlaceholderTransportState(incoming.transportState)
    }

    nonisolated static func isHomeSpeakerStatusDisplayable(
        _ status: SpeakerGroupStatus
    ) -> Bool {
        !status.coordinator.isInvisible
    }

    nonisolated static func homeSpeakerTrackHasUsefulMetadata(_ trackInfo: TrackInfo) -> Bool {
        homeSpeakerTrackHasDisplayTitle(trackInfo)
            || nonEmpty(trackInfo.albumArtURL) != nil
    }

    nonisolated static func homeSpeakerTrackHasDisplayTitle(_ trackInfo: TrackInfo?) -> Bool {
        displayableMetadataText(trackInfo?.title) != nil
    }

    nonisolated static func isPlaceholderTransportState(_ state: TransportState) -> Bool {
        switch state {
        case .stopped, .noMedia, .unknown:
            return true
        case .playing, .paused, .transitioning:
            return false
        }
    }

    nonisolated static func isLiveStreamTrack(_ trackInfo: TrackInfo) -> Bool {
        if trackInfo.source == .tv { return false }
        return SonosTime.parse(trackInfo.duration ?? "") <= 0
    }

}
