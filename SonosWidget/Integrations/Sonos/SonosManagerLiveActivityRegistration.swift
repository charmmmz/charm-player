import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    func startLiveActivityPushToStartObservers() {
        if let tokenData = Activity<SonosActivityAttributes>.pushToStartToken {
            handlePushToStartToken(tokenData, reason: "push-to-start-token-current")
        }

        pushToStartTokenTask?.cancel()
        pushToStartTokenTask = Task { [weak self] in
            for await tokenData in Activity<SonosActivityAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.handlePushToStartToken(tokenData, reason: "push-to-start-token-update")
                }
            }
        }

        activityUpdatesTask?.cancel()
        activityUpdatesTask = Task { [weak self] in
            for await activity in Activity<SonosActivityAttributes>.activityUpdates {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.attachLiveActivityIfNeeded(activity, reason: "activity-updates")
                }
            }
        }
    }

    func stopLiveActivityPushToStartObservers() {
        cancelManualLiveActivityResumeFallback(reason: "stop-observers")
        pushToStartTokenTask?.cancel()
        pushToStartTokenTask = nil
        activityUpdatesTask?.cancel()
        activityUpdatesTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        for task in pushTokenTasksByActivityID.values { task.cancel() }
        pushTokenTasksByActivityID = [:]
        for task in activityStateTasksByActivityID.values { task.cancel() }
        activityStateTasksByActivityID = [:]
    }

    func handlePushToStartToken(_ tokenData: Data, reason: String) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        if SharedStorage.liveActivityPushToStartToken != hex {
            Self.clearPushToStartRegistration()
            inFlightPushToStartRegistrationKey = nil
        }
        SharedStorage.liveActivityPushToStartToken = hex
        registerPushToStartTokenIfPossible(hex, reason: reason)
    }

    func registerPushToStartTokenIfPossible(
        _ token: String,
        reason: String,
        clearDismissalSuppressionForGroupId: String? = nil
    ) {
        guard RelayManager.shared.isAvailable,
              let url = RelayManager.shared.url else {
            logLiveActivity(action: "register-push-to-start-skip",
                            mode: "relay-token",
                            reason: "missing-relay-or-group",
                            token: token)
            return
        }

        let targets = liveActivityStartRegistrationTargets(
            limitedToGroupId: clearDismissalSuppressionForGroupId
        )
        guard !targets.isEmpty else {
            logLiveActivity(action: "register-push-to-start-skip",
                            mode: "relay-token",
                            reason: "missing-registration-target",
                            token: token,
                            relayURL: url)
            return
        }

        for target in targets {
            registerPushToStartToken(
                token,
                target: target,
                relayURL: url,
                reason: reason,
                clearDismissalSuppression: clearDismissalSuppressionForGroupId == target.groupId
            )
        }
    }

    func liveActivityStartRegistrationTargets(
        limitedToGroupId: String? = nil
    ) -> [LiveActivityStartRegistrationTarget] {
        var targets: [LiveActivityStartRegistrationTarget] = []
        var seenGroupIds = Set<String>()

        func append(groupId: String?, speakerName: String?) {
            let cleanGroupId = groupId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !cleanGroupId.isEmpty else { return }
            guard limitedToGroupId == nil || limitedToGroupId == cleanGroupId else { return }
            guard seenGroupIds.insert(cleanGroupId).inserted else { return }
            targets.append(.init(groupId: cleanGroupId, speakerName: speakerName))
        }

        append(groupId: liveActivityGroupId(), speakerName: selectedSpeaker?.name)
        for status in groupStatuses where status.transportState == .playing {
            append(groupId: status.coordinator.playbackIP, speakerName: status.coordinator.name)
        }
        return targets
    }

    func registerPushToStartToken(
        _ token: String,
        target: LiveActivityStartRegistrationTarget,
        relayURL url: URL,
        reason: String,
        clearDismissalSuppression: Bool
    ) {
        let groupId = target.groupId
        let relayURLString = url.absoluteString
        let liveActivityStyleRaw = SharedStorage.liveActivityStyle.rawValue
        let activeActivityIds = Activity<SonosActivityAttributes>.activities.compactMap { activity -> String? in
            if let activityGroupId = activity.attributes.groupId,
               activityGroupId != groupId {
                return nil
            }
            return activity.id
        }
        let groupRegistration = SharedStorage.liveActivityPushToStartRegistration(for: groupId)
        let hasGroupRegistration = Self.hasCurrentPushToStartRegistration(
            token: token,
            registeredToken: groupRegistration?.token,
            currentGroupId: groupId,
            registeredGroupId: groupRegistration == nil ? nil : groupId,
            currentRelayURLString: relayURLString,
            registeredRelayURLString: groupRegistration?.relayURLString,
            registeredAt: groupRegistration?.registeredAt ?? .distantPast
        )
        if !clearDismissalSuppression && hasGroupRegistration { return }

        let registrationKey = "\(token)|\(groupId)|\(relayURLString)|clear=\(clearDismissalSuppression)"
        guard inFlightPushToStartRegistrationKey != registrationKey else {
            logLiveActivity(action: "register-push-to-start-skip",
                            mode: "relay-token",
                            reason: "registration-in-flight",
                            token: token,
                            groupId: groupId,
                            relayURL: url)
            return
        }
        inFlightPushToStartRegistrationKey = registrationKey

        Task { [weak self] in
            do {
                try await RelayClient.registerPushToStart(
                    baseURL: url,
                    groupId: groupId,
                    token: token,
                    clientId: SharedStorage.liveActivityRelayClientID,
                    speakerName: target.speakerName,
                    liveActivityStyleRaw: liveActivityStyleRaw,
                    activeActivityIds: activeActivityIds,
                    clearDismissalSuppression: clearDismissalSuppression
                )
                await MainActor.run {
                    if self?.inFlightPushToStartRegistrationKey == registrationKey {
                        self?.inFlightPushToStartRegistrationKey = nil
                    }
                    guard SharedStorage.liveActivityPushToStartToken == token,
                          RelayManager.shared.url?.absoluteString == relayURLString else {
                        self?.logLiveActivity(action: "register-push-to-start-stale-success",
                                              mode: "relay-token",
                                              reason: "target-changed",
                                              token: token,
                                              groupId: groupId,
                                              relayURL: url)
                        return
                    }
                    let registeredAt = Date()
                    SharedStorage.setLiveActivityPushToStartRegistration(
                        .init(
                            token: token,
                            relayURLString: relayURLString,
                            registeredAt: registeredAt
                        ),
                        for: groupId
                    )
                    if self?.liveActivityGroupId() == groupId {
                        SharedStorage.liveActivityPushToStartRegisteredToken = token
                        SharedStorage.liveActivityPushToStartRegisteredGroupID = groupId
                        SharedStorage.liveActivityPushToStartRegisteredRelayURLString = relayURLString
                        SharedStorage.liveActivityPushToStartRegisteredAt = registeredAt
                    }
                    self?.logLiveActivity(action: "register-push-to-start-success",
                                          mode: "relay-token",
                                          token: token,
                                          groupId: groupId,
                                          relayURL: url,
                                          extra: [
                                            "reason=\(Self.liveActivityLogValue(reason))",
                                            "activeActivityCount=\(activeActivityIds.count)",
                                            "clearDismissalSuppression=\(clearDismissalSuppression)"
                                          ])
                }
            } catch {
                await MainActor.run {
                    if self?.inFlightPushToStartRegistrationKey == registrationKey {
                        self?.inFlightPushToStartRegistrationKey = nil
                    }
                    self?.logLiveActivity(action: "register-push-to-start-failed",
                                          mode: "relay-token",
                                          reason: error.localizedDescription,
                                          token: token,
                                          groupId: groupId,
                                          relayURL: url)
                }
            }
        }
    }

    func attachLiveActivityIfNeeded(
        _ activity: Activity<SonosActivityAttributes>,
        reason: String
    ) {
        let groupId = activity.attributes.groupId ?? liveActivityGroupId() ?? activity.attributes.speakerName
        if remoteLiveActivitiesByGroupID[groupId]?.id == activity.id {
            return
        }

        cancelManualLiveActivityResumeFallback(groupId: groupId, reason: "remote-activity-attach")
        replaceRemoteLiveActivityForGroup(groupId, with: activity)
        remoteLiveActivitiesByGroupID[groupId] = activity
        let selectedGroupId = liveActivityGroupId()
        if selectedGroupId == groupId || (selectedGroupId == nil && currentActivity == nil) {
            currentActivity = activity
            currentActivityUsesRelay = true
        }
        liveActivityRelayWriterReady = false
        logLiveActivity(action: "remote-activity-attach",
                        activityID: activity.id,
                        mode: "relay-token",
                        state: activity.content.state,
                        groupId: groupId,
                        extra: ["reason=\(Self.liveActivityLogValue(reason))"])
        spawnPushTokenObserver(
            activity: activity,
            speakerName: activity.attributes.speakerName
        )
        spawnActivityStateObserver(
            activity: activity,
            groupId: groupId,
            usesRelay: true
        )
    }

    func replaceRemoteLiveActivityForGroup(
        _ groupId: String,
        with newActivity: Activity<SonosActivityAttributes>
    ) {
        guard let previousActivity = remoteLiveActivitiesByGroupID[groupId],
              previousActivity.id != newActivity.id else { return }

        pushTokenTasksByActivityID[previousActivity.id]?.cancel()
        pushTokenTasksByActivityID[previousActivity.id] = nil
        activityStateTasksByActivityID[previousActivity.id]?.cancel()
        activityStateTasksByActivityID[previousActivity.id] = nil
        let tokenToUnregister = registeredPushTokensByActivityID[previousActivity.id]
        registeredPushTokensByActivityID[previousActivity.id] = nil
        SharedStorage.setLiveActivityRelayPushToken(nil, for: groupId)
        if currentActivity?.id == previousActivity.id {
            currentActivity = nil
            currentActivityUsesRelay = false
            lastRegisteredPushToken = nil
            SharedStorage.liveActivityRelayPushToken = nil
        }
        logLiveActivity(action: "remote-activity-replace",
                        activityID: previousActivity.id,
                        mode: currentActivityUsesRelay ? "relay-token" : "local",
                        token: tokenToUnregister,
                        groupId: groupId,
                        extra: ["newActivity=\(Self.shortLiveActivityIdentifier(newActivity.id))"])
        Task { await previousActivity.end(nil, dismissalPolicy: .immediate) }
        if let token = tokenToUnregister, let url = RelayManager.shared.url {
            logLiveActivity(action: "unregister-token-request",
                            activityID: previousActivity.id,
                            token: token,
                            relayURL: url)
            Task { try? await RelayClient.unregisterActivity(baseURL: url, token: token) }
        }
    }

    /// Drains `Activity.pushTokenUpdates` and POSTs each rotation to the
    /// relay so the NAS knows where to deliver Live Activity pushes for the
    /// current Sonos coordinator. Tokens roll over occasionally; we resend
    /// every time the sequence yields rather than caching aggressively.
    func spawnPushTokenObserver(activity: Activity<SonosActivityAttributes>,
                                        speakerName: String) {
        pushTokenTasksByActivityID[activity.id]?.cancel()
        let groupId = activity.attributes.groupId ?? liveActivityGroupId() ?? speakerName
        logLiveActivity(action: "push-token-observer-start", activityID: activity.id,
                        mode: "relay-token", groupId: groupId)
        let task = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                guard let url = await RelayManager.shared.url else {
                    await MainActor.run {
                        if self?.currentActivity?.id == activity.id {
                            self?.liveActivityRelayWriterReady = false
                        }
                        self?.logLiveActivity(action: "register-token-skip", activityID: activity.id,
                                              mode: "relay-token", reason: "missing-relay-url",
                                              token: hex, groupId: groupId)
                    }
                    continue
                }
                await MainActor.run {
                    if self?.currentActivity?.id == activity.id {
                        self?.liveActivityRelayWriterReady = false
                    }
                    self?.logLiveActivity(action: "push-token-yield", activityID: activity.id,
                                          mode: "relay-token", token: hex,
                                          groupId: groupId, relayURL: url)
                }
                do {
                    let registration = try await RelayClient.registerActivity(
                        baseURL: url,
                        groupId: groupId,
                        token: hex,
                        clientId: SharedStorage.liveActivityRelayClientID,
                        activityId: activity.id,
                        speakerName: speakerName,
                        liveActivityStyleRaw: SharedStorage.liveActivityStyle.rawValue
                    )
                    if let initialState = registration.initialState {
                        await activity.update(
                            .init(state: initialState, staleDate: Self.liveActivityStaleDate())
                        )
                        await MainActor.run {
                            self?.logLiveActivity(action: "register-token-initial-state-applied",
                                                  activityID: activity.id,
                                                  mode: "relay-token",
                                                  state: initialState,
                                                  token: hex,
                                                  groupId: groupId,
                                                  relayURL: url)
                        }
                    }
                    await MainActor.run {
                        self?.registeredPushTokensByActivityID[activity.id] = hex
                        if self?.currentActivity?.id == activity.id {
                            self?.lastRegisteredPushToken = hex
                            SharedStorage.liveActivityRelayPushToken = hex
                            self?.liveActivityRelayWriterReady = true
                            self?.pushLiveActivityRelayPreferencesIfNeeded(force: true)
                        }
                        SharedStorage.setLiveActivityRelayPushToken(hex, for: groupId)
                        self?.logLiveActivity(action: "register-token-success",
                                              activityID: activity.id,
                                              mode: "relay-token", token: hex,
                                              groupId: groupId, relayURL: url)
                    }
                } catch {
                    await MainActor.run {
                        if self?.currentActivity?.id == activity.id {
                            self?.liveActivityRelayWriterReady = false
                        }
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
        pushTokenTasksByActivityID[activity.id] = task
    }

    func spawnActivityStateObserver(
        activity: Activity<SonosActivityAttributes>,
        groupId: String?,
        usesRelay: Bool
    ) {
        activityStateTasksByActivityID[activity.id]?.cancel()
        logLiveActivity(action: "state-observer-start",
                        activityID: activity.id,
                        mode: usesRelay ? "relay-token" : "local",
                        state: activity.content.state,
                        groupId: groupId)
        let task = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.handleLiveActivityStateUpdate(
                        state,
                        activity: activity,
                        groupId: groupId,
                        usesRelay: usesRelay
                    )
                }
                if state == .dismissed || state == .ended {
                    return
                }
            }
        }
        activityStateTasksByActivityID[activity.id] = task
    }

    func handleLiveActivityStateUpdate(
        _ state: ActivityState,
        activity: Activity<SonosActivityAttributes>,
        groupId: String?,
        usesRelay: Bool
    ) {
        logLiveActivity(action: "state-update",
                        activityID: activity.id,
                        mode: usesRelay ? "relay-token" : "local",
                        state: activity.content.state,
                        groupId: groupId,
                        extra: ["state=\(Self.liveActivityLogValue(String(describing: state)))"])

        switch state {
        case .dismissed:
            let token = registeredPushTokensByActivityID[activity.id]
                ?? groupId.flatMap { SharedStorage.liveActivityRelayPushTokensByGroupID[$0] }
                ?? (currentActivity?.id == activity.id ? lastRegisteredPushToken : nil)
            cleanupTerminalLiveActivity(activityID: activity.id, groupId: groupId)
            guard usesRelay,
                  let relayURL = RelayManager.shared.url,
                  let groupId else {
                return
            }
            postLiveActivityDismissal(
                relayURL: relayURL,
                groupId: groupId,
                activityID: activity.id,
                token: token
            )
        case .ended:
            let token = registeredPushTokensByActivityID[activity.id]
                ?? groupId.flatMap { SharedStorage.liveActivityRelayPushTokensByGroupID[$0] }
                ?? (currentActivity?.id == activity.id ? lastRegisteredPushToken : nil)
            cleanupTerminalLiveActivity(activityID: activity.id, groupId: groupId)
            guard usesRelay,
                  let token,
                  let relayURL = RelayManager.shared.url else {
                return
            }
            logLiveActivity(action: "unregister-token-request",
                            activityID: activity.id,
                            token: token,
                            relayURL: relayURL)
            Task { try? await RelayClient.unregisterActivity(baseURL: relayURL, token: token) }
        default:
            break
        }
    }

    func cleanupTerminalLiveActivity(activityID: String, groupId: String?) {
        if let groupId {
            remoteLiveActivitiesByGroupID[groupId] = nil
            SharedStorage.setLiveActivityRelayPushToken(nil, for: groupId)
        } else if let matching = remoteLiveActivitiesByGroupID.first(where: { $0.value.id == activityID }) {
            remoteLiveActivitiesByGroupID[matching.key] = nil
            SharedStorage.setLiveActivityRelayPushToken(nil, for: matching.key)
        }
        pushTokenTasksByActivityID[activityID]?.cancel()
        pushTokenTasksByActivityID[activityID] = nil
        activityStateTasksByActivityID[activityID]?.cancel()
        activityStateTasksByActivityID[activityID] = nil
        registeredPushTokensByActivityID[activityID] = nil

        guard currentActivity?.id == activityID else { return }
        currentActivity = liveActivityGroupId().flatMap { remoteLiveActivitiesByGroupID[$0] }
        currentActivityUsesRelay = currentActivity != nil
        liveActivityRelayWriterReady = false
        lastLiveActivityRelayPreferencesSignature = nil
        lastRegisteredPushToken = currentActivity.flatMap {
            registeredPushTokensByActivityID[$0.id]
        }
        SharedStorage.liveActivityRelayPushToken = liveActivityGroupId().flatMap {
            SharedStorage.liveActivityRelayPushTokensByGroupID[$0]
        }
        liveActivityRelayWriterReady = SharedStorage.liveActivityRelayPushToken != nil
    }

    func postLiveActivityDismissal(
        relayURL: URL,
        groupId: String,
        activityID: String,
        token: String?
    ) {
        let body = RelayClient.LiveActivityDismissalBody(
            groupId: groupId,
            clientId: SharedStorage.liveActivityRelayClientID,
            activityId: activityID,
            token: token,
            suppressForSeconds: Self.liveActivityDismissSuppressForSeconds
        )
        logLiveActivity(action: "dismissed-request",
                        activityID: activityID,
                        mode: "relay-token",
                        token: token,
                        groupId: groupId,
                        relayURL: relayURL)
        Task { [weak self] in
            do {
                try await RelayClient.postLiveActivityDismissal(baseURL: relayURL, body: body)
            } catch {
                await MainActor.run {
                    self?.logLiveActivity(action: "dismissed-request-failed",
                                          activityID: activityID,
                                          mode: "relay-token",
                                          reason: error.localizedDescription,
                                          token: token,
                                          groupId: groupId,
                                          relayURL: relayURL)
                }
            }
        }
    }

    /// Stable cross-process identifier for "this group of speakers". Matches
    /// what the relay's `SonosBridge` keys snapshots on (`device.Host`), so
    /// the relay can find the right token list when an event lands.
}
