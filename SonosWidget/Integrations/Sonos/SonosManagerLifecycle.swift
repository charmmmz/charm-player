import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    // MARK: - Lifecycle

    func loadSavedState() {
        allSpeakers = SharedStorage.savedSpeakers
        speakers = Self.homeSpeakerCoordinatorCandidates(in: allSpeakers)
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
        speakers = Self.homeSpeakerCoordinatorCandidates(in: allSpeakers)
        SharedStorage.savedSpeakers = allSpeakers
        let target = speaker.isCoordinator && !speaker.isInvisible
            ? speaker
            : speakers.first(where: { $0.groupId == speaker.groupId && $0.isCoordinator }) ?? speaker
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
            speakers = Self.homeSpeakerCoordinatorCandidates(in: allSpeakers)
            SharedStorage.savedSpeakers = allSpeakers
            let speaker = speakers.first(where: { $0.isCoordinator }) ?? speakers.first
            if let speaker { await selectSpeaker(speaker) }
        } catch {
            errorMessage = "Cannot connect to \(trimmed): \(error.localizedDescription)"
        }
        isLoading = false
    }

    func selectSpeaker(
        _ speaker: SonosPlayer,
        userInitiatedLiveActivityResume: Bool = false
    ) async {
        let previousLiveActivityGroupId = liveActivityGroupId()
        let previousSpeakerName = selectedSpeaker?.name
        let previousPlaybackIP = selectedSpeaker?.playbackIP
        let expectedSpeakerID = speaker.id
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
                    ?? (
                        PlaybackArtworkCachingPolicy.isQueueDiskCacheEnabled
                            ? QueueArtDiskCache.shared.image(for: urlString)
                            : nil
                    )
            }
        )
        let cachedSelectionColor = groupAlbumColors[targetGroupID]
        let cachedSelectionTrackIdentity = AlbumArtTrackIdentity.make(from: targetGroup?.trackInfo)
        selectedSpeaker = speaker
        syncSpeakerToStorage(speaker)
        let nextLiveActivityGroupId = liveActivityGroupId()

        if Self.shouldRecreateLiveActivityForSpeakerChange(
            currentActivityExists: currentActivity != nil,
            usesRelay: currentActivityUsesRelay,
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
        } else if currentActivity != nil,
                  previousLiveActivityGroupId != nil,
                  nextLiveActivityGroupId != nil,
                  previousLiveActivityGroupId != nextLiveActivityGroupId {
            logLiveActivity(action: "recreate-deferred",
                            activityID: currentActivity?.id,
                            mode: currentActivityUsesRelay ? "relay-token" : "local",
                            reason: "selected-speaker-changed",
                            groupId: nextLiveActivityGroupId,
                            extra: [
                                "oldGroupId=\(Self.liveActivityLogValue(previousLiveActivityGroupId ?? "nil"))",
                                "oldSpeaker=\(Self.liveActivityLogValue(previousSpeakerName ?? "nil"))",
                                "newSpeaker=\(Self.liveActivityLogValue(speaker.name))"
                            ])
        }

        if userInitiatedLiveActivityResume,
           let token = SharedStorage.liveActivityPushToStartToken,
           let nextLiveActivityGroupId {
            registerPushToStartTokenIfPossible(
                token,
                reason: "selected-speaker-user",
                clearDismissalSuppressionForGroupId: nextLiveActivityGroupId
            )
        }

        if let nextLiveActivityGroupId,
           !remoteLiveActivitiesByGroupID.isEmpty {
            currentActivity = remoteLiveActivitiesByGroupID[nextLiveActivityGroupId]
            currentActivityUsesRelay = currentActivity != nil
            lastRegisteredPushToken = currentActivity.flatMap {
                registeredPushTokensByActivityID[$0.id]
            }
            SharedStorage.liveActivityRelayPushToken =
                SharedStorage.liveActivityRelayPushTokensByGroupID[nextLiveActivityGroupId]
            liveActivityRelayWriterReady = SharedStorage.liveActivityRelayPushToken != nil
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
        cancelDelayedAudioQualityBadgeRetry()
        cachedCloudQuality = nil
        lastEnrichedTrackKey = nil
        lastCloudQualityAttempt = .distantPast
        lastLiveActivityRelayPreferencesSignature = nil
        if !userInitiatedLiveActivityResume {
            pushLiveActivityRelayPreferencesIfNeeded(force: true)
        }
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
        guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
        _ = await probeBackend()
        guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
        if userInitiatedLiveActivityResume {
            if let token = SharedStorage.liveActivityPushToStartToken,
               let nextLiveActivityGroupId {
                registerPushToStartTokenIfPossible(
                    token,
                    reason: "selected-speaker-user-after-probe",
                    clearDismissalSuppressionForGroupId: nextLiveActivityGroupId
                )
            }
            pushLiveActivityRelayPreferencesIfNeeded(force: true, resumeLiveActivity: true)
        }
        await refreshState(expectedSpeakerID: expectedSpeakerID)
        guard userInitiatedLiveActivityResume,
              speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID),
              let fallbackGroupId = liveActivityGroupId() else {
            return
        }
        scheduleManualLiveActivityResumeFallback(
            groupId: fallbackGroupId,
            expectedSpeakerID: expectedSpeakerID,
            speakerName: speaker.name
        )
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

    func applyCachedArtworkForSpeakerSelection(
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

}
