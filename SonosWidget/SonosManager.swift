import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

enum LiveActivityArtworkThumbnail {
    static let maxBytes = 1_200

    private static let candidates: [(edge: CGFloat, quality: CGFloat)] = [
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

@MainActor
final class RefreshRequestGate {
    private var generation = 0
    private var inFlight: (generation: Int, task: Task<Void, Never>)?

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

@Observable
final class SonosManager {
    struct SpeakerSelectionCachedArtwork {
        let urlString: String
        let image: UIImage
    }

    var speakers: [SonosPlayer] = []
    var allSpeakers: [SonosPlayer] = []
    var groupStatuses: [SpeakerGroupStatus] = []
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
    var miniPlayerDragOffset: CGFloat = 0
    var memberVolumes: [String: Int] = [:]
    var groupAlbumColors: [String: Color] = [:]
    var groupAlbumImages: [String: UIImage] = [:]
    private var groupLastArtURL: [String: String] = [:]

    var positionSeconds: TimeInterval = 0
    var durationSeconds: TimeInterval = 0
    var isShuffling: Bool = false
    var repeatMode: RepeatMode = .off
    var queue: [QueueItem] = []
    private var queueReorderStatusByItemID: [String: QueueReorderStatus] = [:]
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
    private var soundbarEQLockUntil: Date = .distantPast

    let discovery = SonosDiscovery()

    /// Main refresh loop. When LAN events are subscribed this becomes a
    /// low-frequency watchdog; otherwise it keeps the historical polling
    /// cadence so Cloud mode and pre-subscription LAN still stay fresh.
    private var refreshTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var eventSubscriptionTask: Task<Void, Never>?
    private var eventDrivenRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let lanRefreshGate = RefreshRequestGate()
    private var eventListener: SonosEventListener?
    private var eventSubscriptions = SonosEventSubscriptionRegistry()
    private var eventSubscriptionIP: String?
    private var lastAlbumArtURL: String?
    private var loadingAlbumArtURL: String?
    private var displayedAlbumArtTrackIdentity: String?
    private var deferredMissingAlbumArtTrackIdentity: String?
    private var lastWidgetTrackTitle: String?
    private var lastEnrichedTrackKey: String?
    private var lastCloudQualityAttempt: Date = .distantPast
    /// Cloud audio-quality enrichment is best-effort and round-trips a
    /// real HTTP call. Keep it gated to ~once every 15 s so a burst of
    /// `refreshState` ticks (e.g. user scrubbing) doesn't fan out to a
    /// burst of `nowplaying` requests.
    private static let cloudQualityRefreshCooldown: TimeInterval = 15
    private static let albumArtColorTransitionDuration: TimeInterval = 0.45
    private static let fastRefreshIntervalSeconds = 3
    private static let lanEventWatchdogRefreshIntervalSeconds = 30
    private static let sonosEventSubscriptionTimeout = 600
    private static let sonosEventServices: [SonosEventService] = [
        .avTransport,
        .renderingControl,
        .zoneGroupTopology,
        .contentDirectory
    ]

    /// Number of back-to-back `refreshState` failures before we drop the
    /// LAN connection, surface a "pull to refresh" banner, and re-probe
    /// the backend (lets us auto-fall-over to Cloud when the user walks
    /// off Wi-Fi).
    private static let maxConsecutiveRefreshFailures = 3
    private var consecutiveFailures = 0
    private var currentActivity: Activity<SonosActivityAttributes>?
    /// Mirrors the `pushType` we asked for when creating `currentActivity`.
    /// Used for diagnostics and relay token cleanup only; an existing Live
    /// Activity keeps being updated locally even if relay availability changes.
    private var currentActivityUsesRelay: Bool = false
    /// Long-lived task draining `Activity.pushTokenUpdates` for the relay.
    /// Cancelled on activity end / mode switch so we don't double-register
    /// stale tokens with the NAS.
    private var pushTokenTask: Task<Void, Never>?
    /// Most recent Live Activity push token we successfully POSTed to the
    /// relay. We keep this around so `stopLiveActivity` can fire a DELETE
    /// even after the underlying activity is gone.
    private var lastRegisteredPushToken: String?
    /// True only after the relay has accepted the current Live Activity token.
    /// Kept separate from `lastRegisteredPushToken` so token rotation failures
    /// can temporarily fall back to local updates without losing the old token
    /// needed for unregister cleanup.
    private var liveActivityRelayWriterReady: Bool = false
    /// Last Live Activity preference packet POSTed to the NAS relay, keyed so
    /// polling and repeated style writes do not spam the LAN.
    private var lastLiveActivityRelayPreferencesSignature: String?
    private var albumArtTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundKeepaliveTask: Task<Void, Never>?
    /// Timestamp of the last real Sonos position fetch, used to keep timerInterval accurate.
    private var positionFetchedAt: Date = .now

    /// Cloud API group ID resolved for the currently selected speaker.
    private var cloudGroupId: String?
    /// Cloud API player ID for the currently selected speaker — used by
    /// `setPlayerVolume` via the Control API. May be nil if the player isn't
    /// in the resolved household / hasn't been seen via `getGroups` yet.
    private var cloudPlayerId: String?
    /// Cached cloud-sourced audio quality keyed by the current track signature
    /// to survive UPnP refreshes without leaking the badge to same-title tracks.
    private var cachedCloudQuality: (trackKey: String, quality: AudioQuality)?
    private var localControlGroupIdsByPlayerId: [String: String] = [:]
    private var isEnrichingQuality = false
    /// When set, refreshState() will not overwrite isShuffling/repeatMode until this date.
    private var playModeLockUntil: Date = .distantPast

    // MARK: - Transport Backend (LAN vs Cloud routing)

    /// Which pipeline — direct UPnP on the LAN (`SonosAPI`) or the Sonos
    /// Cloud Control API (`SonosCloudAPI`) — we dispatch control commands
    /// through. `.unknown` means we haven't probed yet or the speaker is
    /// totally unreachable.
    enum TransportBackend: Equatable { case unknown, lan, cloud }
    enum QueueReorderStatus: Equatable { case syncing, confirmed }

    /// Current routing decision. Exposed so UI can show a "Remote" pill / gray
    /// out LAN-only controls when on cloud.
    private(set) var transportBackend: TransportBackend = .unknown
    /// Serializes probes so concurrent callers (app foreground + manual
    /// refresh + selectSpeaker) coalesce into a single TCP check.
    private var probeTask: Task<TransportBackend, Never>?

    private static let albumArtSession: URLSession = {
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
    private func applyIncomingTransportState(_ incoming: TransportState) {
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
    private var playbackIP: String? { selectedSpeaker?.playbackIP }
    /// IP for volume commands (individual speaker)
    private var volumeIP: String? { selectedSpeaker?.ipAddress }

    private func currentGroupStatusIndex() -> Int? {
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

    private nonisolated static func speakerOrderRank(
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

    private nonisolated static func speakerOrderStorageID(for status: SpeakerGroupStatus) -> String {
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
            albumArtImage: albumArtData
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

    private nonisolated static func speakerGroupStatus(
        _ status: SpeakerGroupStatus,
        matches id: String
    ) -> Bool {
        status.id == id
            || status.coordinator.id == id
            || status.coordinator.groupId == id
    }

    private func applyPreferredSpeakerOrder(to statuses: [SpeakerGroupStatus]) {
        groupStatuses = Self.sortedSpeakerGroups(statuses)
    }

    // MARK: - Lifecycle

    func loadSavedState() {
        allSpeakers = SharedStorage.savedSpeakers
        speakers = allSpeakers.filter(\.isCoordinator)
        if let ip = SharedStorage.speakerIP,
           let speaker = speakers.first(where: { $0.ipAddress == ip }) {
            selectedSpeaker = speaker
            Task {
                await resolveCloudGroupId()
                _ = await probeBackend()
                await refreshState()
                await refreshAllGroupStatuses()
            }
        } else if let first = speakers.first {
            selectedSpeaker = first
            syncSpeakerToStorage(first)
            Task {
                await resolveCloudGroupId()
                _ = await probeBackend()
                await refreshState()
                await refreshAllGroupStatuses()
            }
        } else {
            discovery.startScan()
        }
    }

    // MARK: - Speaker Management

    func connectFromDiscovery(_ speaker: SonosPlayer) async {
        isLoading = true
        errorMessage = nil
        discovery.stopScan()
        allSpeakers = discovery.discoveredSpeakers
        speakers = allSpeakers.filter(\.isCoordinator)
        SharedStorage.savedSpeakers = allSpeakers
        let target = speaker.isCoordinator ? speaker : speakers.first(where: { $0.groupId == speaker.groupId && $0.isCoordinator }) ?? speaker
        await selectSpeaker(target)
        await refreshAllGroupStatuses()
        isLoading = false
    }

    func addSpeaker(ip: String) async {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        do {
            let discovered = try await SonosAPI.withRetry {
                try await SonosAPI.getZoneGroupState(ip: trimmed)
            }
            if discovered.isEmpty {
                let name = try await SonosAPI.getDeviceName(ip: trimmed)
                allSpeakers = [SonosPlayer(id: UUID().uuidString, name: name, ipAddress: trimmed, isCoordinator: true)]
            } else {
                allSpeakers = discovered
            }
            speakers = allSpeakers.filter(\.isCoordinator)
            SharedStorage.savedSpeakers = allSpeakers
            let speaker = speakers.first(where: { $0.isCoordinator }) ?? speakers.first
            if let speaker { await selectSpeaker(speaker) }
        } catch {
            errorMessage = "Cannot connect to \(trimmed): \(error.localizedDescription)"
        }
        isLoading = false
    }

    func selectSpeaker(_ speaker: SonosPlayer) async {
        let previousLiveActivityGroupId = liveActivityGroupId()
        let previousSpeakerName = selectedSpeaker?.name
        let previousPlaybackIP = selectedSpeaker?.playbackIP
        let targetGroup = groupStatuses.first(where: {
            $0.coordinator.id == speaker.id || $0.coordinator.groupId == speaker.groupId
        })
        let targetGroupID = targetGroup?.id ?? speaker.groupId ?? speaker.id
        let cachedSelectionArtwork = Self.cachedArtworkForSpeakerSelection(
            groupID: targetGroupID,
            trackInfo: targetGroup?.trackInfo,
            groupImages: groupAlbumImages,
            groupLastArtURL: groupLastArtURL,
            imageForURL: { [queueArtCache] urlString in
                queueArtCache.object(forKey: urlString as NSString)
                    ?? QueueArtDiskCache.shared.image(for: urlString)
            }
        )
        let cachedSelectionColor = groupAlbumColors[targetGroupID]
        let cachedSelectionTrackIdentity = AlbumArtTrackIdentity.make(from: targetGroup?.trackInfo)
        selectedSpeaker = speaker
        syncSpeakerToStorage(speaker)
        let nextLiveActivityGroupId = liveActivityGroupId()

        if Self.shouldRecreateLiveActivityForSpeakerChange(
            currentActivityExists: currentActivity != nil,
            previousGroupId: previousLiveActivityGroupId,
            nextGroupId: nextLiveActivityGroupId
        ) {
            logLiveActivity(action: "recreate-request",
                            activityID: currentActivity?.id,
                            mode: currentActivityUsesRelay ? "relay-token" : "local",
                            reason: "selected-speaker-changed",
                            groupId: nextLiveActivityGroupId,
                            extra: [
                                "oldGroupId=\(Self.liveActivityLogValue(previousLiveActivityGroupId ?? "nil"))",
                                "oldSpeaker=\(Self.liveActivityLogValue(previousSpeakerName ?? "nil"))",
                                "newSpeaker=\(Self.liveActivityLogValue(speaker.name))"
                            ])
            stopLiveActivity()
        }

        albumArtTask?.cancel()
        lastAlbumArtURL = nil
        loadingAlbumArtURL = nil
        displayedAlbumArtTrackIdentity = nil
        deferredMissingAlbumArtTrackIdentity = nil
        albumArtImage = nil
        albumArtDominantColor = nil
        albumArtBottomEdgeColor = nil
        consecutiveFailures = 0
        cloudGroupId = nil
        cloudPlayerId = nil
        // Intentionally NOT resetting `transportBackend` here. The probe
        // kicked off below will correct it within ~1s; in the meantime the
        // previous backend is usually still valid (same LAN, different
        // speaker on it), and clearing to `.unknown` would flash the
        // "Speaker unreachable" banner during speaker switches on LAN.
        cachedCloudQuality = nil
        lastEnrichedTrackKey = nil
        lastCloudQualityAttempt = .distantPast
        lastLiveActivityRelayPreferencesSignature = nil
        if previousPlaybackIP != speaker.playbackIP {
            stopEventSubscriptions()
        }
        prefetchTask?.cancel()
        prefetchTask = nil
        queueArtCache.removeAllObjects()
        cachedArtURLs = []
        dominantColorCache = [:]

        // Pre-populate from the group's cached trackInfo to avoid progress bar flash
        if let group = targetGroup {
            trackInfo = group.trackInfo
            positionSeconds = group.trackInfo?.positionSeconds ?? 0
            durationSeconds = group.trackInfo?.durationSeconds ?? 0
        } else {
            trackInfo = nil
            positionSeconds = 0
            durationSeconds = 0
        }
        applyCachedArtworkForSpeakerSelection(
            cachedSelectionArtwork,
            groupID: targetGroupID,
            preferredColor: cachedSelectionColor,
            trackIdentity: cachedSelectionTrackIdentity
        )

        // Resolve cloud + probe FIRST so refreshState() can pick the right
        // path (cloud endpoints need cloudGroupId; probe result drives
        // `transportBackend`). Previously refreshState ran against .unknown
        // and would internally probe — fine, but selectSpeaker is also where
        // the Home tab's first paint happens, so ordering it explicitly keeps
        // the initial "Loading speakers…" window minimal.
        await resolveCloudGroupId()
        _ = await probeBackend()
        await refreshState()
    }

    static func cachedArtworkForSpeakerSelection(
        groupID: String?,
        trackInfo: TrackInfo?,
        groupImages: [String: UIImage],
        groupLastArtURL: [String: String],
        imageForURL: (String) -> UIImage?
    ) -> SpeakerSelectionCachedArtwork? {
        guard let urlString = trackInfo?.albumArtURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else {
            return nil
        }

        if let groupID,
           groupLastArtURL[groupID] == urlString,
           let image = groupImages[groupID] {
            return SpeakerSelectionCachedArtwork(urlString: urlString, image: image)
        }

        if let image = imageForURL(urlString) {
            return SpeakerSelectionCachedArtwork(urlString: urlString, image: image)
        }

        return nil
    }

    private func applyCachedArtworkForSpeakerSelection(
        _ cachedArtwork: SpeakerSelectionCachedArtwork?,
        groupID: String,
        preferredColor: Color?,
        trackIdentity: String?
    ) {
        guard let cachedArtwork else { return }

        let urlString = cachedArtwork.urlString
        let image = cachedArtwork.image
        let color = preferredColor ?? dominantColorCache[urlString] ?? image.dominantColor()
        let bottomEdge = image.bottomEdgeColor()

        lastAlbumArtURL = urlString
        loadingAlbumArtURL = nil
        deferredMissingAlbumArtTrackIdentity = nil
        albumArtImage = image
        displayedAlbumArtTrackIdentity = trackIdentity
        withAnimation(.easeInOut(duration: Self.albumArtColorTransitionDuration)) {
            albumArtDominantColor = color
            albumArtBottomEdgeColor = bottomEdge
        }
        dominantColorCache[urlString] = color
        groupAlbumImages[groupID] = image
        groupAlbumColors[groupID] = color
        groupLastArtURL[groupID] = urlString
        queueArtCache.setObject(
            image,
            forKey: urlString as NSString,
            cost: Int(image.size.width * image.size.height * 4)
        )
        cachedArtURLs.insert(urlString)

        if let data = image.jpegData(compressionQuality: 0.9) {
            SharedStorage.albumArtData = data
            SharedStorage.cachedAlbumArtDataURL = urlString
        }
        SharedStorage.cachedDominantColorHex = image.dominantColorHex()
    }

    func rescan() {
        stopAutoRefresh()
        stopLiveActivity()
        stopEventSubscriptions()
        speakers.removeAll()
        selectedSpeaker = nil
        SharedStorage.savedSpeakers = []
        SharedStorage.speakerIP = nil
        discovery.startScan()
    }

    // MARK: - Playback Controls

    func togglePlayPause() async {
        guard let backend = await controlBackendEnsured() else {
            errorMessage = SonosControlError.noBackend.localizedDescription
            return
        }
        let prev = transportState
        let wasPlaying = prev == .playing
        transportState = wasPlaying ? .paused : .playing
        do {
            try await SonosControl.togglePlayPause(backend, currentlyPlaying: wasPlaying)
            try? await Task.sleep(for: .milliseconds(300))
            await refreshState()
        } catch {
            transportState = prev
            errorMessage = error.localizedDescription
            await fallbackToCloudIfLANFailed(backend)
        }
    }

    func nextTrack() async {
        guard let backend = await controlBackendEnsured() else {
            errorMessage = SonosControlError.noBackend.localizedDescription
            return
        }
        do {
            try await SonosControl.next(backend)
            try? await Task.sleep(for: .milliseconds(500))
            await refreshState()
        } catch {
            errorMessage = error.localizedDescription
            await fallbackToCloudIfLANFailed(backend)
        }
    }

    func previousTrack() async {
        guard let backend = await controlBackendEnsured() else {
            errorMessage = SonosControlError.noBackend.localizedDescription
            return
        }
        do {
            try await SonosControl.previous(backend)
            try? await Task.sleep(for: .milliseconds(500))
            await refreshState()
        } catch {
            errorMessage = error.localizedDescription
            await fallbackToCloudIfLANFailed(backend)
        }
    }

    func toggleShuffle() async {
        // Play-mode changes are LAN-only — Sonos Cloud Control API has
        // `/playback/playMode` but shuffle / repeat semantics are slightly
        // different; keeping LAN-only here means the UI grays the button
        // out in remote mode rather than surprising the user.
        guard let ip = playbackIP else { return }
        let prev = isShuffling
        isShuffling = !prev
        playModeLockUntil = Date().addingTimeInterval(2)
        do {
            try await SonosAPI.setPlayMode(ip: ip, shuffle: isShuffling, repeat: repeatMode)
        } catch {
            isShuffling = prev
            playModeLockUntil = .distantPast
            errorMessage = error.localizedDescription
        }
    }

    func toggleRepeat() async {
        guard let ip = playbackIP else { return }
        let prev = repeatMode
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        playModeLockUntil = Date().addingTimeInterval(2)
        do {
            try await SonosAPI.setPlayMode(ip: ip, shuffle: isShuffling, repeat: repeatMode)
        } catch {
            repeatMode = prev
            playModeLockUntil = .distantPast
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Soundbar TV-mode toggles

    /// Pull the current Night Sound + Speech Enhancement state from the
    /// soundbar. We only call this when the active speaker is in TV input —
    /// the panel that exposes the toggles is hidden otherwise, so polling
    /// during music playback would just be wasted SOAP traffic.
    ///
    /// Honours `soundbarEQLockUntil` so a stale poll landing right after a
    /// user toggle can't stomp the optimistic UI value.
    func refreshSoundbarEQ() async {
        guard let ip = selectedSpeaker?.ipAddress else { return }
        guard Date() >= soundbarEQLockUntil else { return }
        do {
            let (night, speechEnabled, dialog) = try await SonosAPI.getSoundbarEQ(ip: ip)
            nightMode = night
            // Compose the unified 5-step Speech Enhancement enum:
            //   - master switch off → .off (regardless of DialogLevel)
            //   - master switch on  → DialogLevel clamped to 1–4
            // Legacy bars (no SpeechEnhanceEnabled field) get
            // `speechEnabled = dialog > 0` from the API helper, so
            // DialogLevel == 0 → .off, anything else → .low+.
            if speechEnabled, dialog > 0 {
                speechEnhancement = SpeechEnhancementLevel.from(rawLevel: dialog)
            } else {
                speechEnhancement = .off
            }
            SharedStorage.cachedSoundbarNightMode = nightMode
            SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = speechEnhancement.rawValue
        } catch {
            // Soft-fail: non-soundbars return errors here, and we don't want
            // to surface that — the UI just won't show the panel.
        }
    }

    func toggleNightMode() async {
        guard let speaker = selectedSpeaker else { return }
        let ip = speaker.ipAddress
        let prev = nightMode
        nightMode = !prev
        SharedStorage.cachedSoundbarNightMode = nightMode
        soundbarEQLockUntil = Date().addingTimeInterval(2)
        manageLiveActivity()

        if Self.shouldSendSoundbarCommandThroughRelay(
            usesRelay: currentActivityUsesRelay,
            relayWriterReady: liveActivityRelayWriterReady
        ) {
            if let relayState = await sendRelaySoundbarNightModeCommand(
                nightMode,
                fallbackGroupId: speaker.playbackIP
            ) {
                applyRelaySoundbarState(relayState)
            } else {
                nightMode = prev
                SharedStorage.cachedSoundbarNightMode = prev
                soundbarEQLockUntil = .distantPast
                manageLiveActivity()
                errorMessage = "NAS Relay command failed"
            }
            return
        }

        do {
            try await SonosAPI.setEQ(ip: ip, eqType: "NightMode", enabled: nightMode)
        } catch {
            nightMode = prev
            SharedStorage.cachedSoundbarNightMode = prev
            soundbarEQLockUntil = .distantPast
            manageLiveActivity()
            errorMessage = error.localizedDescription
        }
    }

    func setSpeechEnhancement(_ level: SpeechEnhancementLevel) async {
        guard let speaker = selectedSpeaker else { return }
        let ip = speaker.ipAddress
        let prev = speechEnhancement
        guard level != prev else { return }
        speechEnhancement = level
        SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = level.rawValue
        soundbarEQLockUntil = Date().addingTimeInterval(2)
        manageLiveActivity()
        if Self.shouldSendSoundbarCommandThroughRelay(
            usesRelay: currentActivityUsesRelay,
            relayWriterReady: liveActivityRelayWriterReady
        ) {
            if let relayState = await sendRelaySoundbarSpeechEnhancementCommand(
                level,
                fallbackGroupId: speaker.playbackIP
            ) {
                applyRelaySoundbarState(relayState)
            } else {
                speechEnhancement = prev
                SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = prev.rawValue
                soundbarEQLockUntil = .distantPast
                manageLiveActivity()
                errorMessage = "NAS Relay command failed"
            }
            return
        }

        // Arc Ultra requires writing both fields. `SpeechEnhanceEnabled` is
        // the master switch; `DialogLevel` carries the 1–4 intensity. The
        // device persists DialogLevel even when disabled (per Sonos UPnP
        // docs), so when the user turns it back on we want the level they
        // last picked to come right back. Older soundbars silently ignore
        // the unsupported `SpeechEnhanceEnabled` write, but we still send
        // `DialogLevel = 0/1` so legacy bars still respond to Off / Low.
        do {
            switch level {
            case .off:
                _ = try? await SonosAPI.setEQ(ip: ip, eqType: "SpeechEnhanceEnabled", enabled: false)
                try await SonosAPI.setEQLevel(ip: ip, eqType: "DialogLevel", level: 0)
            case .low, .medium, .high, .max:
                try await SonosAPI.setEQLevel(ip: ip, eqType: "DialogLevel", level: level.rawValue)
                _ = try? await SonosAPI.setEQ(ip: ip, eqType: "SpeechEnhanceEnabled", enabled: true)
            }
        } catch {
            speechEnhancement = prev
            SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = prev.rawValue
            soundbarEQLockUntil = .distantPast
            manageLiveActivity()
            errorMessage = error.localizedDescription
        }
    }

    /// Helper: when a LAN command fails we assume reachability might have
    /// flipped — invalidate the cached backend so the next probe re-classifies.
    /// No-op in cloud mode (there we just show the error; cloud failures
    /// don't usually mean we should retry differently).
    private func fallbackToCloudIfLANFailed(_ backend: SonosControl.Backend) async {
        if case .lan = backend {
            invalidateBackend()
            _ = await probeBackend()
        }
    }

    func seekTo(_ seconds: TimeInterval) async {
        guard let backend = await controlBackendEnsured() else { return }
        positionSeconds = seconds
        do {
            try await SonosControl.seek(backend, to: seconds)
        } catch {
            errorMessage = error.localizedDescription
            await fallbackToCloudIfLANFailed(backend)
        }
    }

    func updateVolume(_ newVolume: Int) async {
        guard let backend = await controlBackendEnsured() else { return }
        volume = newVolume
        if let idx = currentGroupStatusIndex() {
            groupStatuses[idx].volume = newVolume
        }
        do {
            try await SonosControl.setGroupVolume(backend, newVolume)
            SharedStorage.cachedVolume = newVolume
        } catch {
            errorMessage = error.localizedDescription
            await fallbackToCloudIfLANFailed(backend)
        }
    }

    func fetchMemberVolumes() async {
        for player in currentGroupMembers {
            if let vol = try? await SonosAPI.getVolume(ip: player.ipAddress) {
                memberVolumes[player.ipAddress] = vol
            }
        }
    }

    func setMemberVolume(ip: String, volume: Int) async {
        memberVolumes[ip] = volume
        do {
            try await SonosAPI.setVolume(ip: ip, volume: volume)
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Per-Group Controls

    func togglePlayPauseForGroup(groupID: String, coordinatorIP: String, currentState: TransportState) async {
        guard let idx = groupStatuses.firstIndex(where: { $0.id == groupID }) else { return }
        let prev = groupStatuses[idx].transportState
        let optimistic: TransportState = (prev == .playing) ? .paused : .playing
        groupStatuses[idx].transportState = optimistic
        do {
            if prev == .playing {
                try await SonosAPI.pause(ip: coordinatorIP)
            } else {
                try await SonosAPI.play(ip: coordinatorIP)
            }
            try? await Task.sleep(for: .milliseconds(400))
            // Skip the brief TRANSITIONING window Sonos returns mid-toggle —
            // otherwise the card icon bounces playing → transitioning → playing.
            // Same policy as `applyIncomingTransportState`.
            if let state = try? await SonosAPI.getTransportInfo(ip: coordinatorIP),
               state != .transitioning,
               let i = groupStatuses.firstIndex(where: { $0.id == groupID }) {
                groupStatuses[i].transportState = state
            }
        } catch {
            if let i = groupStatuses.firstIndex(where: { $0.id == groupID }) {
                groupStatuses[i].transportState = prev
            }
            errorMessage = error.localizedDescription
        }
    }

    func setVolumeForGroup(groupID: String, coordinatorIP: String, newVolume: Int) async {
        guard let idx = groupStatuses.firstIndex(where: { $0.id == groupID }) else { return }
        groupStatuses[idx].volume = newVolume
        do {
            // Use GroupRenderingControl so all group members are adjusted proportionally.
            try await SonosAPI.setGroupVolume(ip: coordinatorIP, volume: newVolume)
            if currentGroupStatusIndex() == idx {
                volume = newVolume
                SharedStorage.cachedVolume = newVolume
            }
        } catch { errorMessage = error.localizedDescription }
    }

    var queueUpdateID: String = "0"
    /// Observable set of URLs whose images have been persisted to disk (survives NSCache eviction).
    private(set) var cachedArtURLs: Set<String> = []

    /// Returns the cached image for a queue item URL, checking memory then disk.
    /// Falls back gracefully if NSCache evicted the image while the view re-renders.
    func queueImage(for urlStr: String) -> UIImage? {
        if let img = queueArtCache.object(forKey: urlStr as NSString) { return img }
        // NSCache evicted it — restore from disk (local flash, ~0.1 ms, safe on main thread).
        return QueueArtDiskCache.shared.image(for: urlStr)
    }
    /// NSCache stores the actual UIImages; auto-evicts under memory pressure, capped at 150 images (~30 MB).
    let queueArtCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 150
        c.totalCostLimit = 30 * 1024 * 1024
        return c
    }()
    /// Dominant color cache keyed by album art URL — avoids re-computing per-pixel analysis on every track change.
    private var dominantColorCache: [String: Color] = [:]
    private var queueLoaded = false
    private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var queueReorderGeneration = 0

    // MARK: - Queue

    func loadQueue() async {
        guard let ip = playbackIP else { return }
        do {
            let result = try await SonosAPI.getQueue(ip: ip)
            applyQueueResult(result)
        } catch {
            if queue.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    func queueReorderStatus(for item: QueueItem) -> QueueReorderStatus? {
        queueReorderStatusByItemID[item.id]
    }

    private func applyQueueResult(_ result: QueueResult) {
        queue = QueueReorderPolicy.confirmedQueue(result.items, preservingIDsFrom: queue)
        queueUpdateID = result.updateID
        queueLoaded = true
        pruneQueueReorderStatuses()
        schedulePrefetch()
    }

    private func pruneQueueReorderStatuses() {
        guard !queueReorderStatusByItemID.isEmpty else { return }
        let visibleIDs = Set(queue.map(\.id))
        queueReorderStatusByItemID = queueReorderStatusByItemID.filter { visibleIDs.contains($0.key) }
    }

    private func schedulePrefetch() {
        prefetchTask?.cancel()

        // Build fetch order: start from now-playing, go forward, then wrap to beginning.
        let nowIndex = queue.firstIndex(where: {
            $0.title == trackInfo?.title && $0.artist == trackInfo?.artist
        }) ?? 0
        let reordered = Array(queue[nowIndex...]) + Array(queue[..<nowIndex])

        let ordered = QueueArtPrefetchPolicy.urlsToPrefetch(
            from: reordered.compactMap { $0.albumArtURL },
            cachedURLs: cachedArtURLs
        )
        guard !ordered.isEmpty else { return }

        let diskCache = QueueArtDiskCache.shared
        prefetchTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                let maxConcurrent = QueueArtPrefetchPolicy.maxConcurrentFetches(for: ordered)
                var index = 0

                func addNext() {
                    guard index < ordered.count else { return }
                    let urlStr = ordered[index]
                    index += 1
                    group.addTask { [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        await self.fetchArtForURL(urlStr, diskCache: diskCache)
                    }
                }

                for _ in 0..<min(maxConcurrent, ordered.count) { addNext() }
                for await _ in group { addNext() }
            }
        }
    }

    private func fetchArtForURL(_ urlStr: String, diskCache: QueueArtDiskCache) async {
        guard !cachedArtURLs.contains(urlStr) else { return }

        // L2: disk cache.
        // L3: network. Always capture raw data so we can populate sibling disk slots.
        let imageData: Data
        if let d = diskCache.data(for: urlStr) {
            imageData = d
        } else {
            guard let url = URL(string: urlStr),
                  let downloaded = try? await Self.fetchAlbumArtData(from: url, originalURLString: urlStr) else { return }
            imageData = downloaded
            diskCache.store(imageData, for: urlStr)
        }
        guard let image = UIImage(data: imageData) else { return }
        let color = dominantColorCache[urlStr] ?? image.dominantColor()

        // Collect all other uncached URLs from the same album so one download
        // populates every track's cache entry simultaneously.
        let albumKey = queue.first(where: { $0.albumArtURL == urlStr })
            .map { "\($0.album)||||\($0.artist)" }
        var siblings: [String] = []
        if let key = albumKey {
            var seen = Set<String>()
            siblings = queue.compactMap { item -> String? in
                guard let u = item.albumArtURL,
                      u != urlStr,
                      !cachedArtURLs.contains(u),
                      "\(item.album)||||\(item.artist)" == key,
                      seen.insert(u).inserted else { return nil }
                return u
            }
        }

        // Write primary URL to memory cache.
        queueArtCache.setObject(image, forKey: urlStr as NSString, cost: imageData.count)
        // Write all sibling URLs to memory + disk cache.
        for sibling in siblings {
            queueArtCache.setObject(image, forKey: sibling as NSString, cost: imageData.count)
            if !diskCache.contains(sibling) { diskCache.store(imageData, for: sibling) }
        }

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.dominantColorCache[urlStr] = color
            self.cachedArtURLs.insert(urlStr)
            for sibling in siblings {
                self.dominantColorCache[sibling] = color
                self.cachedArtURLs.insert(sibling)
            }
        }
    }

    func deleteFromQueue(item: QueueItem) async {
        guard let ip = playbackIP else { return }
        do {
            try await SonosAPI.removeTrackFromQueue(ip: ip, objectID: item.objectID, updateID: queueUpdateID)
            await loadQueue()
        } catch { errorMessage = error.localizedDescription }
    }

    func moveQueueItem(from source: IndexSet, to destination: Int) {
        guard let ip = playbackIP else { return }
        guard let fromIndex = source.first else { return }
        guard queue.indices.contains(fromIndex) else { return }
        let previousQueue = queue
        let movedItemIDs = source.sorted().compactMap { index in
            queue.indices.contains(index) ? queue[index].id : nil
        }
        let sonosFrom = fromIndex + 1
        let sonosDest = destination + 1
        let reorderedQueue = QueueReorderPolicy.reordered(queue, from: source, to: destination)
        guard reorderedQueue.map(\.id) != queue.map(\.id) else { return }
        queue = reorderedQueue
        queueReorderGeneration += 1
        let generation = queueReorderGeneration
        setQueueReorderStatus(.syncing, for: movedItemIDs)

        let capturedUpdateID = queueUpdateID
        Task {
            do {
                try await SonosAPI.reorderTracksInQueue(ip: ip, startIndex: sonosFrom,
                                                         numTracks: 1, insertBefore: sonosDest,
                                                         updateID: capturedUpdateID)
                let result = try await SonosAPI.getQueue(ip: ip)
                guard generation == queueReorderGeneration else { return }
                applyQueueResult(result)
                showQueueReorderConfirmation(for: movedItemIDs, generation: generation)
            } catch {
                guard generation == queueReorderGeneration else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    queue = previousQueue
                    setQueueReorderStatus(nil, for: movedItemIDs)
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setQueueReorderStatus(_ status: QueueReorderStatus?, for itemIDs: [String]) {
        guard !itemIDs.isEmpty else { return }
        for id in itemIDs {
            if let status {
                queueReorderStatusByItemID[id] = status
            } else {
                queueReorderStatusByItemID.removeValue(forKey: id)
            }
        }
    }

    private func showQueueReorderConfirmation(for itemIDs: [String], generation: Int) {
        withAnimation(.easeInOut(duration: 0.16)) {
            setQueueReorderStatus(.confirmed, for: itemIDs)
        }

        Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard generation == queueReorderGeneration else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                setQueueReorderStatus(nil, for: itemIDs)
            }
        }
    }

    func playQueueItemNext(_ item: QueueItem) async {
        guard let ip = playbackIP else { return }
        guard let sourceIndex = queue.firstIndex(where: { $0.id == item.id }) else { return }
        let currentIndex = queue.firstIndex(where: {
            $0.title == trackInfo?.title && $0.artist == trackInfo?.artist
        }) ?? 0
        guard queue.indices.contains(currentIndex) else { return }

        let previousQueue = queue
        let movedItemIDs = [queue[sourceIndex].id]
        let targetPosition = currentIndex + 2 // Sonos uses 1-based, insert after current
        let sonosFrom = queue[sourceIndex].trackNumber
        let reorderedQueue = QueueReorderPolicy.playingNextQueue(
            queue,
            itemID: queue[sourceIndex].id,
            afterCurrentItemID: queue[currentIndex].id
        )
        guard reorderedQueue.map(\.id) != queue.map(\.id) else { return }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            queue = reorderedQueue
        }
        queueReorderGeneration += 1
        let generation = queueReorderGeneration
        setQueueReorderStatus(.syncing, for: movedItemIDs)
        let capturedUpdateID = queueUpdateID

        do {
            try await SonosAPI.reorderTracksInQueue(ip: ip, startIndex: sonosFrom,
                                                     numTracks: 1, insertBefore: targetPosition,
                                                     updateID: capturedUpdateID)
            let result = try await SonosAPI.getQueue(ip: ip)
            guard generation == queueReorderGeneration else { return }
            applyQueueResult(result)
            showQueueReorderConfirmation(for: movedItemIDs, generation: generation)
        } catch {
            guard generation == queueReorderGeneration else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                queue = previousQueue
                setQueueReorderStatus(nil, for: movedItemIDs)
            }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func playNext(uri: String, metadata: String) async -> Bool {
        guard let ip = playbackIP else {
            errorMessage = HandoffTransferError.noSelectedSpeaker.localizedDescription
            return false
        }
        let startedAt = Date()
        SonosLog.debug(
            .playbackLink,
            "manager.playNext start ip=\(ip) isPlayingFromQueue=\(isPlayingFromQueue) " +
                "uri=\(SonosLog.playbackLinkValue(uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(metadata))")
        do {
            // Sonos's `EnqueueAsNext=1` flag is unreliable across
            // firmwares — when an album/playlist is playing it often
            // gets interpreted as "after the current group ends",
            // landing the new track at the bottom of the queue. Compute
            // the insertion point ourselves: `currentTrack + 1` puts it
            // immediately after whatever's playing now.
            //
            // For non-queue sources (radio, TV, line-in) there's no
            // meaningful "current track number", so fall back to the
            // legacy append-at-end behavior.
            if isPlayingFromQueue,
               let current = try await SonosAPI.getCurrentTrackNumber(ip: ip) {
                SonosLog.debug(
                    .playbackLink,
                    "manager.playNext insert ip=\(ip) currentTrack=\(current) " +
                        "position=\(current + 1) asNext=true")
                try await SonosAPI.addURIToQueue(
                    ip: ip, uri: uri, metadata: metadata,
                    position: current + 1, asNext: true)
            } else {
                SonosLog.debug(
                    .playbackLink,
                    "manager.playNext insert ip=\(ip) currentTrack=nil position=0 asNext=true")
                try await SonosAPI.addURIToQueue(
                    ip: ip, uri: uri, metadata: metadata, asNext: true)
            }
            await loadQueue()
            SonosLog.debug(
                .playbackLink,
                "manager.playNext success ip=\(ip) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            return true
        } catch {
            SonosLog.error(
                .playbackLink,
                "manager.playNext failed ip=\(ip) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) " +
                    "error=\(error) uri=\(SonosLog.playbackLinkValue(uri))")
            errorMessage = error.localizedDescription
            return false
        }
    }

    func playTrackInQueue(_ item: QueueItem) async {
        guard let ip = playbackIP else { return }
        do {
            if !isPlayingFromQueue, let speaker = selectedSpeaker {
                try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: speaker.id)
            }
            try await SonosAPI.seekToTrack(ip: ip, trackNumber: item.trackNumber)
            try await SonosAPI.play(ip: ip)
            try? await Task.sleep(for: .milliseconds(300))
            await refreshState()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Speaker Grouping

    var currentGroupMembers: [SonosPlayer] {
        guard let selected = selectedSpeaker else { return [] }
        let groupId = selected.groupId ?? selected.id
        return allSpeakers.filter { $0.groupId == groupId && !$0.isInvisible }
    }

    func musicAmbienceSnapshot() -> HueAmbiencePlaybackSnapshot {
        Self.musicAmbienceSnapshot(
            selectedSpeaker: selectedSpeaker,
            currentGroupMembers: currentGroupMembers,
            trackInfo: trackInfo,
            isPlaying: isPlaying,
            albumArtData: albumArtImage?.jpegData(compressionQuality: 0.85)
        )
    }

    var isEverywhereActive: Bool {
        let visible = allSpeakers.filter { !$0.isInvisible }
        guard visible.count > 1, let gid = selectedSpeaker.map({ $0.groupId ?? $0.id }) else { return false }
        return visible.allSatisfy { $0.groupId == gid }
    }

    func addSpeakerToGroup(_ speaker: SonosPlayer) async {
        guard let coordinator = selectedSpeaker else { return }
        let coordUUID = coordinator.id
        do {
            try await SonosAPI.joinGroup(speakerIP: speaker.ipAddress, coordinatorUUID: coordUUID)
            try? await Task.sleep(for: .milliseconds(500))
            await reloadTopology()
        } catch { errorMessage = error.localizedDescription }
    }

    func removeSpeakerFromGroup(_ speaker: SonosPlayer) async {
        do {
            try await SonosAPI.leaveGroup(speakerIP: speaker.ipAddress)
            try? await Task.sleep(for: .milliseconds(500))
            await reloadTopology()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Separates every non-coordinator member of the group, leaving each speaker standalone.
    func separateGroup(groupID: String) async {
        guard let source = groupStatuses.first(where: { $0.id == groupID }) else { return }
        let nonCoordinators = source.members.filter { $0.id != source.coordinator.id }
        guard !nonCoordinators.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        for member in nonCoordinators {
            do {
                try await SonosAPI.leaveGroup(speakerIP: member.ipAddress)
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        await reloadTopology()
        await refreshAllGroupStatuses()
    }

    /// Merges every member of `sourceGroupID` into `targetGroupID`.
    func mergeGroups(sourceGroupID: String, intoGroupID: String) async {
        guard sourceGroupID != intoGroupID,
              let target = groupStatuses.first(where: { $0.id == intoGroupID }),
              let source = groupStatuses.first(where: { $0.id == sourceGroupID }) else { return }

        isLoading = true
        defer { isLoading = false }

        for member in source.members {
            do {
                try await SonosAPI.joinGroup(speakerIP: member.ipAddress,
                                             coordinatorUUID: target.coordinator.id)
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        await reloadTopology()
        await refreshAllGroupStatuses()
    }

    func transferPlayback(to target: SonosPlayer) async {
        guard let current = selectedSpeaker, current.id != target.id else { return }
        do {
            let targetAlreadyInGroup = currentGroupMembers.contains { $0.id == target.id }

            if targetAlreadyInGroup {
                // Target is already in our group — just remove current coordinator
                // so target becomes the new coordinator and keeps playing.
                try await SonosAPI.leaveGroup(speakerIP: current.ipAddress)
            } else {
                // Target is standalone — add it to our group first, then remove current.
                try await SonosAPI.joinGroup(speakerIP: target.ipAddress, coordinatorUUID: current.id)
                try? await Task.sleep(for: .milliseconds(500))
                try await SonosAPI.leaveGroup(speakerIP: current.ipAddress)
            }

            try? await Task.sleep(for: .milliseconds(500))
            await reloadTopology()

            if let updated = speakers.first(where: { $0.id == target.id })
                ?? allSpeakers.first(where: { $0.id == target.id }) {
                await selectSpeaker(updated)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshAllGroupStatuses() async {
        switch transportBackend {
        case .lan:
            await refreshAllGroupStatusesLAN()
        case .cloud:
            await refreshAllGroupStatusesCloud()
        case .unknown:
            // Don't burn a LAN UPnP call (~30s timeout on cellular) while
            // the backend is still being probed. The next polling tick — or
            // whatever kicked off the probe — will re-route us into the
            // correct branch once `transportBackend` settles. Meanwhile the
            // Home tab's "Speaker unreachable" banner is the right terminal
            // state for a genuinely unreachable speaker.
            return
        }
    }

    private func refreshAllGroupStatusesLAN() async {
        guard let anyIP = allSpeakers.first?.ipAddress ?? selectedSpeaker?.ipAddress else { return }

        do {
            let fresh = try await SonosAPI.getZoneGroupState(ip: anyIP)
            allSpeakers = fresh
            speakers = fresh.filter(\.isCoordinator)
            SharedStorage.savedSpeakers = fresh

            var statuses: [SpeakerGroupStatus] = []
            let coordinators = fresh.filter(\.isCoordinator)

            for coord in coordinators {
                let members = fresh.filter { $0.groupId == coord.groupId && !$0.isInvisible }
                do {
                    async let t = SonosAPI.getTransportInfo(ip: coord.ipAddress)
                    async let p = SonosAPI.getPositionInfo(ip: coord.ipAddress)
                    async let v = SonosAPI.getGroupVolume(ip: coord.ipAddress)
                    let state = try await t
                    let track = try await p
                    let vol = (try? await v) ?? 0
                    statuses.append(SpeakerGroupStatus(
                        id: coord.groupId ?? coord.id,
                        coordinator: coord, members: members,
                        trackInfo: track, transportState: state, volume: vol
                    ))
                } catch {
                    statuses.append(SpeakerGroupStatus(
                        id: coord.groupId ?? coord.id,
                        coordinator: coord, members: members,
                        trackInfo: nil, transportState: .unknown, volume: 0
                    ))
                }
            }
            applyPreferredSpeakerOrder(to: statuses)
            await loadGroupAlbumColors()
        } catch { /* keep existing data */ }
    }

    /// Cloud version of `refreshAllGroupStatuses`. Populates the Home tab
    /// speaker-group cards from the Sonos Cloud Control API's `getGroups`
    /// endpoint so the UI doesn't get stuck on "Loading speakers…" when the
    /// user is off-LAN. Per-group track info / volume can't be fetched
    /// cheaply for non-selected groups (would need one playbackMetadata call
    /// per group), so:
    ///   - The currently selected group gets the track info the main
    ///     `refreshStateCloud` already filled in.
    ///   - Other groups show the transport state from `playbackState` but
    ///     leave `trackInfo` empty.
    private func refreshAllGroupStatusesCloud() async {
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            projectSkeletonGroupStatusesFromSavedSpeakers()
            return
        }
        do {
            let response = try await SonosCloudAPI.getGroups(
                token: token, householdId: householdId)

            // Merge cloud players with anything we already know locally
            // (e.g. from a previous LAN session that got persisted). This
            // keeps per-player IPs around even off-LAN — useful if Wi-Fi
            // comes back and the probe flips to .lan.
            //
            // Name collisions happen in practice: a single speaker often
            // appears twice in `allSpeakers` — the real entry plus a
            // hidden (`isInvisible: true`) shadow for stereo-pair / home
            // theater satellites. When both entries share a display name,
            // prefer the *visible* one; otherwise the Home card picks up
            // the hidden shadow and renders a blank speaker name (the
            // `visibleMembers` filter drops it).
            let savedByName = Dictionary(
                allSpeakers.map { ($0.name, $0) },
                uniquingKeysWith: { first, second in
                    first.isInvisible && !second.isInvisible ? second : first
                })

            // Fetch per-group playback metadata concurrently so every card
            // gets its track name / artist / album art — not just the
            // currently selected group. For a typical 2-4 group household
            // this is 2-4 parallel HTTPS calls, cheap enough to run every
            // ~6s alongside the `getGroups` call above.
            // Per-group fan-out: metadata (track name/art), playback status
            // (position + actual transport state), and group volume. Each
            // call is independent, so run them all in one big TaskGroup.
            // Total cost for a household of N groups is 3N parallel HTTPS
            // calls every ~6s — still small, and enough to give every
            // card on Home a fully-populated mini-now-playing + volume.
            typealias PerGroup = (
                meta: SonosCloudAPI.CloudPlaybackMetadata?,
                status: SonosCloudAPI.PlaybackStatus?,
                volume: SonosCloudAPI.GroupVolume?
            )
            var perGroup: [String: PerGroup] = [:]
            await withTaskGroup(of: (String, String, Any?).self) { group in
                for cloudGroup in response.groups {
                    let gid = cloudGroup.id
                    group.addTask {
                        let meta = try? await SonosCloudAPI.getPlaybackMetadata(
                            token: token, groupId: gid)
                        return (gid, "meta", meta as Any?)
                    }
                    group.addTask {
                        let status = try? await SonosCloudAPI.getPlaybackStatus(
                            token: token, groupId: gid)
                        return (gid, "status", status as Any?)
                    }
                    group.addTask {
                        let vol = try? await SonosCloudAPI.getGroupVolume(
                            token: token, groupId: gid)
                        return (gid, "volume", vol as Any?)
                    }
                }
                for await (gid, kind, value) in group {
                    var entry = perGroup[gid] ?? (nil, nil, nil)
                    switch kind {
                    case "meta":   entry.meta   = value as? SonosCloudAPI.CloudPlaybackMetadata
                    case "status": entry.status = value as? SonosCloudAPI.PlaybackStatus
                    case "volume": entry.volume = value as? SonosCloudAPI.GroupVolume
                    default: break
                    }
                    perGroup[gid] = entry
                }
            }

            var statuses: [SpeakerGroupStatus] = []
            for cloudGroup in response.groups {
                // Each group's members = cloud players whose ids match
                // `playerIds`. Fall back to name matching for savedSpeakers
                // which we saw via UPnP (those have RINCON ids, the cloud
                // uses a parallel id scheme).
                let players = response.players.filter { cloudGroup.playerIds.contains($0.id) }
                let members: [SonosPlayer] = players.map { cloudPlayer in
                    if let saved = savedByName[cloudPlayer.name] { return saved }
                    // Synthesize a LAN-less placeholder; ip is empty so LAN
                    // commands will no-op but group membership displays fine.
                    return SonosPlayer(
                        id: cloudPlayer.id, name: cloudPlayer.name,
                        ipAddress: "", isCoordinator: true,
                        groupId: cloudGroup.id)
                }
                let coord = members.first ?? SonosPlayer(
                    id: cloudGroup.id, name: cloudGroup.name,
                    ipAddress: "", isCoordinator: true,
                    groupId: cloudGroup.id)

                let isSelected = cloudGroup.id == cloudGroupId
                let entry = perGroup[cloudGroup.id] ?? (meta: nil, status: nil, volume: nil)

                // Prefer the live `playbackStatus` result for transport
                // state (more authoritative than the `getGroups`-embedded
                // `playbackState`); fall back to the main `transportState`
                // when this group is the selected one and already fresh.
                let state: TransportState = {
                    if isSelected { return transportState }
                    if let raw = entry.status?.playbackState {
                        return Self.transportState(fromCloudPlaybackState: raw)
                    }
                    return Self.transportState(fromCloudPlaybackState: cloudGroup.playbackState)
                }()

                // Assemble a TrackInfo for the card: selected group reuses
                // the one `refreshStateCloud` already enriched (has audio
                // quality etc.); other groups get a minimal version built
                // from their per-group metadata fetch above — now also
                // carrying `position` so the card's progress ring fills in.
                let track: TrackInfo? = {
                    if isSelected { return trackInfo }
                    guard let meta = entry.meta,
                          let cloudTrack = meta.currentItem?.track else { return nil }
                    // Same LAN-URL filter as `refreshStateCloud` — drop
                    // speaker-local `getaa` URLs that don't work off-LAN.
                    let artURL = Self.pickPublicArtURL(
                        cloudTrack.imageUrl,
                        cloudTrack.album?.imageUrl,
                        meta.container?.imageUrl)
                    let durSec = (cloudTrack.durationMillis).map {
                        TimeInterval($0) / 1000.0
                    } ?? 0
                    let posSec: TimeInterval = (entry.status?.positionMillis).map {
                        TimeInterval($0) / 1000.0
                    } ?? 0
                    let sourceName = cloudTrack.service?.name ?? meta.container?.name
                    return TrackInfo(
                        title: cloudTrack.name ?? "",
                        artist: cloudTrack.artist?.name ?? "",
                        album: cloudTrack.album?.name ?? "",
                        albumArtURL: artURL,
                        duration: SonosTime.apiFormat(durSec),
                        position: SonosTime.apiFormat(posSec),
                        source: PlaybackSource.from(serviceName: sourceName))
                }()

                // Group volume: selected group uses `manager.volume` (kept
                // live for the full player); others read from the cloud
                // `groupVolume` fan-out. Nil response → 0 as a safe sentinel.
                let vol: Int = isSelected
                    ? volume
                    : (entry.volume?.volume ?? 0)

                statuses.append(SpeakerGroupStatus(
                    id: cloudGroup.id,
                    coordinator: coord, members: members,
                    trackInfo: track, transportState: state, volume: vol
                ))
            }
            applyPreferredSpeakerOrder(to: statuses)
            await loadGroupAlbumColors()
        } catch {
            // `getGroups` failed (network blip, token drift, Sonos cloud
            // hiccup). Don't leave the Home tab stuck on "Loading speakers…"
            // — project whatever `savedSpeakers` we have into placeholder
            // cards with unknown transport state so the user at least sees
            // familiar scaffolding. The next refresh tick will overwrite
            // with real data if the cloud recovers.
            SonosLog.error(.sonosCloud, "refreshAllGroupStatusesCloud failed: \(error)")
            projectSkeletonGroupStatusesFromSavedSpeakers()
        }
    }

    /// Fallback used when the cloud-side group refresh fails but we still
    /// have a saved roster from a prior LAN session. Produces minimal
    /// `SpeakerGroupStatus` entries — enough to render speaker cards with
    /// names + membership, but `trackInfo` / `transportState` are blanked.
    /// Returns the first URL string that's actually reachable from the
    /// current network. Sonos Cloud's `playbackMetadata` often hands back
    /// a `track.imageUrl` pointing at the speaker's own LAN address
    /// (`http://192.168.x.x:1400/getaa?…`) — great when you're in the
    /// house, totally dead over cellular. Filter those out in cloud mode
    /// so the CDN fallbacks (`album.imageUrl`, `container.imageUrl`)
    /// actually get a chance to render.
    private static func pickPublicArtURL(_ candidates: String?...) -> String? {
        for case let url? in candidates where isPubliclyReachable(url) {
            return url
        }
        return nil
    }

    private static func isPubliclyReachable(_ urlStr: String) -> Bool {
        guard let url = URL(string: urlStr), let host = url.host else { return false }
        // Accept https outright (mzstatic, aliyuncs, etc. — cross-network
        // CDN URLs). Plain http is only accepted if the host is *not* a
        // private IP literal — matches Sonos's pattern of serving art
        // off the speaker itself on port 1400.
        if url.scheme == "https" { return true }
        // Host is a literal IP?
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            let a = parts[0], b = parts[1]
            let isPrivate =
                a == 10 ||
                (a == 192 && b == 168) ||
                (a == 172 && (16...31).contains(b)) ||
                a == 127
            return !isPrivate
        }
        // Non-IP hostname over plain http — rare but let it through; ATS
        // will block it if it's actually insecure.
        return true
    }

    private func projectSkeletonGroupStatusesFromSavedSpeakers() {
        guard groupStatuses.isEmpty, !allSpeakers.isEmpty else { return }
        let coordinators = allSpeakers.filter(\.isCoordinator)
        let statuses = coordinators.map { coord in
            let members = allSpeakers.filter {
                $0.groupId == coord.groupId && !$0.isInvisible
            }
            return SpeakerGroupStatus(
                id: coord.groupId ?? coord.id,
                coordinator: coord, members: members,
                trackInfo: nil, transportState: .unknown, volume: 0)
        }
        applyPreferredSpeakerOrder(to: statuses)
    }

    private func loadGroupAlbumColors() async {
        for status in groupStatuses {
            let key = status.id
            if status.coordinator.id == selectedSpeaker?.id {
                // Mirror the selected speaker's live values verbatim — the
                // earlier `if let` skipped writes when albumArtImage was
                // nil, which kept the previous track's cover lingering on
                // the home card after switching to TV input.
                groupAlbumColors[key] = albumArtDominantColor
                groupAlbumImages[key] = albumArtImage
                continue
            }
            guard let urlStr = status.trackInfo?.albumArtURL, !urlStr.isEmpty,
                  let url = URL(string: urlStr) else {
                groupAlbumColors[key] = nil
                groupAlbumImages[key] = nil
                groupLastArtURL[key] = nil
                continue
            }
            if groupAlbumImages[key] != nil, groupLastArtURL[key] == urlStr {
                continue
            }
            do {
                let data = try await Self.fetchAlbumArtData(from: url, originalURLString: urlStr)
                if let image = UIImage(data: data) {
                    groupAlbumImages[key] = image
                    groupLastArtURL[key] = urlStr
                    let color = dominantColorCache[urlStr] ?? image.dominantColor()
                    dominantColorCache[urlStr] = color
                    groupAlbumColors[key] = color
                }
            } catch {
                groupAlbumColors[key] = nil
                groupAlbumImages[key] = nil
                groupLastArtURL[key] = nil
            }
        }
    }

    private func reloadTopology() async {
        guard let anyIP = allSpeakers.first?.ipAddress ?? selectedSpeaker?.ipAddress else { return }
        if let fresh = try? await SonosAPI.getZoneGroupState(ip: anyIP) {
            allSpeakers = fresh
            speakers = fresh.filter(\.isCoordinator)
            SharedStorage.savedSpeakers = fresh
        }
        await refreshAllGroupStatuses()
    }

    /// Override track metadata (e.g. when Sonos can't resolve it) and reload album art.
    func patchTrackInfo(title: String, artist: String, album: String, albumArtURL: String?) {
        trackInfo?.title = title
        trackInfo?.artist = artist
        trackInfo?.album = album
        if let art = albumArtURL {
            trackInfo?.albumArtURL = art
        }
        syncCurrentGroupStatusFromPlaybackState()
        updateSharedCache()
        Task { await loadAlbumArt() }
    }

    // MARK: - State Refresh

    /// Drives both the LAN UPnP polling (fast, rich) and the Cloud Control
    /// API polling (slower, lighter) via `transportBackend`. `.unknown`
    /// triggers a probe first, then fills in whichever pipe succeeded.
    func refreshState() async {
        switch transportBackend {
        case .lan:
            await refreshStateLAN()
        case .cloud:
            await refreshStateCloud()
        case .unknown:
            _ = await probeBackend()
            // After probe, route accordingly (one level of recursion max).
            if transportBackend == .lan { await refreshStateLAN() }
            else if transportBackend == .cloud { await refreshStateCloud() }
            else {
                // Still nothing — keep existing state, surface friendly error.
                connectionState = .disconnected
                if errorMessage == nil {
                    errorMessage = SonosControlError.noBackend.localizedDescription
                }
            }
        }
    }

    /// Refresh after a handoff using the backend captured when the transfer
    /// started. This avoids accidentally polling a newly-selected speaker if
    /// the user switches targets while the handoff is settling.
    func refreshState(
        usingLockedBackend backend: SonosControl.Backend,
        expectedSpeakerID: String,
        loadQueue: Bool = false
    ) async -> Bool {
        guard selectedSpeaker?.id == expectedSpeakerID else { return false }

        switch backend {
        case .lan(let ip, _, _):
            return await refreshLockedLANState(
                ip: ip,
                expectedSpeakerID: expectedSpeakerID,
                loadQueue: loadQueue)
        case .cloud(let groupId, let token, _, _):
            return await refreshLockedCloudState(
                token: token,
                groupId: groupId,
                expectedSpeakerID: expectedSpeakerID)
        }
    }

    private func refreshLockedLANState(
        ip: String,
        expectedSpeakerID: String,
        loadQueue: Bool
    ) async -> Bool {
        guard selectedSpeaker?.id == expectedSpeakerID else { return false }

        do {
            async let transportCall = SonosAPI.getTransportInfo(ip: ip)
            async let positionCall = SonosAPI.getPositionInfo(ip: ip)
            async let volumeCall = SonosAPI.getGroupVolume(ip: ip)
            async let modeCall = SonosAPI.getPlayMode(ip: ip)
            async let mediaCall = SonosAPI.getMediaInfo(ip: ip)

            let incomingTransport = try await transportCall
            let positionInfo = try await positionCall
            let groupVolume = try await volumeCall
            let playMode = try await modeCall
            let mediaURI = try? await mediaCall
            let queueSnapshot = loadQueue ? (try? await SonosAPI.getQueue(ip: ip)) : nil

            guard selectedSpeaker?.id == expectedSpeakerID else { return false }

            applyIncomingTransportState(incomingTransport)
            if positionInfo.source == .tv {
                await refreshSoundbarEQ()
            }
            var incomingTrackInfo = Self.reconciledLANTrackInfo(
                positionInfo,
                cachedCloudQuality: cachedCloudQuality,
                cloudQualityIsAuthoritative: SonosAuth.shared.isLoggedIn
                    && isCloudQualityAuthoritative(positionInfo.source)
            )
            if let localMetadata = await fetchLocalControlPlaybackMetadata(ip: ip) {
                incomingTrackInfo = Self.trackInfo(incomingTrackInfo, applyingPlaybackMetadata: localMetadata)
                cacheAudioQualityIfPresent(incomingTrackInfo.audioQuality, for: incomingTrackInfo)
            }
            trackInfo = incomingTrackInfo
            volume = groupVolume
            if let idx = currentGroupStatusIndex() {
                groupStatuses[idx].volume = groupVolume
            }
            isPlayingFromQueue = mediaURI?.hasPrefix("x-rincon-queue:") ?? true
            if Date() > playModeLockUntil {
                isShuffling = playMode.shuffle
                repeatMode = playMode.repeat
            }

            positionSeconds = incomingTrackInfo.positionSeconds
            durationSeconds = incomingTrackInfo.durationSeconds
            positionFetchedAt = Date()
            syncCurrentGroupStatusFromPlaybackState()

            if let queueSnapshot {
                queue = queueSnapshot.items
                queueUpdateID = queueSnapshot.updateID
                queueLoaded = true
                schedulePrefetch()
            }

            consecutiveFailures = 0
            connectionState = .connected
            errorMessage = nil
            ensureEventSubscriptionsIfNeeded()
            updateSharedCache()
            managePositionTimer()
            manageLiveActivity()
            return selectedSpeaker?.id == expectedSpeakerID
        } catch {
            guard selectedSpeaker?.id == expectedSpeakerID else { return false }
            errorMessage = error.localizedDescription
            return true
        }
    }

    private func refreshLockedCloudState(
        token: String,
        groupId: String,
        expectedSpeakerID: String
    ) async -> Bool {
        guard selectedSpeaker?.id == expectedSpeakerID else { return false }

        do {
            async let statusCall = SonosCloudAPI.getPlaybackStatus(token: token, groupId: groupId)
            async let metaCall = SonosCloudAPI.getPlaybackMetadata(token: token, groupId: groupId)
            async let volumeCall = SonosCloudAPI.getGroupVolume(token: token, groupId: groupId)
            let status = try await statusCall
            let meta = try await metaCall
            let groupVolume = try? await volumeCall

            guard selectedSpeaker?.id == expectedSpeakerID else { return false }

            applyIncomingTransportState(
                Self.transportState(fromCloudPlaybackState: status.playbackState))

            if Date() > playModeLockUntil,
               let modes = status.playModes {
                isShuffling = modes.shuffle ?? false
                repeatMode = Self.repeatMode(fromCloud: modes.repeatMode, one: modes.repeatOne)
            }

            let track = meta.currentItem?.track
            let durationSec: TimeInterval = (track?.durationMillis).map { TimeInterval($0) / 1000.0 } ?? 0
            let positionSec: TimeInterval = (status.positionMillis).map { TimeInterval($0) / 1000.0 } ?? 0

            let previousTrackInfo = trackInfo
            var info = previousTrackInfo ?? TrackInfo(title: "", artist: "", album: "")
            info.title = track?.name ?? info.title
            info.artist = track?.artist?.name ?? info.artist
            info.album = track?.album?.name ?? info.album
            let artURL = Self.pickPublicArtURL(
                track?.imageUrl,
                track?.album?.imageUrl,
                meta.container?.imageUrl)
            info.albumArtURL = AlbumArtURLCarryoverPolicy.albumArtURL(
                incomingURL: artURL,
                previousTrackInfo: previousTrackInfo,
                incomingTrackInfo: info
            )
            info.duration = SonosTime.apiFormat(durationSec)
            info.position = SonosTime.apiFormat(positionSec)
            let sourceHint = track?.service?.name ?? meta.container?.name
            info.source = PlaybackSource.from(serviceName: sourceHint)
            if let q = track?.quality, let mapped = AudioQuality.from(cloudQuality: q) {
                info.audioQuality = mapped
            }
            trackInfo = info

            positionSeconds = positionSec
            durationSeconds = durationSec
            if let groupVolume = groupVolume?.volume {
                volume = groupVolume
                if let idx = currentGroupStatusIndex() {
                    groupStatuses[idx].volume = groupVolume
                }
            }
            positionFetchedAt = Date()
            syncCurrentGroupStatusFromPlaybackState()

            consecutiveFailures = 0
            connectionState = .connected
            errorMessage = nil
            updateSharedCache()
            managePositionTimer()
            manageLiveActivity()
            return selectedSpeaker?.id == expectedSpeakerID
        } catch SonosCloudError.unauthorized {
            _ = await SonosAuth.shared.refreshAccessToken()
            return selectedSpeaker?.id == expectedSpeakerID
        } catch {
            guard selectedSpeaker?.id == expectedSpeakerID else { return false }
            errorMessage = error.localizedDescription
            return true
        }
    }

    private func refreshStateLAN() async {
        await lanRefreshGate.run { [weak self] in
            await self?.performRefreshStateLAN()
        }
    }

    private func performRefreshStateLAN() async {
        guard let pIP = playbackIP else { return }
        do {
            async let t = SonosAPI.getTransportInfo(ip: pIP)
            async let p = SonosAPI.getPositionInfo(ip: pIP)
            async let v = SonosAPI.getGroupVolume(ip: pIP)
            async let m = SonosAPI.getPlayMode(ip: pIP)
            async let mediaURI = SonosAPI.getMediaInfo(ip: pIP)
            applyIncomingTransportState(try await t)
            // `getPositionInfo` already ran `PlaybackSource.from(trackURI:)`
            // which consults SharedStorage's sid → name map for services
            // whose local sid varies per install (NetEase etc.), so we no
            // longer need a manual second pass here.
            let positionInfo = try await p
            let groupVolume = try await v
            volume = groupVolume
            if let idx = currentGroupStatusIndex() {
                groupStatuses[idx].volume = groupVolume
            }
            // Soundbar TV-mode toggles only show up in the player UI when
            // source == .tv — fetching them off the music path would just
            // be wasted SOAP calls (and most non-soundbars 402 on it).
            if positionInfo.source == .tv {
                await refreshSoundbarEQ()
            }
            let mode = try await m
            isPlayingFromQueue = (try? await mediaURI)?.hasPrefix("x-rincon-queue:") ?? true
            if Date() > playModeLockUntil {
                isShuffling = mode.shuffle
                repeatMode = mode.repeat
            }

            var incomingTrackInfo = Self.reconciledLANTrackInfo(
                positionInfo,
                cachedCloudQuality: cachedCloudQuality,
                cloudQualityIsAuthoritative: SonosAuth.shared.isLoggedIn
                    && isCloudQualityAuthoritative(positionInfo.source)
            )
            if let localMetadata = await fetchLocalControlPlaybackMetadata(ip: pIP) {
                incomingTrackInfo = Self.trackInfo(incomingTrackInfo, applyingPlaybackMetadata: localMetadata)
                cacheAudioQualityIfPresent(incomingTrackInfo.audioQuality, for: incomingTrackInfo)
            }
            trackInfo = incomingTrackInfo
            positionSeconds = incomingTrackInfo.positionSeconds
            durationSeconds = incomingTrackInfo.durationSeconds
            positionFetchedAt = Date()

            consecutiveFailures = 0
            connectionState = .connected
            errorMessage = nil
            ensureEventSubscriptionsIfNeeded()

            await enrichAudioQualityFromCloud()
            syncCurrentGroupStatusFromPlaybackState()
            updateSharedCache()
            await loadAlbumArt()
            MusicAmbienceManager.shared.receive(snapshot: musicAmbienceSnapshot())
            if queueLoaded { await loadQueue() }
            managePositionTimer()
            manageLiveActivity()
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= Self.maxConsecutiveRefreshFailures {
                connectionState = .disconnected
                errorMessage = "Connection lost — pull to refresh."
                // Mid-session LAN loss — maybe the user walked off the Wi-Fi.
                // Invalidate the backend so the next command probes again
                // and has a chance to fall over to cloud.
                invalidateBackend()
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Cloud-based state refresh used when we're off-LAN. Much less detailed
    /// than the LAN path — no queue, no raw transport URI, no per-speaker
    /// volume — but enough to populate the mini-player and now-playing UI.
    private func refreshStateCloud() async {
        guard let gid = cloudGroupId,
              let token = await SonosAuth.shared.validAccessToken() else {
            connectionState = .disconnected
            return
        }
        do {
            // Concurrent requests: playback status (transport + modes +
            // position), metadata (track name / artist / art), and group
            // volume for the full player / widget shared cache.
            async let statusCall = SonosCloudAPI.getPlaybackStatus(token: token, groupId: gid)
            async let metaCall = SonosCloudAPI.getPlaybackMetadata(token: token, groupId: gid)
            async let volumeCall = SonosCloudAPI.getGroupVolume(token: token, groupId: gid)
            let status = try await statusCall
            let meta = try await metaCall
            let groupVolume = try? await volumeCall

            applyIncomingTransportState(
                Self.transportState(fromCloudPlaybackState: status.playbackState))

            if Date() > playModeLockUntil,
               let modes = status.playModes {
                isShuffling = modes.shuffle ?? false
                repeatMode = Self.repeatMode(fromCloud: modes.repeatMode, one: modes.repeatOne)
            }

            let track = meta.currentItem?.track
            let durationSec: TimeInterval = (track?.durationMillis).map { TimeInterval($0) / 1000.0 } ?? 0
            let positionSec: TimeInterval = (status.positionMillis).map { TimeInterval($0) / 1000.0 } ?? 0

            let previousTrackInfo = trackInfo
            var info = previousTrackInfo ?? TrackInfo(title: "", artist: "", album: "")
            info.title = track?.name ?? info.title
            info.artist = track?.artist?.name ?? info.artist
            info.album = track?.album?.name ?? info.album
            // Album art falls through several Sonos Cloud JSON paths —
            // `track.imageUrl` is most common, but album-art-only streams
            // (radio stations, playlist headers, line-in) route art up to
            // `container.imageUrl`, and some services shove it onto
            // `album.imageUrl`. In cloud mode we also filter out LAN
            // URLs (Sonos loves to return `http://192.168.x.x:1400/getaa`
            // for `track.imageUrl`, which can't be loaded off-LAN), so
            // the CDN-backed fallbacks actually win. Honor the previous
            // value if every path above is nil, so we don't blank an
            // art we already loaded.
            let artURL = Self.pickPublicArtURL(
                track?.imageUrl,
                track?.album?.imageUrl,
                meta.container?.imageUrl)
            info.albumArtURL = AlbumArtURLCarryoverPolicy.albumArtURL(
                incomingURL: artURL,
                previousTrackInfo: previousTrackInfo,
                incomingTrackInfo: info
            )
            info.duration = SonosTime.apiFormat(durationSec)
            info.position = SonosTime.apiFormat(positionSec)
            // Tag the playback source so the now-playing badge renders.
            // Cloud `playbackMetadata` ships the service name directly;
            // fall back to the container name for line-in / radio /
            // service-less cases.
            let sourceHint = track?.service?.name ?? meta.container?.name
            info.source = PlaybackSource.from(serviceName: sourceHint)
            if let q = track?.quality, let mapped = AudioQuality.from(cloudQuality: q) {
                info.audioQuality = mapped
            }
            trackInfo = info

            positionSeconds = positionSec
            durationSeconds = durationSec
            if let groupVolume = groupVolume?.volume {
                volume = groupVolume
                if let idx = currentGroupStatusIndex() {
                    groupStatuses[idx].volume = groupVolume
                }
            }
            positionFetchedAt = Date()
            syncCurrentGroupStatusFromPlaybackState()

            consecutiveFailures = 0
            connectionState = .connected
            errorMessage = nil

            updateSharedCache()
            await loadAlbumArt()
            MusicAmbienceManager.shared.receive(snapshot: musicAmbienceSnapshot())
            managePositionTimer()
            manageLiveActivity()
        } catch SonosCloudError.unauthorized {
            _ = await SonosAuth.shared.refreshAccessToken()
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= Self.maxConsecutiveRefreshFailures {
                connectionState = .disconnected
                errorMessage = "Remote control unavailable — check your connection."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func transportState(fromCloudPlaybackState raw: String?) -> TransportState {
        switch raw {
        case "PLAYBACK_STATE_PLAYING":   return .playing
        case "PLAYBACK_STATE_PAUSED":    return .paused
        case "PLAYBACK_STATE_BUFFERING": return .transitioning
        case "PLAYBACK_STATE_IDLE":      return .stopped
        default:                         return .stopped
        }
    }

    private static func repeatMode(fromCloud raw: String?, one: Bool?) -> RepeatMode {
        if one == true { return .one }
        switch raw {
        case "REPEAT_ALL", "ALL":  return .all
        case "REPEAT_ONE", "ONE":  return .one
        default:                   return .off
        }
    }


    // MARK: - Transport Backend Probe

    /// Decide whether we can reach the speaker over LAN or need to fall back
    /// to the Sonos Cloud Control API. The TCP probe is short (1 s) so the
    /// UI rarely blocks on it — subsequent commands just consult the cached
    /// `transportBackend` value. Concurrent callers share the in-flight
    /// `probeTask`, so e.g. "app foreground + speaker tap" only does one
    /// probe.
    @discardableResult
    func probeBackend() async -> TransportBackend {
        if let task = probeTask { return await task.value }

        let task = Task<TransportBackend, Never> { [weak self] in
            guard let self else { return .unknown }
            let result = await self.runBackendProbe()
            await MainActor.run {
                self.transportBackend = result
                if result != .lan {
                    self.stopEventSubscriptions()
                }
                SonosLog.info(.sonosCloud, "transport backend → \(result)")
            }
            return result
        }
        probeTask = task
        defer { probeTask = nil }
        return await task.value
    }

    /// Marks the current backend stale and kicks off a re-probe on the next
    /// call. Useful when a LAN command unexpectedly times out mid-session —
    /// the next UI action will silently re-route to cloud.
    func invalidateBackend() {
        transportBackend = .unknown
        probeTask = nil
        stopEventSubscriptions()
    }

    /// Pure probe logic; always returns the decision without touching state.
    private func runBackendProbe() async -> TransportBackend {
        guard let ip = playbackIP else { return .unknown }

        // Try a 1s TCP connect to the speaker's control port. Anything that
        // answers the TCP handshake is "LAN reachable" for our purposes —
        // we don't need to verify UPnP semantics here, the next real SOAP
        // call will surface a problem if the speaker's in a weird state.
        let lanReachable = await Self.tcpProbe(host: ip, port: 1400, timeout: 1.0)
        if lanReachable { return .lan }

        // LAN unreachable. Only hard requirement for routing to `.cloud` is
        // a valid OAuth token — if Sonos Cloud auth works, the actual
        // `cloudGroupId` / `householdId` can resolve lazily inside the
        // refresh code path. Previously this branch blocked on
        // `resolveCloudGroupId()` succeeding first, which meant a single
        // flaky `getGroups` response kept us stuck in `.unknown` and the
        // Home tab's spinner spun forever. Kick off the resolve in the
        // background (we'll need the id for control commands soon anyway)
        // but don't wait on it.
        guard await SonosAuth.shared.validAccessToken() != nil else {
            return .unknown
        }
        if cloudGroupId == nil {
            Task { await resolveCloudGroupId() }
        }
        return .cloud
    }

    /// Lightweight TCP reachability probe. Wrapping `NWConnection` in
    /// `withCheckedContinuation` keeps the caller on async/await. We use
    /// `.tcp` directly so the probe works even when the speaker isn't
    /// advertising via Bonjour at the moment.
    private static func tcpProbe(host: String, port: UInt16,
                                 timeout: TimeInterval) async -> Bool {
        let queue = DispatchQueue.global(qos: .userInitiated)
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
        // Use a class-based box so the timeout timer and state handler can
        // race to resume the continuation safely — first one to win sets
        // `done` under the lock and resumes; the loser is a no-op.
        final class ResumeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func tryComplete() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let box = ResumeBox()

        return await withCheckedContinuation { continuation in
            queue.asyncAfter(deadline: .now() + timeout) {
                if box.tryComplete() {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if box.tryComplete() {
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if box.tryComplete() {
                        continuation.resume(returning: false)
                    }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Package the current routing decision into a `SonosControl.Backend`
    /// the verb dispatcher can use. Returns nil when we have nothing usable
    /// (no speaker / failed probe / no cloud auth). Callers then surface
    /// `SonosControlError.noBackend` to the user.
    func currentControlBackend() -> SonosControl.Backend? {
        switch transportBackend {
        case .lan:
            guard let ip = playbackIP,
                  let vIP = volumeIP,
                  let uuid = selectedSpeaker?.id else { return nil }
            return .lan(ip: ip, volumeIP: vIP, speakerUUID: uuid)
        case .cloud:
            guard let gid = cloudGroupId,
                  let token = SonosAuth.shared.cachedAccessToken,
                  let hid = SonosAuth.shared.householdId else { return nil }
            return .cloud(groupId: gid, token: token,
                          householdId: hid, playerId: cloudPlayerId)
        case .unknown:
            return nil
        }
    }

    /// Like `currentControlBackend` but probes first if we haven't already.
    /// Use from async command entry points where an extra 1 s latency on
    /// the first tap is acceptable; hot paths should cache.
    func controlBackendEnsured() async -> SonosControl.Backend? {
        if transportBackend == .unknown { _ = await probeBackend() }
        return currentControlBackend()
    }

    // MARK: - Sonos Cloud API

    /// Resolve the cloud group ID by matching the selected speaker's RINCON UUID to cloud players.
    func resolveCloudGroupId() async {
        guard let speaker = selectedSpeaker,
              let token = await SonosAuth.shared.validAccessToken() else {
            return
        }

        do {
            if SonosAuth.shared.householdId == nil {
                let households = try await SonosCloudAPI.getHouseholds(token: token)
                SonosAuth.shared.householdId = households.first?.id
            }
            guard let householdId = SonosAuth.shared.householdId else {
                SonosLog.error(.sonosCloud, "no householdId")
                return
            }

            let response = try await SonosCloudAPI.getGroups(token: token, householdId: householdId)
            let rincon = speaker.id

            cloudGroupId = response.groups.first(where: { group in
                group.playerIds.contains(where: { $0.contains(rincon) || rincon.contains($0) })
            })?.id

            if cloudGroupId == nil {
                cloudGroupId = response.groups.first(where: { group in
                    response.players.filter { group.playerIds.contains($0.id) }
                        .contains(where: { $0.name == speaker.name })
                })?.id
            }

            // RINCON id is a substring of the cloud player id — needed
            // for per-player volume over the Cloud Control API.
            cloudPlayerId = response.players.first { p in
                p.id.contains(rincon) || rincon.contains(p.id) || p.name == speaker.name
            }?.id

            if let gid = cloudGroupId {
                SharedStorage.cloudGroupId = gid
            } else {
                SonosLog.error(.sonosCloud, "Could not match speaker \(speaker.name) (id: \(rincon)) to any cloud group")
            }
        } catch SonosCloudError.unauthorized {
            SonosLog.info(.sonosCloud, "unauthorized, refreshing token...")
            _ = await SonosAuth.shared.refreshAccessToken()
        } catch {
            SonosLog.error(.sonosCloud, "resolveCloudGroupId error: \(error)")
        }
    }

    nonisolated static func cloudQualityTrackKey(for trackInfo: TrackInfo?) -> String? {
        guard let trackInfo else { return nil }
        let title = trackInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artist = trackInfo.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let artURL = trackInfo.albumArtURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(title)|\(artist)|\(artURL)"
    }

    nonisolated static func reconciledLANTrackInfo(
        _ incoming: TrackInfo,
        cachedCloudQuality: (trackKey: String, quality: AudioQuality)?,
        cloudQualityIsAuthoritative: Bool
    ) -> TrackInfo {
        var info = incoming

        // Local UPnP metadata is allowed to be the first source of truth for
        // badges: if DIDL/res/protocolInfo confirms FLAC/ALAC/Hi-Res, publish
        // it immediately. Cloud can still enhance a nil/ambiguous streaming
        // track later, but it should not be required before a badge appears.
        if case nil = info.audioQuality,
           let cachedCloudQuality,
           cachedCloudQuality.trackKey == cloudQualityTrackKey(for: info) {
            info.audioQuality = cachedCloudQuality.quality
        }

        return info
    }

    nonisolated static func trackInfo(
        _ incoming: TrackInfo,
        applyingPlaybackMetadata metadata: SonosCloudAPI.CloudPlaybackMetadata
    ) -> TrackInfo {
        var info = incoming
        guard let track = metadata.currentItem?.track else { return info }

        if let name = nonEmpty(track.name) {
            info.title = name
        }
        if let artist = nonEmpty(track.artist?.name) {
            info.artist = artist
        }
        if let album = nonEmpty(track.album?.name) {
            info.album = album
        }
        if let imageURL = nonEmpty(track.imageUrl ?? track.album?.imageUrl ?? metadata.container?.imageUrl) {
            info.albumArtURL = imageURL
        }
        if let durationMillis = track.durationMillis, durationMillis > 0 {
            info.duration = SonosTime.apiFormat(TimeInterval(durationMillis) / 1000.0)
        }

        let sourceHint = track.service?.name ?? metadata.container?.name
        let source = PlaybackSource.from(serviceName: sourceHint)
        if source != .unknown {
            info.source = source
        }
        if let quality = track.quality,
           let mapped = AudioQuality.from(cloudQuality: quality) {
            info.audioQuality = mapped
        }
        return info
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func fetchLocalControlPlaybackMetadata(ip: String) async -> SonosCloudAPI.CloudPlaybackMetadata? {
        guard let playerId = localControlPlayerId(forPlaybackIP: ip) else {
            logAudioQualityDiagnostic(action: "local-control-skip", extra: ["reason=missing-player-id"])
            return nil
        }

        if let groupId = localControlGroupIdsByPlayerId[playerId] {
            do {
                let metadata = try await SonosLocalControlAPI.getPlaybackMetadata(ip: ip, groupId: groupId)
                logLocalControlMetadata(metadata, groupId: groupId, playerId: playerId)
                return metadata
            } catch {
                localControlGroupIdsByPlayerId[playerId] = nil
                logAudioQualityDiagnostic(action: "local-control-refresh-group", extra: [
                    "playerId=\(Self.liveActivityLogValue(playerId))",
                    "reason=\(Self.liveActivityLogValue(error.localizedDescription))"
                ])
            }
        }

        do {
            let info = try await SonosLocalControlAPI.playerInfo(ip: ip, playerId: playerId)
            guard let groupId = info.groupId, !groupId.isEmpty else {
                logAudioQualityDiagnostic(action: "local-control-skip", extra: [
                    "reason=missing-group-id",
                    "playerId=\(Self.liveActivityLogValue(playerId))"
                ])
                return nil
            }
            localControlGroupIdsByPlayerId[playerId] = groupId
            let metadata = try await SonosLocalControlAPI.getPlaybackMetadata(ip: ip, groupId: groupId)
            logLocalControlMetadata(metadata, groupId: groupId, playerId: playerId)
            return metadata
        } catch {
            logAudioQualityDiagnostic(action: "local-control-failed", extra: [
                "playerId=\(Self.liveActivityLogValue(playerId))",
                "reason=\(Self.liveActivityLogValue(error.localizedDescription))"
            ])
            return nil
        }
    }

    private func localControlPlayerId(forPlaybackIP ip: String) -> String? {
        if let coordinator = allSpeakers.first(where: { $0.ipAddress == ip && $0.isCoordinator }) {
            return coordinator.id
        }
        if let selected = selectedSpeaker {
            if selected.ipAddress == ip {
                return selected.id
            }
            if let groupId = selected.groupId,
               let coordinator = allSpeakers.first(where: { $0.groupId == groupId && $0.isCoordinator }) {
                return coordinator.id
            }
        }
        return selectedSpeaker?.id
    }

    private func cacheAudioQualityIfPresent(_ quality: AudioQuality?, for info: TrackInfo) {
        guard let quality, let trackKey = Self.cloudQualityTrackKey(for: info) else { return }
        cachedCloudQuality = (trackKey: trackKey, quality: quality)
    }

    private func logLocalControlMetadata(
        _ metadata: SonosCloudAPI.CloudPlaybackMetadata,
        groupId: String,
        playerId: String
    ) {
        let quality = metadata.currentItem?.track?.quality
        logAudioQualityDiagnostic(action: "local-control-metadata", extra: [
            "groupId=\(Self.liveActivityLogValue(groupId))",
            "playerId=\(Self.liveActivityLogValue(playerId))",
            "service=\(Self.liveActivityLogValue(metadata.currentItem?.track?.service?.name ?? "nil"))",
            "rawLossless=\(quality?.lossless.map { String($0) } ?? "nil")",
            "rawImmersive=\(quality?.immersive.map { String($0) } ?? "nil")",
            "rawBitDepth=\(quality?.bitDepth.map { String($0) } ?? "nil")",
            "rawSampleRate=\(quality?.sampleRate.map { String($0) } ?? "nil")"
        ])
    }

    /// Whether Sonos Cloud's `playbackMetadata.quality` is trustworthy for a
    /// given playback source. First-party streaming services (Sonos-owned
    /// ingest pipeline) plus NetEase Cloud Music — verified to populate
    /// `quality` via Sonos Cloud — all qualify. Local library / radio /
    /// AirPlay / Line-In have no cloud representation so UPnP stays the
    /// only signal there.
    private func isCloudQualityAuthoritative(_ source: PlaybackSource?) -> Bool {
        switch source {
        case .spotify, .appleMusic, .amazonMusic, .tidal, .youtubeMusic, .neteaseMusic:
            return true
        default:
            return false
        }
    }

    /// Pull authoritative audio-quality info from the Sonos Cloud API.
    /// With `isCloudQualityAuthoritative(...)` wiping UPnP up-front for
    /// first-party streaming services, this is effectively the *only* path
    /// that sets `audioQuality` for Apple Music / Spotify / etc. — making
    /// Cloud the single source of truth as long as the user is logged in.
    private func enrichAudioQualityFromCloud() async {
        let trackKey = Self.cloudQualityTrackKey(for: trackInfo)
        let loggedIn = SonosAuth.shared.isLoggedIn

        let needsEnrich: Bool = {
            // Logged in → Sonos Cloud is authoritative. Always refresh once
            // per track change (throttled below by the same-track cooldown)
            // so we catch Dolby Atmos, lossless flags, etc. that UPnP
            // systematically mis-labels.
            if loggedIn { return true }

            guard let quality = trackInfo?.audioQuality else { return true }
            let codec = quality.codec.lowercased()
            return codec == "mp3" || codec == "mpeg" || codec == "aac"
                || codec.contains("octet-stream")
        }()

        logAudioQualityDiagnostic(action: "cloud-enrich-check", extra: [
            "needs=\(needsEnrich)",
            "isEnriching=\(isEnrichingQuality)",
            "transport=\(transportState)",
            "loggedIn=\(loggedIn)",
            "trackKey=\(Self.liveActivityLogValue(trackKey ?? "nil"))",
            "currentQuality=\(Self.liveActivityLogValue(trackInfo?.audioQuality?.label ?? "nil"))",
            "source=\(trackInfo?.source.rawValue ?? "nil")"
        ])

        guard needsEnrich else {
            logAudioQualityDiagnostic(action: "cloud-enrich-skip", extra: ["reason=not-needed"])
            return
        }
        guard !isEnrichingQuality else {
            logAudioQualityDiagnostic(action: "cloud-enrich-skip", extra: ["reason=in-flight"])
            return
        }
        guard transportState == .playing else {
            logAudioQualityDiagnostic(action: "cloud-enrich-skip", extra: [
                "reason=not-playing",
                "transport=\(transportState)"
            ])
            return
        }
        guard loggedIn else {
            logAudioQualityDiagnostic(action: "cloud-enrich-skip", extra: ["reason=not-logged-in"])
            return
        }

        // New track → fetch immediately; same track → respect cooldown
        if trackKey == lastEnrichedTrackKey {
            let age = Date().timeIntervalSince(lastCloudQualityAttempt)
            guard age > Self.cloudQualityRefreshCooldown else {
                logAudioQualityDiagnostic(action: "cloud-enrich-skip", extra: [
                    "reason=cooldown",
                    "age=\(String(format: "%.1f", age))"
                ])
                return
            }
        }

        isEnrichingQuality = true
        defer { isEnrichingQuality = false }
        lastCloudQualityAttempt = Date()

        if cloudGroupId == nil {
            await resolveCloudGroupId()
        }
        guard let groupId = cloudGroupId else {
            logAudioQualityDiagnostic(action: "cloud-enrich-skip", extra: ["reason=missing-cloud-group"])
            return
        }
        guard let token = await SonosAuth.shared.validAccessToken() else {
            logAudioQualityDiagnostic(action: "cloud-enrich-skip", extra: ["reason=missing-token"])
            return
        }

        do {
            let metadata = try await fetchPlaybackMetadata(token: token, groupId: groupId)
            if let quality = metadata.currentItem?.track?.quality,
               let mapped = AudioQuality.from(cloudQuality: quality) {
                trackInfo?.audioQuality = mapped
                if let trackKey = Self.cloudQualityTrackKey(for: trackInfo) {
                    cachedCloudQuality = (trackKey: trackKey, quality: mapped)
                }
                logAudioQualityDiagnostic(action: "cloud-enrich-success", extra: [
                    "groupId=\(Self.liveActivityLogValue(groupId))",
                    "rawCodec=\(Self.liveActivityLogValue(quality.codec ?? "nil"))",
                    "rawLossless=\(quality.lossless.map { String($0) } ?? "nil")",
                    "rawImmersive=\(quality.immersive.map { String($0) } ?? "nil")",
                    "rawBitDepth=\(quality.bitDepth.map { String($0) } ?? "nil")",
                    "rawSampleRate=\(quality.sampleRate.map { String($0) } ?? "nil")",
                    "mapped=\(Self.liveActivityLogValue(mapped.label))"
                ])
            } else {
                let quality = metadata.currentItem?.track?.quality
                logAudioQualityDiagnostic(action: "cloud-enrich-no-quality", extra: [
                    "groupId=\(Self.liveActivityLogValue(groupId))",
                    "hasTrack=\(metadata.currentItem?.track != nil)",
                    "hasQuality=\(quality != nil)",
                    "rawCodec=\(Self.liveActivityLogValue(quality?.codec ?? "nil"))",
                    "rawLossless=\(quality?.lossless.map { String($0) } ?? "nil")",
                    "rawImmersive=\(quality?.immersive.map { String($0) } ?? "nil")"
                ])
            }
            lastEnrichedTrackKey = trackKey
        } catch SonosCloudError.unauthorized {
            logAudioQualityDiagnostic(action: "cloud-enrich-failed", extra: ["reason=unauthorized"])
            _ = await SonosAuth.shared.refreshAccessToken()
        } catch {
            lastEnrichedTrackKey = trackKey
            SonosLog.error(.sonosCloud, "playbackMetadata error: \(error)")
            logAudioQualityDiagnostic(action: "cloud-enrich-failed", extra: [
                "reason=\(Self.liveActivityLogValue(error.localizedDescription))"
            ])
        }
    }

    private func fetchPlaybackMetadata(token: String, groupId: String) async throws -> SonosCloudAPI.CloudPlaybackMetadata {
        do {
            return try await SonosCloudAPI.getPlaybackMetadata(token: token, groupId: groupId)
        } catch SonosCloudError.httpError(410) {
            SonosLog.info(.sonosCloud, "playbackMetadata 410 — re-resolving cloudGroupId…")
            cloudGroupId = nil
            await resolveCloudGroupId()
            guard let newGroupId = cloudGroupId else { throw SonosCloudError.groupNotFound }
            return try await SonosCloudAPI.getPlaybackMetadata(token: token, groupId: newGroupId)
        }
    }

    private var groupRefreshCounter = 0

    static func autoRefreshPlan(
        transportBackend: TransportBackend,
        hasLANEventSubscriptions: Bool,
        cycle: Int
    ) -> AutoRefreshPlan {
        if transportBackend == .lan && hasLANEventSubscriptions {
            return AutoRefreshPlan(
                refreshState: true,
                refreshGroups: true,
                sleepSeconds: lanEventWatchdogRefreshIntervalSeconds
            )
        }

        let refreshGroups = !cycle.isMultiple(of: 2)
        let refreshState = transportBackend != .cloud || cycle.isMultiple(of: 2)
        return AutoRefreshPlan(
            refreshState: refreshState,
            refreshGroups: refreshGroups,
            sleepSeconds: fastRefreshIntervalSeconds
        )
    }

    private var hasActiveLANEventSubscriptions: Bool {
        transportBackend == .lan
            && eventSubscriptions.subscription(for: .avTransport) != nil
    }

    func startAutoRefresh() {
        stopAutoRefresh()

        groupRefreshCounter = 0
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let plan = Self.autoRefreshPlan(
                    transportBackend: self.transportBackend,
                    hasLANEventSubscriptions: self.hasActiveLANEventSubscriptions,
                    cycle: self.groupRefreshCounter
                )
                if plan.refreshState {
                    await self.refreshState()
                }
                if plan.refreshGroups {
                    await self.refreshAllGroupStatuses()
                }
                self.groupRefreshCounter += 1
                try? await Task.sleep(for: .seconds(plan.sleepSeconds))
            }
        }

        // Start background keepalive when app goes to background (while Live Activity is running).
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.startBackgroundKeepalive() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopBackgroundKeepalive()
                // LAN reachability may have flipped while we were in the
                // background (user left home / came back). Invalidate the
                // cached backend so the next command re-probes.
                self?.invalidateBackend()
                _ = await self?.probeBackend()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        positionTask?.cancel()
        positionTask = nil
        stopEventSubscriptions()
        stopBackgroundKeepalive()
        NotificationCenter.default.removeObserver(self,
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self,
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - Background Keepalive for Live Activity

    /// When music is playing and the app moves to background, iOS suspends our Timer.
    /// This grabs ~30s of background execution time and polls every 5s so the Live
    /// Activity (track title, progress timestamps) stays fresh through track changes.
    @MainActor
    private func startBackgroundKeepalive() {
        guard currentActivity != nil else { return }
        stopBackgroundKeepalive()

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SonosLiveActivity") { [weak self] in
            self?.stopBackgroundKeepalive()
        }

        backgroundKeepaliveTask = Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { break }
                await self.refreshState()
            }
            await MainActor.run { self?.stopBackgroundKeepalive() }
        }
    }

    @MainActor
    private func stopBackgroundKeepalive() {
        backgroundKeepaliveTask?.cancel()
        backgroundKeepaliveTask = nil
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Sonos Event Subscriptions

    private func ensureEventSubscriptionsIfNeeded() {
        guard transportBackend == .lan, let ip = playbackIP else {
            stopEventSubscriptions()
            return
        }
        if eventSubscriptionIP == ip, eventSubscriptionTask != nil {
            return
        }

        eventSubscriptionTask?.cancel()
        eventSubscriptionTask = Task { @MainActor [weak self] in
            await self?.runEventSubscriptionLoop(ip: ip)
        }
    }

    @MainActor
    private func runEventSubscriptionLoop(ip: String) async {
        defer {
            if eventSubscriptionIP == ip {
                eventSubscriptionTask = nil
            }
        }

        do {
            let callbackURL = try eventCallbackURL()
            eventSubscriptionIP = ip
            eventSubscriptions.removeAll()

            while !Task.isCancelled, playbackIP == ip, transportBackend == .lan {
                await subscribeMissingEventServices(ip: ip, callbackURL: callbackURL)
                let delay = nextEventRenewalDelay()

                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }

                guard !Task.isCancelled, playbackIP == ip, transportBackend == .lan else { break }
                await renewEventSubscriptions(ip: ip)
            }
        } catch {
            eventSubscriptionIP = nil
            eventSubscriptions.removeAll()
            eventListener?.stop()
            eventListener = nil
            SonosLog.debug(.sonosEvents, "subscription listener unavailable: \(error)")
        }
    }

    @MainActor
    private func subscribeMissingEventServices(ip: String, callbackURL: URL) async {
        for service in Self.sonosEventServices where eventSubscriptions.subscription(for: service) == nil {
            do {
                let subscription = try await SonosEventSubscriptionClient.subscribe(
                    ip: ip,
                    service: service,
                    callbackURL: callbackURL,
                    timeoutSeconds: Self.sonosEventSubscriptionTimeout)
                guard playbackIP == ip, transportBackend == .lan else { return }
                eventSubscriptions.replace(subscription)
                SonosLog.info(.sonosEvents, "subscribed \(service) sid=\(subscription.sid)")
            } catch {
                SonosLog.debug(.sonosEvents, "subscribe \(service) failed: \(error)")
            }
        }
    }

    @MainActor
    private func renewEventSubscriptions(ip: String) async {
        for subscription in eventSubscriptions.subscriptions {
            do {
                let renewed = try await SonosEventSubscriptionClient.renew(
                    ip: ip,
                    existingSubscription: subscription,
                    timeoutSeconds: Self.sonosEventSubscriptionTimeout)
                guard playbackIP == ip, transportBackend == .lan else { return }
                eventSubscriptions.replace(renewed)
                SonosLog.debug(.sonosEvents, "renewed \(renewed.service) sid=\(renewed.sid)")
            } catch {
                eventSubscriptions.remove(sid: subscription.sid)
                SonosLog.debug(.sonosEvents, "renew \(subscription.service) failed: \(error)")
            }
        }
    }

    private func nextEventRenewalDelay() -> Int {
        let delays = eventSubscriptions.subscriptions.map(\.renewalDelaySeconds)
        return delays.min() ?? 60
    }

    private func eventCallbackURL() throws -> URL {
        if let callbackURL = eventListener?.callbackURL {
            return callbackURL
        }

        let listener = eventListener ?? SonosEventListener { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleSonosEvent(notification)
            }
        }
        let callbackURL = try listener.start()
        eventListener = listener
        return callbackURL
    }

    private func stopEventSubscriptions(unsubscribe: Bool = true) {
        eventSubscriptionTask?.cancel()
        eventSubscriptionTask = nil
        eventDrivenRefreshTask?.cancel()
        eventDrivenRefreshTask = nil

        let ip = eventSubscriptionIP
        let subscriptions = eventSubscriptions.subscriptions
        eventSubscriptionIP = nil
        eventSubscriptions.removeAll()
        eventListener?.stop()
        eventListener = nil

        guard unsubscribe, let ip else { return }
        Task {
            for subscription in subscriptions {
                try? await SonosEventSubscriptionClient.unsubscribe(ip: ip, subscription: subscription)
            }
        }
    }

    @MainActor
    private func handleSonosEvent(_ notification: SonosEventNotification) {
        guard let service = eventSubscriptions.service(for: notification) else {
            SonosLog.debug(.sonosEvents, "ignored notification for unknown sid=\(notification.sid)")
            return
        }

        SonosLog.debug(.sonosEvents, "notify \(service) seq=\(notification.sequence.map(String.init) ?? "?")")
        scheduleEventDrivenRefresh(for: service)
    }

    @MainActor
    private func scheduleEventDrivenRefresh(for service: SonosEventService) {
        eventDrivenRefreshTask?.cancel()
        eventDrivenRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.transportBackend == .lan else { return }

            switch service {
            case .zoneGroupTopology:
                await self.reloadTopology()
            case .contentDirectory:
                if self.queueLoaded {
                    await self.loadQueue()
                }
                await self.refreshStateLAN()
            case .avTransport, .renderingControl:
                await self.refreshStateLAN()
            }
        }
    }

    // MARK: - Position Timer

    private func managePositionTimer() {
        if isPlaying && durationSeconds > 0 {
            if positionTask == nil {
                positionTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        guard self.isPlaying, self.durationSeconds > 0 else {
                            self.positionTask = nil
                            return
                        }
                        self.positionSeconds = min(self.positionSeconds + 1, self.durationSeconds)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        } else {
            positionTask?.cancel()
            positionTask = nil
        }
    }

    // MARK: - Live Activity

    private func manageLiveActivity() {
        guard let speaker = selectedSpeaker else {
            logLiveActivity(action: "skip", reason: "no-selected-speaker")
            return
        }

        // Reattach to an existing activity if the in-memory reference was lost
        // after a process relaunch. We keep it alive and continue local
        // updates regardless of whether it was originally local or push-token.
        if currentActivity == nil {
            currentActivity = Activity<SonosActivityAttributes>.activities.first
            if let currentActivity {
                currentActivityUsesRelay = RelayManager.shared.isAvailable
                logLiveActivity(action: "reattach", activityID: currentActivity.id,
                                mode: currentActivityUsesRelay ? "relay-token" : "local")
            }
        }

        let now = Date()
        let shouldKeep = Self.shouldKeepLiveActivity(
            isPlaying: isPlaying,
            transportState: transportState,
            currentActivityExists: currentActivity != nil,
            playStateLockUntil: SharedStorage.playStateLockUntil,
            now: now
        )
        guard shouldKeep else {
            logLiveActivity(action: "stop-request",
                            mode: currentActivityUsesRelay ? "relay-token" : "local",
                            reason: "not-playing")
            stopLiveActivity()
            return
        }

        let useRelay = RelayManager.shared.isAvailable

        if currentActivity == nil {
            // No existing activity — create one (always, even during TRANSITIONING).
            let state = makeActivityState()
            let attrs = SonosActivityAttributes(speakerName: speaker.name)
            // `staleDate` is refreshed on every `update()` below so an alive
            // app keeps the activity fresh indefinitely. If all writers stop,
            // iOS can age the activity out without us actively killing it.
            let content = ActivityContent(state: state, staleDate: Self.liveActivityStaleDate())

            // First try the user's preferred mode. If that's `.token` (relay
            // looks reachable) but the app doesn't actually have an
            // `aps-environment` entitlement — i.e. no Apple Developer account
            // / push capability is set up yet — `Activity.request` will throw.
            // Fall back to local-update mode unconditionally so the Lock
            // Screen still shows *something*. The user gets a working Live
            // Activity right now, and once they enrol + sign with the right
            // entitlement the same code path automatically upgrades to push.
            if useRelay {
                do {
                    let activity = try Activity.request(
                        attributes: attrs,
                        content: content,
                        pushType: .token
                    )
                    currentActivity = activity
                    currentActivityUsesRelay = true
                    liveActivityRelayWriterReady = false
                    logLiveActivity(action: "create", activityID: activity.id, mode: "relay-token",
                                    state: state, extra: ["speaker=\(Self.liveActivityLogValue(speaker.name))"])
                    spawnPushTokenObserver(activity: activity, speakerName: speaker.name)
                    return
                } catch {
                    logLiveActivity(action: "create-failed", mode: "relay-token",
                                    reason: error.localizedDescription, state: state)
                    SonosLog.info(.station,
                        "Activity.request(.token) failed (\(error.localizedDescription)). " +
                        "Falling back to local-update Live Activity.")
                }
            }

            do {
                let activity = try Activity.request(
                    attributes: attrs,
                    content: content,
                    pushType: nil
                )
                currentActivity = activity
                currentActivityUsesRelay = false
                liveActivityRelayWriterReady = false
                SharedStorage.liveActivityRelayPushToken = nil
                logLiveActivity(action: "create", activityID: activity.id, mode: "local",
                                state: state, extra: ["speaker=\(Self.liveActivityLogValue(speaker.name))"])
            } catch {
                logLiveActivity(action: "create-failed", mode: "local",
                                reason: error.localizedDescription, state: state)
                SonosLog.error(.station,
                    "Activity.request failed: \(error.localizedDescription)")
                currentActivityUsesRelay = false
            }
            return
        }

        // During TRANSITIONING the Sonos device is buffering between tracks.
        // isPlaying == false here, so makeActivityState() would produce nil startedAt/endsAt,
        // causing the Live Activity to fall back to a frozen static progress bar.
        // Instead, skip the update entirely — the existing timerInterval keeps animating on its
        // own using the device clock. We'll push a fresh state once the new track is actually
        // playing (next refreshState cycle).
        guard transportState != .transitioning else {
            logLiveActivity(action: "skip-update", activityID: currentActivity?.id,
                            mode: currentActivityUsesRelay ? "relay-token" : "local",
                            reason: "transitioning")
            return
        }

        guard !Self.shouldSkipLiveActivityContentUpdateDuringPlayStateLock(
            isPlaying: isPlaying,
            transportState: transportState,
            playStateLockUntil: SharedStorage.playStateLockUntil,
            now: now
        ) else {
            logLiveActivity(action: "skip-update", activityID: currentActivity?.id,
                            mode: currentActivityUsesRelay ? "relay-token" : "local",
                            reason: "play-state-lock")
            return
        }

        guard Self.shouldPerformLocalLiveActivityUpdate(
            usesRelay: currentActivityUsesRelay,
            relayWriterReady: liveActivityRelayWriterReady
        ) else {
            logLiveActivity(action: "skip-update", activityID: currentActivity?.id,
                            mode: "relay-token",
                            reason: "nas-primary-writer",
                            token: lastRegisteredPushToken,
                            extra: ["localActivityUpdate=false"])
            return
        }

        let state = makeActivityState()
        let activity = currentActivity
        logLiveActivity(action: "update-request", activityID: activity?.id,
                        mode: currentActivityUsesRelay ? "relay-token" : "local",
                        state: state,
                        extra: ["localActivityUpdate=true"])
        Task {
            await activity?.update(
                .init(state: state, staleDate: Self.liveActivityStaleDate()))
        }
    }

    /// Roll the Live Activity's stale window forward 60 min on every refresh.
    /// This is passive ageing only; explicit `end()` calls are reserved for
    /// user-driven teardown or confirmed playback stop.
    nonisolated static func liveActivityStaleDate() -> Date {
        Date().addingTimeInterval(60 * 60)
    }

    nonisolated static func shouldPerformLocalLiveActivityUpdate(
        usesRelay: Bool,
        relayWriterReady: Bool
    ) -> Bool {
        !usesRelay || !relayWriterReady
    }

    nonisolated static func shouldSendSoundbarCommandThroughRelay(
        usesRelay: Bool,
        relayWriterReady: Bool
    ) -> Bool {
        usesRelay && relayWriterReady
    }

    nonisolated static func shouldKeepLiveActivity(
        isPlaying: Bool,
        transportState: TransportState,
        currentActivityExists: Bool,
        playStateLockUntil: Date,
        now: Date = Date()
    ) -> Bool {
        if isPlaying || transportState == .paused || transportState == .transitioning {
            return true
        }
        return currentActivityExists && now < playStateLockUntil
    }

    nonisolated static func shouldSkipLiveActivityContentUpdateDuringPlayStateLock(
        isPlaying: Bool,
        transportState: TransportState,
        playStateLockUntil: Date,
        now: Date = Date()
    ) -> Bool {
        !isPlaying && transportState == .stopped && now < playStateLockUntil
    }

    nonisolated static func shouldRecreateLiveActivityForSpeakerChange(
        currentActivityExists: Bool,
        previousGroupId: String?,
        nextGroupId: String?
    ) -> Bool {
        guard currentActivityExists,
              let previousGroupId,
              let nextGroupId else {
            return false
        }
        return previousGroupId != nextGroupId
    }

    func updateLiveActivityStyle(_ style: LiveActivityStyle) {
        SharedStorage.liveActivityStyle = style
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")

        let activities = Activity<SonosActivityAttributes>.activities
        logLiveActivity(action: "style-update-request",
                        extra: [
                            "style=\(style.rawValue)",
                            "activityCount=\(activities.count)"
                        ])
        pushLiveActivityRelayPreferencesIfNeeded(force: true)

        Task {
            for activity in activities {
                var state = activity.content.state
                state.liveActivityStyleRaw = style.rawValue
                await activity.update(
                    .init(state: state, staleDate: Self.liveActivityStaleDate()))
            }
        }
    }

    private func logLiveActivity(action: String,
                                 activityID: String? = nil,
                                 mode: String? = nil,
                                 reason: String? = nil,
                                 state: SonosActivityAttributes.ContentState? = nil,
                                 token: String? = nil,
                                 groupId: String? = nil,
                                 relayURL: URL? = nil,
                                 extra: [String] = []) {
        var parts = [
            "live_activity",
            "source=app",
            "action=\(action)",
            "relayStatus=\(liveActivityRelayStatusLogValue())"
        ]
        if let activityID {
            parts.append("activity=\(Self.shortLiveActivityIdentifier(activityID))")
        }
        if let mode {
            parts.append("mode=\(mode)")
        }
        if let reason {
            parts.append("reason=\(Self.liveActivityLogValue(reason))")
        }
        if let token {
            parts.append("token=\(Self.shortLiveActivityIdentifier(token))")
        }
        if let groupId {
            parts.append("groupId=\(Self.liveActivityLogValue(groupId))")
        }
        if let relayURL {
            parts.append("relayURL=\(Self.liveActivityLogValue(relayURL.absoluteString))")
        }
        if let state {
            parts.append(contentsOf: Self.liveActivityStateLogParts(state))
        }
        parts.append(contentsOf: extra)
        SonosLog.info(.station, parts.joined(separator: " "))
    }

    private func liveActivityRelayStatusLogValue() -> String {
        switch RelayManager.shared.status {
        case .disabled:
            return "disabled"
        case .probing:
            return "probing"
        case .connected(let groupCount):
            return "connected(\(groupCount))"
        case .unreachable:
            return "unreachable"
        }
    }

    private static func liveActivityStateLogParts(
        _ state: SonosActivityAttributes.ContentState
    ) -> [String] {
        [
            "track=\(liveActivityLogValue(state.trackTitle))",
            "artist=\(liveActivityLogValue(state.artist))",
            "playing=\(state.isPlaying)",
            "pos=\(Int(state.positionSeconds.rounded()))",
            "duration=\(Int(state.durationSeconds.rounded()))",
            "color=\(state.dominantColorHex ?? "nil")",
            "artBytes=\(state.albumArtThumbnail?.count ?? 0)",
            "members=\(state.groupMemberCount)",
            "sourceRaw=\(state.playbackSourceRaw ?? "nil")",
            "activityStyle=\(state.liveActivityStyleRaw ?? "nil")",
            "quality=\(state.audioQualityLabel ?? "nil")",
            "hasStartedAt=\(state.startedAt != nil)",
            "hasEndsAt=\(state.endsAt != nil)"
        ]
    }

    private static func liveActivityLogValue(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "'\(sanitized)'"
    }

    private static func shortLiveActivityIdentifier(_ value: String) -> String {
        guard value.count > 14 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }

    /// Drains `Activity.pushTokenUpdates` and POSTs each rotation to the
    /// relay so the NAS knows where to deliver Live Activity pushes for the
    /// current Sonos coordinator. Tokens roll over occasionally; we resend
    /// every time the sequence yields rather than caching aggressively.
    private func spawnPushTokenObserver(activity: Activity<SonosActivityAttributes>,
                                        speakerName: String) {
        pushTokenTask?.cancel()
        let groupId = liveActivityGroupId() ?? speakerName
        logLiveActivity(action: "push-token-observer-start", activityID: activity.id,
                        mode: "relay-token", groupId: groupId)
        pushTokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                guard let url = await RelayManager.shared.url else {
                    await MainActor.run {
                        self?.liveActivityRelayWriterReady = false
                        self?.logLiveActivity(action: "register-token-skip", activityID: activity.id,
                                              mode: "relay-token", reason: "missing-relay-url",
                                              token: hex, groupId: groupId)
                    }
                    continue
                }
                await MainActor.run {
                    self?.liveActivityRelayWriterReady = false
                    self?.logLiveActivity(action: "push-token-yield", activityID: activity.id,
                                          mode: "relay-token", token: hex,
                                          groupId: groupId, relayURL: url)
                }
                do {
                    try await RelayClient.registerActivity(
                        baseURL: url,
                        groupId: groupId,
                        token: hex,
                        clientId: SharedStorage.liveActivityRelayClientID,
                        activityId: activity.id,
                        speakerName: speakerName,
                        liveActivityStyleRaw: SharedStorage.liveActivityStyle.rawValue
                    )
                    await MainActor.run {
                        self?.lastRegisteredPushToken = hex
                        SharedStorage.liveActivityRelayPushToken = hex
                        self?.liveActivityRelayWriterReady = true
                        self?.logLiveActivity(action: "register-token-success",
                                              activityID: activity.id,
                                              mode: "relay-token", token: hex,
                                              groupId: groupId, relayURL: url)
                    }
                } catch {
                    await MainActor.run {
                        self?.liveActivityRelayWriterReady = false
                        self?.logLiveActivity(action: "register-token-failed",
                                              activityID: activity.id,
                                              mode: "relay-token",
                                              reason: error.localizedDescription,
                                              token: hex, groupId: groupId,
                                              relayURL: url)
                    }
                    SonosLog.info(.station, "relay register failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stable cross-process identifier for "this group of speakers". Matches
    /// what the relay's `SonosBridge` keys snapshots on (`device.Host`), so
    /// the relay can find the right token list when an event lands.
    private func liveActivityGroupId() -> String? {
        selectedSpeaker?.playbackIP
    }

    private func sendRelaySoundbarNightModeCommand(
        _ enabled: Bool,
        fallbackGroupId: String
    ) async -> RelayClient.RelayPlaybackState? {
        await sendRelayLiveActivityCommand(
            "setSoundbarNightMode",
            fallbackGroupId: fallbackGroupId,
            nightMode: enabled
        )
    }

    private func sendRelaySoundbarSpeechEnhancementCommand(
        _ level: SpeechEnhancementLevel,
        fallbackGroupId: String
    ) async -> RelayClient.RelayPlaybackState? {
        await sendRelayLiveActivityCommand(
            "setSoundbarSpeechEnhancement",
            fallbackGroupId: fallbackGroupId,
            speechEnhancementRawLevel: level.rawValue
        )
    }

    private func sendRelayLiveActivityCommand(
        _ command: String,
        fallbackGroupId: String,
        nightMode: Bool? = nil,
        speechEnhancementRawLevel: Int? = nil
    ) async -> RelayClient.RelayPlaybackState? {
        guard let route = RelayClient.liveActivityCommandRoute(
            relayURLString: SharedStorage.relayURLString,
            relayPushToken: SharedStorage.liveActivityRelayPushToken,
            coordinatorIP: liveActivityGroupId(),
            fallbackGroupId: fallbackGroupId
        ) else {
            return nil
        }

        return try? await RelayClient.sendLiveActivityCommand(
            baseURL: route.baseURL,
            groupId: route.groupId,
            token: route.token,
            command: command,
            nightMode: nightMode,
            speechEnhancementRawLevel: speechEnhancementRawLevel
        )
    }

    private func applyRelaySoundbarState(_ state: RelayClient.RelayPlaybackState) {
        if let night = state.soundbarNightMode {
            nightMode = night
            SharedStorage.cachedSoundbarNightMode = night
        }
        if let rawLevel = state.soundbarSpeechEnhancementRawLevel {
            let level = SpeechEnhancementLevel.from(rawLevel: rawLevel)
            speechEnhancement = level
            SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = level.rawValue
        }
        if let label = state.audioQualityLabel {
            SharedStorage.cachedAudioQualityLabel = label
        }
        soundbarEQLockUntil = .distantPast
    }

    private func pushLiveActivityRelayPreferencesIfNeeded(force: Bool = false) {
        guard RelayManager.shared.isAvailable else {
            logLiveActivity(action: "preferences-skip",
                            mode: "relay-token",
                            reason: "relay-unavailable",
                            extra: [
                                "force=\(force)"
                            ])
            return
        }
        guard let url = RelayManager.shared.url else {
            logLiveActivity(action: "preferences-skip",
                            mode: "relay-token",
                            reason: "missing-relay-url",
                            extra: [
                                "force=\(force)"
                            ])
            return
        }
        guard let groupId = liveActivityGroupId() else {
            logLiveActivity(action: "preferences-skip",
                            mode: "relay-token",
                            reason: "missing-group-id",
                            relayURL: url,
                            extra: [
                                "force=\(force)"
                            ])
            return
        }

        let body = RelayClient.LiveActivityPreferencesBody(
            groupId: groupId,
            liveActivityStyleRaw: SharedStorage.liveActivityStyle.rawValue
        )
        let signature = [
            body.groupId,
            body.liveActivityStyleRaw ?? ""
        ].joined(separator: "\u{1F}")

        guard force || signature != lastLiveActivityRelayPreferencesSignature else {
            logLiveActivity(action: "preferences-skip",
                            mode: "relay-token",
                            reason: "duplicate-signature",
                            groupId: groupId,
                            relayURL: url,
                            extra: [
                                "style=\(body.liveActivityStyleRaw ?? "nil")"
                            ])
            return
        }
        lastLiveActivityRelayPreferencesSignature = signature

        logLiveActivity(action: "preferences-post-request",
                        mode: "relay-token",
                        groupId: groupId,
                        relayURL: url,
                        extra: [
                            "force=\(force)",
                            "style=\(body.liveActivityStyleRaw ?? "nil")"
                        ])

        Task { [weak self] in
            do {
                try await RelayClient.postLiveActivityPreferences(baseURL: url, body: body)
                await MainActor.run {
                    self?.logLiveActivity(action: "preferences-post-success",
                                          mode: "relay-token",
                                          groupId: groupId,
                                          relayURL: url,
                                          extra: [
                                            "style=\(body.liveActivityStyleRaw ?? "nil")"
                                          ])
                }
            } catch {
                await MainActor.run {
                    if self?.lastLiveActivityRelayPreferencesSignature == signature {
                        self?.lastLiveActivityRelayPreferencesSignature = nil
                    }
                    self?.logLiveActivity(action: "preferences-post-failed",
                                          mode: "relay-token",
                                          reason: error.localizedDescription,
                                          groupId: groupId,
                                          relayURL: url)
                }
            }
        }
    }

    func stopLiveActivity() {
        // Only explicit user teardown or confirmed playback stop should call
        // this. Mode changes and relay availability changes must keep the
        // existing Activity alive and update it in place.
        guard let activity = currentActivity else { return }
        currentActivity = nil
        currentActivityUsesRelay = false
        liveActivityRelayWriterReady = false
        lastLiveActivityRelayPreferencesSignature = nil
        pushTokenTask?.cancel()
        pushTokenTask = nil
        let tokenToUnregister = lastRegisteredPushToken
        lastRegisteredPushToken = nil
        SharedStorage.liveActivityRelayPushToken = nil
        logLiveActivity(action: "end", activityID: activity.id,
                        mode: "local-or-relay", token: tokenToUnregister)
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        if let token = tokenToUnregister, let url = RelayManager.shared.url {
            logLiveActivity(action: "unregister-token-request", activityID: activity.id,
                            token: token, relayURL: url)
            Task { try? await RelayClient.unregisterActivity(baseURL: url, token: token) }
        }
    }

    private func makeActivityState() -> SonosActivityAttributes.ContentState {
        // Anchor the timerInterval to the moment the Sonos position was actually fetched,
        // not to Date() which is slightly later. This prevents small jitter on each update.
        let anchor = positionFetchedAt
        let source = trackInfo?.source
        let isTVSource = source == .tv
        let startedAt = isPlaying && durationSeconds > 0
            ? anchor.addingTimeInterval(-positionSeconds) : nil
        let endsAt = isPlaying && durationSeconds > 0
            ? anchor.addingTimeInterval(durationSeconds - positionSeconds) : nil
        let thumbnail = LiveActivityArtworkThumbnail.make(from: albumArtImage)
        return .init(
            trackTitle: trackInfo?.title ?? "Not Playing",
            artist: trackInfo?.artist ?? "—",
            album: trackInfo?.album ?? "",
            isPlaying: isPlaying,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            dominantColorHex: SharedStorage.cachedDominantColorHex,
            startedAt: startedAt,
            endsAt: endsAt,
            albumArtThumbnail: thumbnail,
            groupMemberCount: currentGroupMembers.filter { !$0.isInvisible }.count,
            playbackSourceRaw: source?.rawValue,
            soundbarNightMode: isTVSource ? nightMode : nil,
            soundbarSpeechEnhancementRawLevel: isTVSource ? speechEnhancement.rawValue : nil,
            liveActivityStyleRaw: SharedStorage.liveActivityStyle.rawValue,
            audioQualityLabel: SharedStorage.cachedAudioQualityLabel
        )
    }

    // MARK: - Private Helpers

    private func syncSpeakerToStorage(_ speaker: SonosPlayer) {
        SharedStorage.speakerID = speaker.id
        SharedStorage.speakerIP = speaker.ipAddress
        SharedStorage.speakerName = speaker.name
        SharedStorage.coordinatorIP = speaker.coordinatorIP
    }

    private func updateSharedCache() {
        let currentTitle = trackInfo?.title
        let trackChanged = currentTitle != lastWidgetTrackTitle

        SharedStorage.isPlaying = isPlaying
        SharedStorage.cachedTrackTitle = trackInfo?.title
        SharedStorage.cachedArtist = trackInfo?.artist
        SharedStorage.cachedAlbum = trackInfo?.album
        SharedStorage.cachedAlbumArtURL = trackInfo?.albumArtURL
        SharedStorage.cachedVolume = volume
        SharedStorage.cachedPlaybackSource = trackInfo?.source.rawValue
        // Music tracks ship `audioQuality` (Atmos / Lossless / Hi-Res …). TV
        // input has no `audioQuality` at all — its parallel is `tvFormat`.
        // Reuse the same widget cache slot so the home/medium widgets and
        // Live Activity can surface the format string ("Dolby Atmos · MAT",
        // "Multichannel PCM · 5.1", …) and the Atmos badge logic, which
        // already keys off `label.contains("atmos")`, still picks up the
        // right mark.
        let audioQualityLabel = trackInfo?.audioQuality?.label
            ?? trackInfo?.tvFormat?.geekLabel
        SharedStorage.cachedAudioQualityLabel = audioQualityLabel
        logLiveActivity(action: "quality-cache-write",
                        extra: [
                            "track=\(Self.liveActivityLogValue(trackInfo?.title ?? "nil"))",
                            "source=\(trackInfo?.source.rawValue ?? "nil")",
                            "trackQuality=\(Self.liveActivityLogValue(trackInfo?.audioQuality?.label ?? "nil"))",
                            "tvFormat=\(Self.liveActivityLogValue(trackInfo?.tvFormat?.geekLabel ?? "nil"))",
                            "cachedQuality=\(Self.liveActivityLogValue(audioQualityLabel ?? "nil"))",
                            "relayAvailable=\(RelayManager.shared.isAvailable)",
                            "relayWriterReady=\(liveActivityRelayWriterReady)"
                        ])
        SharedStorage.cachedIsLiveStream = trackInfo?.isLiveStream ?? false
        if trackInfo?.source == .tv {
            SharedStorage.cachedSoundbarNightMode = nightMode
            SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = speechEnhancement.rawValue
        }
        SharedStorage.cachedGroupMemberCount = currentGroupMembers.filter { !$0.isInvisible }.count
        // Keep cloudGroupId in sync so the widget can call Cloud API independently.
        if let gid = cloudGroupId { SharedStorage.cloudGroupId = gid }

        // Reload widget only when something meaningful changed (track, play state).
        if trackChanged || isPlaying != SharedStorage.isPlaying {
            lastWidgetTrackTitle = currentTitle
            WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        }

    }

    private func logAudioQualityDiagnostic(action: String, extra: [String] = []) {
        var parts = [
            "audio_quality_diag",
            "action=\(action)",
            "track=\(Self.liveActivityLogValue(trackInfo?.title ?? "nil"))",
            "artist=\(Self.liveActivityLogValue(trackInfo?.artist ?? "nil"))",
            "source=\(trackInfo?.source.rawValue ?? "nil")",
            "relayStatus=\(liveActivityRelayStatusLogValue())"
        ]
        parts.append(contentsOf: extra)
        SonosLog.info(.sonosCloud, parts.joined(separator: " "))
    }

    private func loadAlbumArt() async {
        let urlStr = trackInfo?.albumArtURL ?? ""
        let incomingTrackIdentity = AlbumArtTrackIdentity.make(from: trackInfo)

        // No artwork in the current track — TV input, line-in, idle, etc.
        // Old code `guard let urlStr = ...` short-circuited and the previous
        // album cover would linger on the home-tab speaker card. Treat the
        // empty case as "clear everything" so switching from music → TV
        // properly resets the art (the player view falls back to its `tv`
        // glyph; the home card falls back to the speaker glyph).
        if urlStr.isEmpty {
            let hasDeferredMissingArtwork = deferredMissingAlbumArtTrackIdentity == incomingTrackIdentity
            let shouldClearArtwork = AlbumArtLoadAttemptPolicy.shouldClearArtworkForMissingURL(
                trackSource: trackInfo?.source,
                hasDisplayedArtwork: albumArtImage != nil,
                displayedTrackIdentity: displayedAlbumArtTrackIdentity,
                incomingTrackIdentity: incomingTrackIdentity,
                hasDeferredMissingArtworkForIncomingTrack: hasDeferredMissingArtwork
            )
            guard shouldClearArtwork else {
                loadingAlbumArtURL = nil
                albumArtTask?.cancel()
                deferredMissingAlbumArtTrackIdentity = incomingTrackIdentity
                return
            }
            deferredMissingAlbumArtTrackIdentity = nil
            guard lastAlbumArtURL != "" || albumArtImage != nil else { return }
            lastAlbumArtURL = ""
            loadingAlbumArtURL = nil
            albumArtTask?.cancel()
            withAnimation(.easeInOut(duration: 0.5)) {
                albumArtImage = nil
                displayedAlbumArtTrackIdentity = nil
                albumArtDominantColor = nil
                if let gid = selectedSpeaker?.groupId ?? selectedSpeaker?.id {
                    groupAlbumImages[gid] = nil
                    groupAlbumColors[gid] = nil
                    groupLastArtURL[gid] = nil
                }
            }
            SharedStorage.albumArtData = nil
            SharedStorage.cachedAlbumArtDataURL = nil
            SharedStorage.cachedDominantColorHex = nil
            return
        }

        if albumArtImage == nil,
           let cachedData = AlbumArtSharedCacheRecoveryPolicy.reusableArtworkData(
               currentURLString: urlStr,
               cachedDataURLString: SharedStorage.cachedAlbumArtDataURL,
               cachedData: SharedStorage.albumArtData
           ),
           let cachedImage = UIImage(data: cachedData) {
            albumArtTask?.cancel()
            loadingAlbumArtURL = nil
            let color = dominantColorCache[urlStr] ?? cachedImage.dominantColor()
            applyLoadedAlbumArt(
                cachedImage,
                color: color,
                bottomEdge: cachedImage.bottomEdgeColor(),
                urlString: urlStr,
                trackIdentity: incomingTrackIdentity,
                preserveDisplayedArtwork: false
            )
            SharedStorage.cachedAlbumArtDataURL = urlStr
            SharedStorage.cachedDominantColorHex = cachedImage.dominantColorHex()
            return
        }

        guard AlbumArtLoadAttemptPolicy.shouldStartLoad(
            urlString: urlStr,
            lastLoadedURL: lastAlbumArtURL,
            hasDisplayedArtwork: albumArtImage != nil,
            loadingURL: loadingAlbumArtURL
        ) else {
            return
        }
        deferredMissingAlbumArtTrackIdentity = nil
        let shouldPreserveDisplayedArtwork = AlbumArtRefreshPolicy.shouldPreserveDisplayedArtwork(
            hasDisplayedArtwork: albumArtImage != nil,
            displayedTrackIdentity: displayedAlbumArtTrackIdentity,
            incomingTrackIdentity: incomingTrackIdentity
        )
        loadingAlbumArtURL = urlStr
        albumArtTask?.cancel()

        guard let url = URL(string: urlStr) else {
            await MainActor.run {
                self.finishAlbumArtLoadAttempt(urlString: urlStr, loadedImage: nil)
                withAnimation(.easeInOut(duration: 0.5)) {
                    albumArtImage = nil
                    displayedAlbumArtTrackIdentity = nil
                    albumArtDominantColor = nil
                }
            }
            SharedStorage.albumArtData = nil
            SharedStorage.cachedAlbumArtDataURL = nil
            SharedStorage.cachedDominantColorHex = nil
            return
        }

        let capturedURL = urlStr
        albumArtTask = Task {
            // Fast path: image already in memory cache.
            if let cached = self.queueArtCache.object(forKey: urlStr as NSString) {
                guard !Task.isCancelled, self.loadingAlbumArtURL == urlStr else { return }
                let color = self.dominantColorCache[urlStr] ?? cached.dominantColor()
                let bottomEdge = cached.bottomEdgeColor()
                // Keep disk entry warm so LRU eviction doesn't drop the current song's art.
                QueueArtDiskCache.shared.touch(urlStr)
                await MainActor.run {
                    self.applyLoadedAlbumArt(
                        cached,
                        color: color,
                        bottomEdge: bottomEdge,
                        urlString: urlStr,
                        trackIdentity: incomingTrackIdentity,
                        preserveDisplayedArtwork: shouldPreserveDisplayedArtwork
                    )
                }
                if let data = cached.jpegData(compressionQuality: 0.9) {
                    SharedStorage.albumArtData = data
                    SharedStorage.cachedAlbumArtDataURL = urlStr
                }
                SharedStorage.cachedDominantColorHex = cached.dominantColorHex()
                return
            }

            // L2: check disk cache before hitting the network.
            if let cached = QueueArtDiskCache.shared.image(for: urlStr) {
                guard !Task.isCancelled, self.loadingAlbumArtURL == urlStr else { return }
                let color = self.dominantColorCache[urlStr] ?? cached.dominantColor()
                let bottomEdge = cached.bottomEdgeColor()
                self.queueArtCache.setObject(cached, forKey: urlStr as NSString,
                                             cost: Int(cached.size.width * cached.size.height * 4))
                await MainActor.run {
                    self.applyLoadedAlbumArt(
                        cached,
                        color: color,
                        bottomEdge: bottomEdge,
                        urlString: urlStr,
                        trackIdentity: incomingTrackIdentity,
                        preserveDisplayedArtwork: shouldPreserveDisplayedArtwork
                    )
                }
                if let data = cached.jpegData(compressionQuality: 0.9) {
                    SharedStorage.albumArtData = data
                    SharedStorage.cachedAlbumArtDataURL = urlStr
                }
                SharedStorage.cachedDominantColorHex = cached.dominantColorHex()
                return
            }

            // Slow path: download from network.
            do {
                let data = try await Self.fetchAlbumArtData(from: url, originalURLString: urlStr)
                guard !Task.isCancelled,
                      self.loadingAlbumArtURL == capturedURL,
                      self.trackInfo?.albumArtURL == capturedURL else { return }
                let image = UIImage(data: data)
                let dominantColor = self.dominantColorCache[urlStr] ?? image?.dominantColor()
                let bottomEdge = image?.bottomEdgeColor()
                if image != nil { QueueArtDiskCache.shared.store(data, for: urlStr) }
                await MainActor.run {
                    self.applyLoadedAlbumArt(
                        image,
                        color: dominantColor,
                        bottomEdge: bottomEdge,
                        urlString: urlStr,
                        trackIdentity: incomingTrackIdentity,
                        preserveDisplayedArtwork: shouldPreserveDisplayedArtwork
                    )
                }
                SharedStorage.albumArtData = data
                SharedStorage.cachedAlbumArtDataURL = urlStr
                SharedStorage.cachedDominantColorHex = image?.dominantColorHex()
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.finishAlbumArtLoadAttempt(urlString: urlStr, loadedImage: nil)
                }
                guard !shouldPreserveDisplayedArtwork else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.albumArtImage = nil
                        self.displayedAlbumArtTrackIdentity = nil
                        self.albumArtDominantColor = nil
                        self.albumArtBottomEdgeColor = nil
                    }
                }
            }
        }
        await albumArtTask?.value
    }

    private static func fetchAlbumArtData(from url: URL, originalURLString: String) async throws -> Data {
        if let relayURL = await MainActor.run(body: {
            RelayManager.shared.isAvailable ? RelayManager.shared.url : nil
        }) {
            do {
                return try await RelayClient.fetchArtwork(
                    baseURL: relayURL,
                    sourceURLString: originalURLString
                )
            } catch {
                SonosLog.debug(
                    .playback,
                    "relay artwork fetch failed; falling back direct url='\(originalURLString)' error=\(error)"
                )
            }
        }

        let (data, _) = try await Self.albumArtSession.data(from: url)
        return data
    }

    private func applyLoadedAlbumArt(
        _ image: UIImage?,
        color: Color?,
        bottomEdge: Color?,
        urlString: String,
        trackIdentity: String?,
        preserveDisplayedArtwork: Bool
    ) {
        finishAlbumArtLoadAttempt(urlString: urlString, loadedImage: image)
        deferredMissingAlbumArtTrackIdentity = nil

        if preserveDisplayedArtwork {
            withAnimation(.easeInOut(duration: Self.albumArtColorTransitionDuration)) {
                albumArtDominantColor = color
                albumArtBottomEdgeColor = bottomEdge
                if let gid = selectedSpeaker?.groupId ?? selectedSpeaker?.id {
                    groupAlbumColors[gid] = color
                }
            }
            dominantColorCache[urlString] = color
            if let gid = selectedSpeaker?.groupId ?? selectedSpeaker?.id {
                if let image {
                    groupAlbumImages[gid] = image
                    groupLastArtURL[gid] = urlString
                }
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.65)) {
            albumArtImage = image
            displayedAlbumArtTrackIdentity = image == nil ? nil : trackIdentity
            albumArtDominantColor = color
            albumArtBottomEdgeColor = bottomEdge
            if let gid = selectedSpeaker?.groupId ?? selectedSpeaker?.id {
                groupAlbumColors[gid] = color
                groupAlbumImages[gid] = image
                groupLastArtURL[gid] = image == nil ? nil : urlString
            }
        }
        dominantColorCache[urlString] = color
    }

    private func finishAlbumArtLoadAttempt(urlString: String, loadedImage image: UIImage?) {
        if loadingAlbumArtURL == urlString {
            loadingAlbumArtURL = nil
        }
        if image != nil {
            lastAlbumArtURL = urlString
        } else if lastAlbumArtURL == urlString {
            lastAlbumArtURL = nil
        }
    }
}
