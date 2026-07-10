import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    func liveActivityGroupId() -> String? {
        selectedSpeaker?.playbackIP
    }

    func sendRelaySoundbarNightModeCommand(
        _ enabled: Bool,
        fallbackGroupId: String
    ) async -> RelayClient.RelayPlaybackState? {
        await sendRelayLiveActivityCommand(
            "setSoundbarNightMode",
            fallbackGroupId: fallbackGroupId,
            nightMode: enabled
        )
    }

    func sendRelaySoundbarSpeechEnhancementCommand(
        _ level: SpeechEnhancementLevel,
        fallbackGroupId: String
    ) async -> RelayClient.RelayPlaybackState? {
        await sendRelayLiveActivityCommand(
            "setSoundbarSpeechEnhancement",
            fallbackGroupId: fallbackGroupId,
            speechEnhancementRawLevel: level.rawValue
        )
    }

    func sendRelayLiveActivityCommand(
        _ command: String,
        fallbackGroupId: String,
        nightMode: Bool? = nil,
        speechEnhancementRawLevel: Int? = nil
    ) async -> RelayClient.RelayPlaybackState? {
        guard let route = RelayClient.liveActivityCommandRoute(
            relayURLString: SharedStorage.relayURLString,
            relayPushToken: SharedStorage.liveActivityRelayPushToken(for: liveActivityGroupId()),
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

    func applyRelaySoundbarState(_ state: RelayClient.RelayPlaybackState) {
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

    func pushLiveActivityRelayPreferencesIfNeeded(
        force: Bool = false,
        resumeLiveActivity: Bool = false
    ) {
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
            liveActivityStyleRaw: SharedStorage.liveActivityStyle.rawValue,
            selectedGroupId: groupId,
            clientId: resumeLiveActivity ? SharedStorage.liveActivityRelayClientID : nil,
            resumeLiveActivity: resumeLiveActivity ? true : nil
        )
        let signature = [
            body.groupId,
            body.liveActivityStyleRaw ?? "",
            body.selectedGroupId ?? "",
            body.clientId ?? "",
            body.resumeLiveActivity == true ? "resume" : ""
        ].joined(separator: "\u{1F}")

        guard force || signature != lastLiveActivityRelayPreferencesSignature else {
            logLiveActivity(action: "preferences-skip",
                            mode: "relay-token",
                            reason: "duplicate-signature",
                            groupId: groupId,
                            relayURL: url,
                            extra: [
                                "style=\(body.liveActivityStyleRaw ?? "nil")",
                                "selectedGroupId=\(Self.liveActivityLogValue(body.selectedGroupId ?? "nil"))",
                                "resumeLiveActivity=\(body.resumeLiveActivity == true)"
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
                            "style=\(body.liveActivityStyleRaw ?? "nil")",
                            "selectedGroupId=\(Self.liveActivityLogValue(body.selectedGroupId ?? "nil"))",
                            "resumeLiveActivity=\(body.resumeLiveActivity == true)"
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
                                            "style=\(body.liveActivityStyleRaw ?? "nil")",
                                            "selectedGroupId=\(Self.liveActivityLogValue(body.selectedGroupId ?? "nil"))",
                                            "resumeLiveActivity=\(body.resumeLiveActivity == true)"
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

    nonisolated static func cleanLiveActivityHintString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}
