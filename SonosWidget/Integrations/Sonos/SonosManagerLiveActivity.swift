import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    // MARK: - Live Activity

    struct LiveActivityStartRegistrationTarget: Hashable {
        let groupId: String
        let speakerName: String?
    }

    func scheduleManualLiveActivityResumeFallback(
        groupId: String,
        expectedSpeakerID: String,
        speakerName: String
    ) {
        liveActivityResumeFallbackTask?.cancel()
        liveActivityResumeFallbackGroupId = groupId
        logLiveActivity(action: "resume-fallback-scheduled",
                        mode: "relay-token",
                        groupId: groupId,
                        extra: [
                            "speaker=\(Self.liveActivityLogValue(speakerName))",
                            "delayMs=2500"
                        ])

        liveActivityResumeFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveActivityResumeFallbackDelayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            guard self.liveActivityResumeFallbackGroupId == groupId else { return }
            defer {
                if self.liveActivityResumeFallbackGroupId == groupId {
                    self.liveActivityResumeFallbackTask = nil
                    self.liveActivityResumeFallbackGroupId = nil
                }
            }

            guard self.speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID),
                  let speaker = self.selectedSpeaker,
                  self.liveActivityGroupId() == groupId else {
                self.logLiveActivity(action: "resume-fallback-skip",
                                     mode: "relay-token",
                                     reason: "selection-changed",
                                     groupId: groupId)
                return
            }

            let now = Date()
            let currentActivityExists = self.liveActivityExists(forGroupId: groupId)
            let shouldKeep = Self.shouldKeepLiveActivity(
                isPlaying: self.isPlaying,
                transportState: self.transportState,
                currentActivityExists: currentActivityExists,
                playStateLockUntil: SharedStorage.playStateLockUntil,
                now: now
            )
            guard Self.shouldCreateManualResumeFallbackLiveActivity(
                currentActivityExistsForGroup: currentActivityExists,
                shouldKeepActivity: shouldKeep,
                userInitiatedResume: true
            ) else {
                self.logLiveActivity(action: "resume-fallback-skip",
                                     mode: "relay-token",
                                     reason: currentActivityExists ? "activity-exists" : "should-not-keep",
                                     groupId: groupId)
                return
            }

            self.logLiveActivity(action: "resume-fallback-create",
                                 mode: "relay-token",
                                 groupId: groupId,
                                 extra: ["speaker=\(Self.liveActivityLogValue(speaker.name))"])
            _ = self.createRelayTokenLiveActivity(
                speaker: speaker,
                reason: "manual-resume-fallback",
                logLocalFallbackOnFailure: false
            )
        }
    }

    func cancelManualLiveActivityResumeFallback(
        groupId: String? = nil,
        reason: String
    ) {
        guard let pendingGroupId = liveActivityResumeFallbackGroupId,
              groupId == nil || groupId == pendingGroupId else {
            return
        }
        liveActivityResumeFallbackTask?.cancel()
        liveActivityResumeFallbackTask = nil
        liveActivityResumeFallbackGroupId = nil
        logLiveActivity(action: "resume-fallback-cancel",
                        mode: "relay-token",
                        reason: reason,
                        groupId: pendingGroupId)
    }

    func liveActivityExists(forGroupId groupId: String) -> Bool {
        if remoteLiveActivitiesByGroupID[groupId] != nil {
            return true
        }
        if let currentActivity,
           liveActivity(currentActivity, matchesGroupId: groupId) {
            return true
        }
        return Activity<SonosActivityAttributes>.activities.contains {
            liveActivity($0, matchesGroupId: groupId)
        }
    }

    func liveActivity(
        _ activity: Activity<SonosActivityAttributes>,
        matchesGroupId groupId: String
    ) -> Bool {
        activity.attributes.groupId == groupId
    }

    @discardableResult
    func createRelayTokenLiveActivity(
        speaker: SonosPlayer,
        reason: String,
        logLocalFallbackOnFailure: Bool
    ) -> Bool {
        let state = makeActivityState()
        let attrs = SonosActivityAttributes(
            speakerName: speaker.name,
            groupId: liveActivityGroupId()
        )
        let content = ActivityContent(state: state, staleDate: Self.liveActivityStaleDate())

        do {
            let activity = try Activity.request(
                attributes: attrs,
                content: content,
                pushType: .token
            )
            currentActivity = activity
            currentActivityUsesRelay = true
            liveActivityRelayWriterReady = false
            logLiveActivity(action: "create",
                            activityID: activity.id,
                            mode: "relay-token",
                            state: state,
                            extra: [
                                "speaker=\(Self.liveActivityLogValue(speaker.name))",
                                "reason=\(Self.liveActivityLogValue(reason))"
                            ])
            spawnPushTokenObserver(activity: activity, speakerName: speaker.name)
            spawnActivityStateObserver(
                activity: activity,
                groupId: attrs.groupId,
                usesRelay: true
            )
            pushLiveActivityRelayPreferencesIfNeeded(force: true)
            return true
        } catch {
            logLiveActivity(action: "create-failed",
                            mode: "relay-token",
                            reason: error.localizedDescription,
                            state: state,
                            groupId: attrs.groupId,
                            extra: ["requestReason=\(Self.liveActivityLogValue(reason))"])
            if logLocalFallbackOnFailure {
                SonosLog.info(.station,
                    "Activity.request(.token) failed (\(error.localizedDescription)). " +
                    "Falling back to local-update Live Activity.")
            }
            return false
        }
    }

    func manageLiveActivity() {
        manageRemoteMediaSession()

        guard let speaker = selectedSpeaker else {
            logLiveActivity(action: "skip", reason: "no-selected-speaker")
            return
        }

        // Reattach to an existing activity if the in-memory reference was lost
        // after a process relaunch. We keep it alive and continue local
        // updates regardless of whether it was originally local or push-token.
        if currentActivity == nil {
            let activities = Activity<SonosActivityAttributes>.activities
            let usesRelay = RelayManager.shared.isAvailable
            for activity in activities {
                let groupId = activity.attributes.groupId ?? liveActivityGroupId() ?? activity.attributes.speakerName
                remoteLiveActivitiesByGroupID[groupId] = activity
                logLiveActivity(action: "reattach", activityID: activity.id,
                                mode: usesRelay ? "relay-token" : "local",
                                groupId: groupId)
                spawnActivityStateObserver(
                    activity: activity,
                    groupId: groupId,
                    usesRelay: usesRelay
                )
                if usesRelay {
                    spawnPushTokenObserver(
                        activity: activity,
                        speakerName: activity.attributes.speakerName
                    )
                }
            }
            if let selectedGroupId = liveActivityGroupId() {
                currentActivity = remoteLiveActivitiesByGroupID[selectedGroupId]
            } else {
                currentActivity = activities.first
            }
            currentActivityUsesRelay = currentActivity.map { _ in usesRelay } ?? false
            if currentActivityUsesRelay, let selectedGroupId = liveActivityGroupId() {
                SharedStorage.liveActivityRelayPushToken =
                    SharedStorage.liveActivityRelayPushTokensByGroupID[selectedGroupId]
                lastRegisteredPushToken = currentActivity.flatMap {
                    registeredPushTokensByActivityID[$0.id]
                } ?? SharedStorage.liveActivityRelayPushToken
                liveActivityRelayWriterReady = SharedStorage.liveActivityRelayPushToken != nil
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

        let pushToStartGroupId = liveActivityGroupId()
        let pushToStartRelayURLString = RelayManager.shared.url?.absoluteString
        let pushToStartRegistration = pushToStartGroupId.flatMap {
            SharedStorage.liveActivityPushToStartRegistration(for: $0)
        }
        let hasCurrentPushToStartRegistration = Self.hasCurrentPushToStartRegistration(
            token: SharedStorage.liveActivityPushToStartToken,
            registeredToken: pushToStartRegistration?.token
                ?? SharedStorage.liveActivityPushToStartRegisteredToken,
            currentGroupId: pushToStartGroupId,
            registeredGroupId: pushToStartRegistration == nil
                ? SharedStorage.liveActivityPushToStartRegisteredGroupID
                : pushToStartGroupId,
            currentRelayURLString: pushToStartRelayURLString,
            registeredRelayURLString: pushToStartRegistration?.relayURLString
                ?? SharedStorage.liveActivityPushToStartRegisteredRelayURLString,
            registeredAt: pushToStartRegistration?.registeredAt
                ?? SharedStorage.liveActivityPushToStartRegisteredAt
        )
        if let token = SharedStorage.liveActivityPushToStartToken,
           RelayManager.shared.isAvailable {
            registerPushToStartTokenIfPossible(token, reason: "manage-live-activity-refresh")
        }

        let useRelay = RelayManager.shared.isAvailable

        if currentActivity == nil {
            let relayPushToStartReady = Self.isRelayPushToStartReady(
                relayAvailable: RelayManager.shared.isAvailable,
                apnsMode: RelayManager.shared.relayAPNs?.mode,
                hasRegisteredPushToStartToken: hasCurrentPushToStartRegistration
            )
            guard Self.shouldCreateLocalLiveActivity(
                currentActivityExists: false,
                shouldKeepActivity: shouldKeep,
                relayPushToStartReady: relayPushToStartReady
            ) else {
                logLiveActivity(action: "skip-create",
                                mode: "relay-token",
                                reason: "relay-push-to-start-ready")
                if let token = SharedStorage.liveActivityPushToStartToken {
                    registerPushToStartTokenIfPossible(token, reason: "skip-create-refresh")
                }
                return
            }

            // First try the user's preferred mode. If that's `.token` (relay
            // looks reachable) but the app doesn't actually have an
            // `aps-environment` entitlement — i.e. no Apple Developer account
            // / push capability is set up yet — `Activity.request` will throw.
            // Fall back to local-update mode unconditionally so the Lock
            // Screen still shows *something*. The user gets a working Live
            // Activity right now, and once they enrol + sign with the right
            // entitlement the same code path automatically upgrades to push.
            if useRelay {
                if createRelayTokenLiveActivity(
                    speaker: speaker,
                    reason: "manage-live-activity",
                    logLocalFallbackOnFailure: true
                ) {
                    return
                }
            }

            // No existing activity — create one (always, even during TRANSITIONING).
            let state = makeActivityState()
            let attrs = SonosActivityAttributes(
                speakerName: speaker.name,
                groupId: liveActivityGroupId()
            )
            // `staleDate` is refreshed on every `update()` below so an alive
            // app keeps the activity fresh indefinitely. If all writers stop,
            // iOS can age the activity out without us actively killing it.
            let content = ActivityContent(state: state, staleDate: Self.liveActivityStaleDate())

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
                spawnActivityStateObserver(
                    activity: activity,
                    groupId: attrs.groupId,
                    usesRelay: false
                )
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
        !usesRelay
    }

    nonisolated static func shouldCreateLocalLiveActivity(
        currentActivityExists: Bool,
        shouldKeepActivity: Bool,
        relayPushToStartReady: Bool
    ) -> Bool {
        shouldKeepActivity && !currentActivityExists && !relayPushToStartReady
    }

    nonisolated static func shouldCreateManualResumeFallbackLiveActivity(
        currentActivityExistsForGroup: Bool,
        shouldKeepActivity: Bool,
        userInitiatedResume: Bool
    ) -> Bool {
        userInitiatedResume && shouldKeepActivity && !currentActivityExistsForGroup
    }

    nonisolated static func isRelayPushToStartReady(
        relayAvailable: Bool,
        apnsMode: RelayClient.HealthResponse.APNs.Mode?,
        hasRegisteredPushToStartToken: Bool
    ) -> Bool {
        relayAvailable && apnsMode == .ready && hasRegisteredPushToStartToken
    }

    nonisolated static func hasCurrentPushToStartRegistration(
        token: String?,
        registeredToken: String?,
        currentGroupId: String?,
        registeredGroupId: String?,
        currentRelayURLString: String?,
        registeredRelayURLString: String?,
        registeredAt: Date
    ) -> Bool {
        guard registeredAt > .distantPast,
              let token = cleanLiveActivityHintString(token),
              let registeredToken = cleanLiveActivityHintString(registeredToken),
              let currentGroupId = cleanLiveActivityHintString(currentGroupId),
              let registeredGroupId = cleanLiveActivityHintString(registeredGroupId),
              let currentRelayURLString = cleanLiveActivityHintString(currentRelayURLString),
              let registeredRelayURLString = cleanLiveActivityHintString(registeredRelayURLString) else {
            return false
        }

        return token == registeredToken
            && currentGroupId == registeredGroupId
            && currentRelayURLString == registeredRelayURLString
    }

    nonisolated static func clearPushToStartRegistration() {
        SharedStorage.liveActivityPushToStartRegisteredToken = nil
        SharedStorage.liveActivityPushToStartRegisteredGroupID = nil
        SharedStorage.liveActivityPushToStartRegisteredRelayURLString = nil
        SharedStorage.liveActivityPushToStartRegisteredAt = .distantPast
        SharedStorage.liveActivityPushToStartRegistrationsByGroupID = [:]
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
        usesRelay: Bool,
        previousGroupId: String?,
        nextGroupId: String?
    ) -> Bool {
        guard currentActivityExists,
              !usesRelay,
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

    func logLiveActivity(action: String,
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

    func liveActivityRelayStatusLogValue() -> String {
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

    static func liveActivityStateLogParts(
        _ state: SonosActivityAttributes.ContentState
    ) -> [String] {
        let preferredArtwork = state.preferredAlbumArtData
        let compactArtwork = state.compactAlbumArtData
        let preferredArtworkDecodable = preferredArtwork.flatMap { UIImage(data: $0) } != nil
        let compactArtworkDecodable = compactArtwork.flatMap { UIImage(data: $0) } != nil

        return [
            "track=\(liveActivityLogValue(state.trackTitle))",
            "artist=\(liveActivityLogValue(state.artist))",
            "playing=\(state.isPlaying)",
            "pos=\(Int(state.positionSeconds.rounded()))",
            "duration=\(Int(state.durationSeconds.rounded()))",
            "color=\(state.dominantColorHex ?? "nil")",
            "artBytes=\(state.albumArtThumbnail?.count ?? 0)",
            "artTrace=\(state.artworkTraceId ?? "nil")",
            "preferredArtBytes=\(preferredArtwork?.count ?? 0)",
            "preferredArtDecodable=\(preferredArtworkDecodable)",
            "compactArtBytes=\(compactArtwork?.count ?? 0)",
            "compactArtDecodable=\(compactArtworkDecodable)",
            "members=\(state.groupMemberCount)",
            "sourceRaw=\(state.playbackSourceRaw ?? "nil")",
            "activityStyle=\(state.liveActivityStyleRaw ?? "nil")",
            "quality=\(state.audioQualityLabel ?? "nil")",
            "hasStartedAt=\(state.startedAt != nil)",
            "hasEndsAt=\(state.endsAt != nil)"
        ]
    }

    static func liveActivityLogValue(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "'\(sanitized)'"
    }

    static func shortLiveActivityIdentifier(_ value: String) -> String {
        guard value.count > 14 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }

}
