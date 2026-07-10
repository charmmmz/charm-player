import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    // MARK: - Transport Backend Probe

    /// Decide whether we can reach the speaker over LAN or need to fall back
    /// to the Sonos Cloud Control API. The TCP probe is short (1 s) so the
    /// UI rarely blocks on it — subsequent commands just consult the cached
    /// `transportBackend` value. Concurrent callers share the in-flight
    /// `probeTask`, so e.g. "app foreground + speaker tap" only does one
    /// probe.
    @discardableResult
    func probeBackend() async -> TransportBackend {
        guard let speaker = selectedSpeaker else { return .unknown }
        let expectedSpeakerID = speaker.id
        let expectedPlaybackIP = speaker.playbackIP

        if let probeTask, probeTask.speakerID == expectedSpeakerID {
            return await probeTask.task.value
        }

        let task = Task<TransportBackend, Never> { [weak self, expectedSpeakerID, expectedPlaybackIP] in
            guard let self else { return .unknown }
            let result = await self.runBackendProbe(playbackIP: expectedPlaybackIP)
            await MainActor.run {
                guard self.speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else {
                    return
                }
                self.transportBackend = result
                if result != .lan {
                    self.stopEventSubscriptions()
                }
                SonosLog.info(.sonosCloud, "transport backend → \(result)")
            }
            return result
        }
        probeTask = (speakerID: expectedSpeakerID, task: task)
        defer {
            if probeTask?.speakerID == expectedSpeakerID {
                probeTask = nil
            }
        }
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
    func runBackendProbe(playbackIP ip: String) async -> TransportBackend {
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
    static func tcpProbe(host: String, port: UInt16,
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
        let expectedSpeakerID = speaker.id

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
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
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

    nonisolated static func lanTrackInfo(
        _ positionInfo: TrackInfo,
        localMetadata: SonosCloudAPI.CloudPlaybackMetadata?,
        cachedCloudQuality: (trackKey: String, quality: AudioQuality)?,
        cloudQualityIsAuthoritative: Bool
    ) -> TrackInfo {
        var info = reconciledLANTrackInfo(
            positionInfo,
            cachedCloudQuality: cachedCloudQuality,
            cloudQualityIsAuthoritative: cloudQualityIsAuthoritative
        )
        if let localMetadata {
            info = trackInfo(info, applyingPlaybackMetadata: localMetadata)
        }
        return info
    }

    nonisolated static func shouldFetchLocalControlMetadataForLANSpeakerStatus(
        _ positionInfo: TrackInfo
    ) -> Bool {
        guard isLiveStreamTrack(positionInfo),
              !homeSpeakerTrackHasDisplayTitle(positionInfo) else {
            return false
        }
        return positionInfo.source == .appleMusic || positionInfo.source == .unknown
    }

    nonisolated static func trackInfo(
        _ incoming: TrackInfo,
        applyingPlaybackMetadata metadata: SonosCloudAPI.CloudPlaybackMetadata
    ) -> TrackInfo {
        var info = incoming
        guard let track = metadata.currentItem?.track else {
            applyPlaybackContainerFallback(to: &info, metadata: metadata)
            return info
        }

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

    nonisolated static func applyPlaybackContainerFallback(
        to info: inout TrackInfo,
        metadata: SonosCloudAPI.CloudPlaybackMetadata
    ) {
        guard metadata.currentItem?.track == nil else { return }
        let containerTitle = displayableMetadataText(metadata.container?.name)
        let containerArtURL = nonEmpty(metadata.container?.imageUrl)
        guard containerTitle != nil || containerArtURL != nil else { return }

        let source = PlaybackSource.from(serviceName: metadata.container?.name)
        guard info.source == .appleMusic || source == .appleMusic else { return }

        if let containerTitle, !homeSpeakerTrackHasDisplayTitle(info) {
            info.title = containerTitle
        }
        if let containerArtURL {
            info.albumArtURL = containerArtURL
        }

        if source != .unknown {
            info.source = source
        }

        if displayableMetadataText(info.artist) == nil {
            let sourceName = fallbackDisplayName(for: info.source)
            if !sourceName.isEmpty {
                info.artist = sourceName
            }
        }
    }

    nonisolated static func fallbackDisplayName(for source: PlaybackSource) -> String {
        switch source {
        case .appleMusic:
            return "Apple Music"
        default:
            return ""
        }
    }

    nonisolated static func displayableMetadataText(_ value: String?) -> String? {
        guard let trimmed = nonEmpty(value) else { return nil }
        switch trimmed.lowercased() {
        case "unknown", "idle", "not playing":
            return nil
        default:
            return trimmed
        }
    }

    nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func fetchLocalControlPlaybackMetadata(ip: String) async -> SonosCloudAPI.CloudPlaybackMetadata? {
        guard let playerId = localControlPlayerId(forPlaybackIP: ip) else {
            logAudioQualityDiagnostic(action: "local-control-skip", extra: ["reason=missing-player-id"])
            return nil
        }

        if let groupId = localControlGroupIdsByPlayerId[playerId] {
            do {
                return try await fetchLocalControlPlaybackMetadata(
                    ip: ip,
                    groupId: groupId,
                    playerId: playerId
                )
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
            return try await fetchLocalControlPlaybackMetadata(
                ip: ip,
                groupId: groupId,
                playerId: playerId
            )
        } catch {
            logAudioQualityDiagnostic(action: "local-control-failed", extra: [
                "playerId=\(Self.liveActivityLogValue(playerId))",
                "reason=\(Self.liveActivityLogValue(error.localizedDescription))"
            ])
            return nil
        }
    }

    func fetchLocalControlPlaybackMetadata(
        ip: String,
        groupId: String,
        playerId: String
    ) async throws -> SonosCloudAPI.CloudPlaybackMetadata {
        let metadata = try await SonosLocalControlAPI.getPlaybackMetadata(ip: ip, groupId: groupId)
        logLocalControlMetadata(metadata, groupId: groupId, playerId: playerId)

        guard Self.playbackMetadataQualityNeedsRetry(metadata) else {
            return metadata
        }

        logAudioQualityDiagnostic(action: "local-control-quality-retry", extra: [
            "groupId=\(Self.liveActivityLogValue(groupId))",
            "playerId=\(Self.liveActivityLogValue(playerId))",
            "reason=incomplete-quality"
        ])

        do {
            try await Task.sleep(nanoseconds: Self.localPlaybackMetadataQualityRetryDelayNanoseconds)
            let retryMetadata = try await SonosLocalControlAPI.getPlaybackMetadata(ip: ip, groupId: groupId)
            logLocalControlMetadata(retryMetadata, groupId: groupId, playerId: playerId)
            return retryMetadata
        } catch {
            if error is CancellationError { throw error }
            logAudioQualityDiagnostic(action: "local-control-quality-retry-failed", extra: [
                "groupId=\(Self.liveActivityLogValue(groupId))",
                "playerId=\(Self.liveActivityLogValue(playerId))",
                "reason=\(Self.liveActivityLogValue(error.localizedDescription))"
            ])
            return metadata
        }
    }

    nonisolated static func playbackMetadataQualityNeedsRetry(
        _ metadata: SonosCloudAPI.CloudPlaybackMetadata
    ) -> Bool {
        guard let quality = metadata.currentItem?.track?.quality else { return false }
        return playbackMetadataQualityNeedsRetry(quality)
    }

    nonisolated static func audioQualityNeedsDelayedBadgeRetry(_ quality: AudioQuality?) -> Bool {
        guard let quality else { return true }
        if quality.lossless == true || quality.immersive == true { return false }
        return quality.codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "audio"
    }

    nonisolated static func playbackMetadataQualityNeedsRetry(
        _ quality: SonosCloudAPI.CloudTrackQuality
    ) -> Bool {
        let codec = quality.codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hasGenericCodec = codec.isEmpty || codec == "audio"
        let hasAudioParameters = quality.bitDepth != nil || quality.sampleRate != nil
        let mapsToTechnicalFallback = audioQualityNeedsDelayedBadgeRetry(AudioQuality.from(cloudQuality: quality))
        return quality.immersive != true
            && hasGenericCodec
            && hasAudioParameters
            && (quality.lossless == nil || (quality.lossless == false && mapsToTechnicalFallback))
    }

    func localControlPlayerId(forPlaybackIP ip: String) -> String? {
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

    func cacheAudioQualityIfPresent(_ quality: AudioQuality?, for info: TrackInfo) {
        guard let quality, let trackKey = Self.cloudQualityTrackKey(for: info) else { return }
        cachedCloudQuality = (trackKey: trackKey, quality: quality)
    }

    func cancelDelayedAudioQualityBadgeRetry() {
        delayedAudioQualityRetryTask?.cancel()
        delayedAudioQualityRetryTask = nil
        delayedAudioQualityRetryTrackKey = nil
        delayedAudioQualityRetryExhaustedTrackKey = nil
    }

    func scheduleDelayedAudioQualityBadgeRetryIfNeeded(expectedSpeakerID: String) {
        guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID),
              transportState == .playing,
              SonosAuth.shared.isLoggedIn,
              let trackInfo,
              isCloudQualityAuthoritative(trackInfo.source),
              let trackKey = Self.cloudQualityTrackKey(for: trackInfo),
              Self.audioQualityNeedsDelayedBadgeRetry(trackInfo.audioQuality) else {
            if delayedAudioQualityRetryTask != nil,
               delayedAudioQualityRetryTrackKey != Self.cloudQualityTrackKey(for: trackInfo) {
                cancelDelayedAudioQualityBadgeRetry()
            }
            return
        }

        if delayedAudioQualityRetryExhaustedTrackKey == trackKey { return }
        if delayedAudioQualityRetryTrackKey == trackKey,
           delayedAudioQualityRetryTask != nil {
            return
        }

        delayedAudioQualityRetryTask?.cancel()
        delayedAudioQualityRetryTrackKey = trackKey
        delayedAudioQualityRetryExhaustedTrackKey = nil
        delayedAudioQualityRetryTask = Task { @MainActor [weak self] in
            await self?.runDelayedAudioQualityBadgeRetries(
                expectedSpeakerID: expectedSpeakerID,
                trackKey: trackKey
            )
        }
        logAudioQualityDiagnostic(action: "cloud-enrich-delayed-scheduled", extra: [
            "trackKey=\(Self.liveActivityLogValue(trackKey))",
            "currentQuality=\(Self.liveActivityLogValue(trackInfo.audioQuality?.label ?? "nil"))"
        ])
    }

    func runDelayedAudioQualityBadgeRetries(
        expectedSpeakerID: String,
        trackKey: String
    ) async {
        defer {
            if delayedAudioQualityRetryTrackKey == trackKey {
                delayedAudioQualityRetryTask = nil
                delayedAudioQualityRetryTrackKey = nil
            }
        }

        for (attemptIndex, delay) in Self.delayedAudioQualityRetryIntervalsNanoseconds.enumerated() {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID),
                  Self.cloudQualityTrackKey(for: trackInfo) == trackKey else {
                return
            }
            guard Self.audioQualityNeedsDelayedBadgeRetry(trackInfo?.audioQuality) else {
                delayedAudioQualityRetryExhaustedTrackKey = nil
                return
            }

            logAudioQualityDiagnostic(action: "cloud-enrich-delayed-retry", extra: [
                "attempt=\(attemptIndex + 1)",
                "trackKey=\(Self.liveActivityLogValue(trackKey))",
                "currentQuality=\(Self.liveActivityLogValue(trackInfo?.audioQuality?.label ?? "nil"))"
            ])
            await enrichAudioQualityFromCloud(
                expectedSpeakerID: expectedSpeakerID,
                bypassCooldown: true
            )

            guard !Task.isCancelled,
                  speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID),
                  Self.cloudQualityTrackKey(for: trackInfo) == trackKey else {
                return
            }

            syncCurrentGroupStatusFromPlaybackState()
            updateSharedCache()
            manageLiveActivity()

            if !Self.audioQualityNeedsDelayedBadgeRetry(trackInfo?.audioQuality) {
                delayedAudioQualityRetryExhaustedTrackKey = nil
                return
            }
        }

        delayedAudioQualityRetryExhaustedTrackKey = trackKey
        logAudioQualityDiagnostic(action: "cloud-enrich-delayed-exhausted", extra: [
            "trackKey=\(Self.liveActivityLogValue(trackKey))",
            "currentQuality=\(Self.liveActivityLogValue(trackInfo?.audioQuality?.label ?? "nil"))"
        ])
    }

    func logLocalControlMetadata(
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
    func isCloudQualityAuthoritative(_ source: PlaybackSource?) -> Bool {
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
    func enrichAudioQualityFromCloud(
        expectedSpeakerID: String,
        bypassCooldown: Bool = false
    ) async {
        guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
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
            "bypassCooldown=\(bypassCooldown)",
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
        if !bypassCooldown, trackKey == lastEnrichedTrackKey {
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
        guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
        guard let groupId = cloudGroupId else {
            logAudioQualityDiagnostic(action: "cloud-enrich-skip", extra: ["reason=missing-cloud-group"])
            return
        }
        guard let token = await SonosAuth.shared.validAccessToken() else {
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            logAudioQualityDiagnostic(action: "cloud-enrich-skip", extra: ["reason=missing-token"])
            return
        }

        do {
            let metadata = try await fetchPlaybackMetadata(token: token, groupId: groupId)
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
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
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            logAudioQualityDiagnostic(action: "cloud-enrich-failed", extra: ["reason=unauthorized"])
            _ = await SonosAuth.shared.refreshAccessToken()
        } catch {
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            lastEnrichedTrackKey = trackKey
            SonosLog.error(.sonosCloud, "playbackMetadata error: \(error)")
            logAudioQualityDiagnostic(action: "cloud-enrich-failed", extra: [
                "reason=\(Self.liveActivityLogValue(error.localizedDescription))"
            ])
        }
    }

    func fetchPlaybackMetadata(token: String, groupId: String) async throws -> SonosCloudAPI.CloudPlaybackMetadata {
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

    var hasActiveLANEventSubscriptions: Bool {
        transportBackend == .lan
            && eventSubscriptions.subscription(for: .avTransport) != nil
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        startLiveActivityPushToStartObservers()

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
        stopLiveActivityPushToStartObservers()
        cancelDelayedAudioQualityBadgeRetry()
        NotificationCenter.default.removeObserver(self,
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self,
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

}
