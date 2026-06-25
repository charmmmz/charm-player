import AppIntents
import ActivityKit
import WidgetKit
import Foundation

// MARK: - Playback Intents

struct PlayPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Playback"
    static var description: IntentDescription = "Play or pause the current Sonos speaker."

    @Parameter(title: "Group ID")
    var groupId: String?

    init() {
        self.groupId = nil
    }

    init(groupId: String?) {
        self.groupId = groupId
    }

    func perform() async throws -> some IntentResult {
        guard let ip = IntentHelper.targetPlaybackIP(groupId: groupId) else { return .result() }

        let state = try? await SonosAPI.getTransportInfo(ip: ip)
        let shouldPause = state == .playing || (state == nil && SharedStorage.isPlaying)
        do {
            if shouldPause {
                try await SonosAPI.pause(ip: ip)
                SharedStorage.isPlaying = false
            } else {
                try await SonosAPI.play(ip: ip)
                SharedStorage.isPlaying = true
            }
        } catch {
            if let relayState = await IntentHelper.sendRelayPlaybackCommand(
                shouldPause ? "pause" : "play",
                fallbackGroupId: ip,
                groupId: groupId
            ) {
                await IntentHelper.applyRelayPlaybackState(relayState)
            } else {
                return .result()
            }
        }

        // Lock play state for 5s so fetchLiveEntry won't overwrite our optimistic update
        // with a potentially stale device response.
        SharedStorage.playStateLockUntil = Date().addingTimeInterval(5)
        await IntentHelper.updateLiveActivityPlayState(isPlaying: SharedStorage.isPlaying, groupId: groupId)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

struct NextTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description: IntentDescription = "Skip to the next track."

    @Parameter(title: "Group ID")
    var groupId: String?

    init() {
        self.groupId = nil
    }

    init(groupId: String?) {
        self.groupId = groupId
    }

    func perform() async throws -> some IntentResult {
        guard let ip = IntentHelper.targetPlaybackIP(groupId: groupId) else { return .result() }
        let previousTrack = IntentHelper.cachedTrackIdentity()

        if let relayState = await IntentHelper.sendRelayPlaybackCommand(
            "next",
            fallbackGroupId: ip,
            groupId: groupId
        ) {
            SharedStorage.playStateLockUntil = Date().addingTimeInterval(8)
            await IntentHelper.applyRelayPlaybackState(relayState)
            WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
            return .result()
        }

        do {
            try await SonosAPI.next(ip: ip)
        } catch {
            return .result()
        }

        // Lock the current play state during track transition so the widget doesn't
        // flicker while the device is in TRANSITIONING state.
        SharedStorage.playStateLockUntil = Date().addingTimeInterval(8)
        let info = await IntentHelper.refreshCacheAfterTrackCommand(
            playbackIP: ip,
            previousTrack: previousTrack)
        await IntentHelper.updateLiveActivityPlaybackState(trackInfo: info, isPlaying: true, groupId: groupId)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

struct PreviousTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description: IntentDescription = "Go back to the previous track."

    @Parameter(title: "Group ID")
    var groupId: String?

    init() {
        self.groupId = nil
    }

    init(groupId: String?) {
        self.groupId = groupId
    }

    func perform() async throws -> some IntentResult {
        guard let ip = IntentHelper.targetPlaybackIP(groupId: groupId) else { return .result() }
        let previousTrack = IntentHelper.cachedTrackIdentity()

        if let relayState = await IntentHelper.sendRelayPlaybackCommand(
            "previous",
            fallbackGroupId: ip,
            groupId: groupId
        ) {
            SharedStorage.playStateLockUntil = Date().addingTimeInterval(8)
            await IntentHelper.applyRelayPlaybackState(relayState)
            WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
            return .result()
        }

        do {
            try await SonosAPI.previous(ip: ip)
        } catch {
            return .result()
        }

        SharedStorage.playStateLockUntil = Date().addingTimeInterval(8)
        let info = await IntentHelper.refreshCacheAfterTrackCommand(
            playbackIP: ip,
            previousTrack: previousTrack)
        await IntentHelper.updateLiveActivityPlaybackState(trackInfo: info, isPlaying: true, groupId: groupId)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

// MARK: - TV Soundbar Intents

struct ToggleNightModeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Night Sound"
    static var description: IntentDescription = "Turn Sonos Night Sound on or off for TV audio."

    @Parameter(title: "Group ID")
    var groupId: String?

    init() {
        self.groupId = nil
    }

    init(groupId: String?) {
        self.groupId = groupId
    }

    func perform() async throws -> some IntentResult {
        guard let ip = IntentHelper.targetPlaybackIP(groupId: groupId) else { return .result() }
        let previousValue = SharedStorage.cachedSoundbarNightMode
        let nextValue = !SharedStorage.cachedSoundbarNightMode
        SharedStorage.cachedSoundbarNightMode = nextValue
        await IntentHelper.updateLiveActivitySoundbarState(nightMode: nextValue, groupId: groupId)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")

        if IntentHelper.hasRelayCommandRoute(fallbackGroupId: ip, groupId: groupId) {
            if let relayState = await IntentHelper.sendRelaySoundbarNightModeCommand(
                nextValue,
                fallbackGroupId: ip,
                groupId: groupId
            ) {
                await IntentHelper.applyRelayPlaybackState(relayState)
            } else {
                SharedStorage.cachedSoundbarNightMode = previousValue
                await IntentHelper.updateLiveActivitySoundbarState(nightMode: previousValue, groupId: groupId)
                WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
            }
            return .result()
        }

        do {
            try await SonosAPI.setEQ(ip: ip, eqType: "NightMode", enabled: nextValue)
        } catch {
            SharedStorage.cachedSoundbarNightMode = previousValue
            await IntentHelper.updateLiveActivitySoundbarState(nightMode: previousValue, groupId: groupId)
            WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        }

        return .result()
    }
}

struct ToggleSpeechEnhancementIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Speech Enhancement"
    static var description: IntentDescription = "Turn Sonos Speech Enhancement on or off for TV audio."

    @Parameter(title: "Group ID")
    var groupId: String?

    init() {
        self.groupId = nil
    }

    init(groupId: String?) {
        self.groupId = groupId
    }

    func perform() async throws -> some IntentResult {
        guard let ip = IntentHelper.targetPlaybackIP(groupId: groupId) else { return .result() }
        let currentLevel = SpeechEnhancementLevel.from(
            rawLevel: SharedStorage.cachedSoundbarSpeechEnhancementRawLevel)
        let nextLevel = currentLevel.nextCyclicLevel
        SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = nextLevel.rawValue
        await IntentHelper.updateLiveActivitySoundbarState(speechEnhancement: nextLevel, groupId: groupId)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")

        if IntentHelper.hasRelayCommandRoute(fallbackGroupId: ip, groupId: groupId) {
            if let relayState = await IntentHelper.sendRelaySoundbarSpeechEnhancementCommand(
                nextLevel,
                fallbackGroupId: ip,
                groupId: groupId
            ) {
                await IntentHelper.applyRelayPlaybackState(relayState)
            } else {
                SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = currentLevel.rawValue
                await IntentHelper.updateLiveActivitySoundbarState(speechEnhancement: currentLevel, groupId: groupId)
                WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
            }
            return .result()
        }

        do {
            switch nextLevel {
            case .off:
                _ = try? await SonosAPI.setEQ(
                    ip: ip,
                    eqType: "SpeechEnhanceEnabled",
                    enabled: false)
                try await SonosAPI.setEQLevel(ip: ip, eqType: "DialogLevel", level: 0)
            case .low, .medium, .high, .max:
                try await SonosAPI.setEQLevel(
                    ip: ip,
                    eqType: "DialogLevel",
                    level: nextLevel.rawValue)
                _ = try? await SonosAPI.setEQ(
                    ip: ip,
                    eqType: "SpeechEnhanceEnabled",
                    enabled: true)
            }
        } catch {
            SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = currentLevel.rawValue
            await IntentHelper.updateLiveActivitySoundbarState(speechEnhancement: currentLevel, groupId: groupId)
            WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        }

        return .result()
    }
}

// MARK: - Volume Intents

struct VolumeUpIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Volume Up"
    static var description: IntentDescription = "Increase volume by 2."

    @Parameter(title: "Group ID")
    var groupId: String?

    init() {
        self.groupId = nil
    }

    init(groupId: String?) {
        self.groupId = groupId
    }

    func perform() async throws -> some IntentResult {
        guard let ip = IntentHelper.targetPlaybackIP(groupId: groupId) else { return .result() }
        let current: Int
        if let groupVolume = try? await SonosAPI.getGroupVolume(ip: ip) {
            current = groupVolume
        } else if let speakerVolume = try? await SonosAPI.getVolume(ip: ip) {
            current = speakerVolume
        } else {
            current = SharedStorage.cachedVolume
        }
        let newVol = min(100, current + 2)
        do {
            try await SonosAPI.setGroupVolume(ip: ip, volume: newVol)
        } catch {
            try? await SonosAPI.setVolume(ip: ip, volume: newVol)
        }
        SharedStorage.cachedVolume = newVol
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

struct VolumeDownIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Volume Down"
    static var description: IntentDescription = "Decrease volume by 2."

    @Parameter(title: "Group ID")
    var groupId: String?

    init() {
        self.groupId = nil
    }

    init(groupId: String?) {
        self.groupId = groupId
    }

    func perform() async throws -> some IntentResult {
        guard let ip = IntentHelper.targetPlaybackIP(groupId: groupId) else { return .result() }
        let current: Int
        if let groupVolume = try? await SonosAPI.getGroupVolume(ip: ip) {
            current = groupVolume
        } else if let speakerVolume = try? await SonosAPI.getVolume(ip: ip) {
            current = speakerVolume
        } else {
            current = SharedStorage.cachedVolume
        }
        let newVol = max(0, current - 2)
        do {
            try await SonosAPI.setGroupVolume(ip: ip, volume: newVol)
        } catch {
            try? await SonosAPI.setVolume(ip: ip, volume: newVol)
        }
        SharedStorage.cachedVolume = newVol
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

// MARK: - Shared Helper

enum IntentHelper {
    struct TrackIdentity: Equatable {
        let title: String
        let artist: String
        let album: String

        init(title: String?, artist: String?, album: String?) {
            self.title = Self.normalized(title)
            self.artist = Self.normalized(artist)
            self.album = Self.normalized(album)
        }

        init(trackInfo: TrackInfo) {
            self.init(title: trackInfo.title, artist: trackInfo.artist, album: trackInfo.album)
        }

        func matches(_ trackInfo: TrackInfo) -> Bool {
            self == TrackIdentity(trackInfo: trackInfo)
        }

        private static func normalized(_ value: String?) -> String {
            value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
        }
    }

    static func cachedTrackIdentity() -> TrackIdentity {
        TrackIdentity(
            title: SharedStorage.cachedTrackTitle,
            artist: SharedStorage.cachedArtist,
            album: SharedStorage.cachedAlbum)
    }

    static func targetPlaybackIP(groupId: String?) -> String? {
        let cleanGroupId = groupId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanGroupId.isEmpty {
            return cleanGroupId
        }
        return SharedStorage.coordinatorIP ?? SharedStorage.speakerIP
    }

    @discardableResult
    static func refreshCache(playbackIP ip: String) async -> TrackInfo? {
        guard let info = try? await SonosAPI.getPositionInfo(ip: ip) else {
            return nil
        }

        let cachedAlbumArtDataURL = SharedStorage.cachedAlbumArtDataURL
        let cachedAlbumArtData = AlbumArtSharedCacheRecoveryPolicy.reusableArtworkData(
            currentURLString: info.albumArtURL,
            cachedDataURLString: cachedAlbumArtDataURL,
            cachedData: SharedStorage.albumArtData
        )
        SharedStorage.cachedTrackTitle = info.title
        SharedStorage.cachedArtist = info.artist
        SharedStorage.cachedAlbum = info.album
        SharedStorage.cachedAlbumArtURL = info.albumArtURL
        SharedStorage.cachedAudioQualityLabel = info.audioQuality?.label
            ?? info.tvFormat?.geekLabel
        SharedStorage.cachedPlaybackSource = info.source.rawValue
        SharedStorage.cachedIsLiveStream = info.isLiveStream
        if info.source == .tv {
            await refreshSoundbarEQ(playbackIP: ip)
        }

        if CachedArtworkFetchPolicy.shouldFetch(
            incomingURLString: info.albumArtURL,
            cachedURLString: cachedAlbumArtDataURL,
            hasCachedData: cachedAlbumArtData != nil
        ),
           let urlStr = info.albumArtURL,
           let data = await fetchArtworkData(urlString: urlStr) {
            SharedStorage.albumArtData = data
            SharedStorage.cachedAlbumArtDataURL = urlStr
        }

        return info
    }

    private static func fetchArtworkData(urlString: String) async -> Data? {
        let trimmedRelayURL = SharedStorage.relayURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let relayBaseURL = URL(string: trimmedRelayURL),
           let data = try? await RelayClient.fetchArtwork(
            baseURL: relayBaseURL,
            sourceURLString: urlString
           ) {
            return data
        }

        guard let url = URL(string: urlString),
              let (data, _) = try? await noProxySession.data(from: url) else {
            return nil
        }
        return data
    }

    static func refreshCacheAfterTrackCommand(
        playbackIP ip: String,
        previousTrack: TrackIdentity
    ) async -> TrackInfo? {
        let delays: [Duration] = [
            .milliseconds(800),
            .milliseconds(900),
            .milliseconds(1_200)
        ]
        var latestInfo: TrackInfo?

        for delay in delays {
            try? await Task.sleep(for: delay)
            guard let info = await refreshCache(playbackIP: ip) else { continue }
            latestInfo = info
            if !previousTrack.matches(info) {
                return info
            }
        }

        return latestInfo
    }

    static func refreshSoundbarEQ(playbackIP ip: String) async {
        guard let eq = try? await SonosAPI.getSoundbarEQ(ip: ip) else { return }

        let level: SpeechEnhancementLevel
        if eq.speechEnabled, eq.dialogLevel > 0 {
            level = SpeechEnhancementLevel.from(rawLevel: eq.dialogLevel)
        } else {
            level = .off
        }

        SharedStorage.cachedSoundbarNightMode = eq.night
        SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = level.rawValue
        await updateLiveActivitySoundbarState(
            nightMode: eq.night,
            speechEnhancement: level)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
    }

    static func sendRelayPlaybackCommand(
        _ command: String,
        fallbackGroupId: String,
        groupId: String? = nil,
        volume: Int? = nil,
        nightMode: Bool? = nil,
        speechEnhancementRawLevel: Int? = nil
    ) async -> RelayClient.RelayPlaybackState? {
        guard let route = relayCommandRoute(fallbackGroupId: fallbackGroupId, groupId: groupId) else {
            return nil
        }
        return try? await RelayClient.sendLiveActivityCommand(
            baseURL: route.baseURL,
            groupId: route.groupId,
            token: route.token,
            command: command,
            volume: volume,
            nightMode: nightMode,
            speechEnhancementRawLevel: speechEnhancementRawLevel
        )
    }

    static func hasRelayCommandRoute(fallbackGroupId: String, groupId: String? = nil) -> Bool {
        relayCommandRoute(fallbackGroupId: fallbackGroupId, groupId: groupId) != nil
    }

    private static func relayCommandRoute(
        fallbackGroupId: String,
        groupId explicitGroupId: String? = nil
    ) -> RelayClient.LiveActivityCommandRoute? {
        let fallback = fallbackGroupId.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = explicitGroupId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let routeGroupId = explicit.isEmpty ? fallback : explicit
        let token = explicit.isEmpty
            ? SharedStorage.liveActivityRelayPushToken(for: routeGroupId)
            : SharedStorage.liveActivityRelayPushTokensByGroupID[routeGroupId]
        return RelayClient.liveActivityCommandRoute(
            relayURLString: SharedStorage.relayURLString,
            relayPushToken: token,
            coordinatorIP: routeGroupId,
            fallbackGroupId: routeGroupId
        )
    }

    static func sendRelaySoundbarNightModeCommand(
        _ enabled: Bool,
        fallbackGroupId: String,
        groupId: String? = nil
    ) async -> RelayClient.RelayPlaybackState? {
        await sendRelayPlaybackCommand(
            "setSoundbarNightMode",
            fallbackGroupId: fallbackGroupId,
            groupId: groupId,
            nightMode: enabled)
    }

    static func sendRelaySoundbarSpeechEnhancementCommand(
        _ level: SpeechEnhancementLevel,
        fallbackGroupId: String,
        groupId: String? = nil
    ) async -> RelayClient.RelayPlaybackState? {
        await sendRelayPlaybackCommand(
            "setSoundbarSpeechEnhancement",
            fallbackGroupId: fallbackGroupId,
            groupId: groupId,
            speechEnhancementRawLevel: level.rawValue)
    }

    static func applyRelayPlaybackState(_ state: RelayClient.RelayPlaybackState) async {
        let info = state.trackInfo
        SharedStorage.cachedTrackTitle = info.title
        SharedStorage.cachedArtist = info.artist
        SharedStorage.cachedAlbum = info.album
        SharedStorage.cachedAlbumArtURL = info.albumArtURL
        SharedStorage.cachedAudioQualityLabel = state.audioQualityLabel
        SharedStorage.cachedPlaybackSource = info.source.rawValue
        SharedStorage.cachedIsLiveStream = info.isLiveStream
        SharedStorage.cachedGroupMemberCount = state.groupMemberCount
        SharedStorage.isPlaying = state.isPlaying
        if let nightMode = state.soundbarNightMode {
            SharedStorage.cachedSoundbarNightMode = nightMode
        }
        if let rawLevel = state.soundbarSpeechEnhancementRawLevel {
            SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = rawLevel
        }
        await updateLiveActivityPlaybackState(
            trackInfo: info,
            isPlaying: state.isPlaying,
            groupId: state.groupId,
            audioQualityLabel: state.audioQualityLabel,
            groupMemberCount: state.groupMemberCount,
            soundbarNightMode: state.soundbarNightMode,
            soundbarSpeechEnhancementRawLevel: state.soundbarSpeechEnhancementRawLevel)
    }

    static func updateLiveActivityPlaybackState(
        trackInfo: TrackInfo?,
        isPlaying: Bool,
        groupId: String? = nil,
        audioQualityLabel: String? = nil,
        groupMemberCount: Int? = nil,
        soundbarNightMode: Bool? = nil,
        soundbarSpeechEnhancementRawLevel: Int? = nil
    ) async {
        guard let trackInfo else { return }

        for activity in Activity<SonosActivityAttributes>.activities {
            guard liveActivity(activity, matches: groupId) else { continue }
            var state = LiveActivityPlaybackStateBuilder.replacing(
                activity.content.state,
                with: trackInfo,
                isPlaying: isPlaying,
                dominantColorHex: SharedStorage.cachedDominantColorHex,
                liveActivityStyleRaw: SharedStorage.liveActivityStyle.rawValue)
            if let groupMemberCount {
                state.groupMemberCount = groupMemberCount
            }
            if let audioQualityLabel {
                state.audioQualityLabel = audioQualityLabel
            }
            if trackInfo.source == .tv {
                if let soundbarNightMode {
                    state.soundbarNightMode = soundbarNightMode
                }
                if let soundbarSpeechEnhancementRawLevel {
                    state.soundbarSpeechEnhancementRawLevel = SpeechEnhancementLevel.from(
                        rawLevel: soundbarSpeechEnhancementRawLevel
                    ).rawValue
                }
            }

            await activity.update(
                ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(60 * 60)))
        }
    }

    static func updateLiveActivityPlayState(isPlaying: Bool, groupId: String? = nil) async {
        let now = Date()

        for activity in Activity<SonosActivityAttributes>.activities {
            guard liveActivity(activity, matches: groupId) else { continue }
            var state = activity.content.state
            let currentPosition: Double
            if let startedAt = state.startedAt, state.durationSeconds > 0 {
                currentPosition = min(
                    max(now.timeIntervalSince(startedAt), 0),
                    state.durationSeconds)
            } else {
                currentPosition = state.positionSeconds
            }

            state.isPlaying = isPlaying
            state.positionSeconds = currentPosition
            state.startedAt = isPlaying && state.durationSeconds > 0
                ? now.addingTimeInterval(-currentPosition)
                : nil
            state.endsAt = isPlaying && state.durationSeconds > 0
                ? now.addingTimeInterval(state.durationSeconds - currentPosition)
                : nil

            await activity.update(
                ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(60 * 60)))
        }
    }

    static func updateLiveActivitySoundbarState(
        nightMode: Bool? = nil,
        speechEnhancement: SpeechEnhancementLevel? = nil,
        groupId: String? = nil
    ) async {
        for activity in Activity<SonosActivityAttributes>.activities {
            guard liveActivity(activity, matches: groupId) else { continue }
            let oldState = activity.content.state
            let state = oldState.applyingSoundbarLiveActivityUpdate(
                nightMode: nightMode,
                speechEnhancement: speechEnhancement)
            guard state != oldState else { continue }

            await activity.update(
                ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(60 * 60)))
        }
    }

    private static func liveActivity(
        _ activity: Activity<SonosActivityAttributes>,
        matches groupId: String?
    ) -> Bool {
        let cleanGroupId = groupId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanGroupId.isEmpty else { return true }
        return activity.attributes.groupId == cleanGroupId
    }
}
