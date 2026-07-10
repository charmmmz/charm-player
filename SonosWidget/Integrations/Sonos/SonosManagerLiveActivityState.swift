import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    func stopLiveActivity() {
        // Only explicit user teardown or confirmed playback stop should call
        // this. Mode changes and relay availability changes must keep the
        // existing Activity alive and update it in place.
        let groupId = liveActivityGroupId()
        cancelManualLiveActivityResumeFallback(groupId: groupId, reason: "stop-live-activity")
        guard let activity = groupId.flatMap({ remoteLiveActivitiesByGroupID[$0] }) ?? currentActivity else {
            return
        }
        let tokenToUnregister = registeredPushTokensByActivityID[activity.id]
            ?? SharedStorage.liveActivityRelayPushToken(for: groupId)
            ?? lastRegisteredPushToken
        cleanupTerminalLiveActivity(activityID: activity.id, groupId: groupId)
        logLiveActivity(action: "end", activityID: activity.id,
                        mode: "local-or-relay", token: tokenToUnregister,
                        groupId: groupId)
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        if let token = tokenToUnregister, let url = RelayManager.shared.url {
            logLiveActivity(action: "unregister-token-request", activityID: activity.id,
                            token: token, relayURL: url)
            Task { try? await RelayClient.unregisterActivity(baseURL: url, token: token) }
        }
    }

    func makeActivityState() -> SonosActivityAttributes.ContentState {
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
        let title = trackInfo?.title ?? "Not Playing"
        let artist = trackInfo?.artist ?? "—"
        let album = trackInfo?.album ?? ""
        let sourceRaw = source?.rawValue
        return .init(
            trackTitle: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            dominantColorHex: SharedStorage.cachedDominantColorHex,
            startedAt: startedAt,
            endsAt: endsAt,
            albumArtThumbnail: thumbnail,
            artworkTraceId: Self.localArtworkTraceId(
                trackTitle: title,
                artist: artist,
                album: album,
                sourceRaw: sourceRaw,
                thumbnailBytes: thumbnail?.count ?? 0
            ),
            groupMemberCount: currentGroupMembers.filter { !$0.isInvisible }.count,
            playbackSourceRaw: sourceRaw,
            soundbarNightMode: isTVSource ? nightMode : nil,
            soundbarSpeechEnhancementRawLevel: isTVSource ? speechEnhancement.rawValue : nil,
            liveActivityStyleRaw: SharedStorage.liveActivityStyle.rawValue,
            audioQualityLabel: SharedStorage.cachedAudioQualityLabel
        )
    }

    static func localArtworkTraceId(
        trackTitle: String,
        artist: String,
        album: String,
        sourceRaw: String?,
        thumbnailBytes: Int
    ) -> String {
        let raw = [
            trackTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            sourceRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            String(thumbnailBytes)
        ].joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "local_%016llx", hash)
    }

}
