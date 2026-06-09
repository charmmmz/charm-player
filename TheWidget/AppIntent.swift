import AppIntents
import ActivityKit
import WidgetKit
import Foundation

// MARK: - Playback Intents

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Playback"
    static var description: IntentDescription = "Play or pause the current Sonos speaker."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }

        let state = try? await SonosAPI.getTransportInfo(ip: ip)
        if state == .playing {
            try? await SonosAPI.pause(ip: ip)
            SharedStorage.isPlaying = false
        } else {
            try? await SonosAPI.play(ip: ip)
            SharedStorage.isPlaying = true
        }

        // Lock play state for 5s so fetchLiveEntry won't overwrite our optimistic update
        // with a potentially stale device response.
        SharedStorage.playStateLockUntil = Date().addingTimeInterval(5)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description: IntentDescription = "Skip to the next track."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }
        try? await SonosAPI.next(ip: ip)
        // Lock the current play state during track transition so the widget doesn't
        // flicker while the device is in TRANSITIONING state.
        SharedStorage.playStateLockUntil = Date().addingTimeInterval(5)
        try? await Task.sleep(for: .milliseconds(800))
        await IntentHelper.refreshCache(playbackIP: ip)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description: IntentDescription = "Go back to the previous track."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }
        try? await SonosAPI.previous(ip: ip)
        SharedStorage.playStateLockUntil = Date().addingTimeInterval(5)
        try? await Task.sleep(for: .milliseconds(800))
        await IntentHelper.refreshCache(playbackIP: ip)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

// MARK: - TV Soundbar Intents

struct ToggleNightModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Night Sound"
    static var description: IntentDescription = "Turn Sonos Night Sound on or off for TV audio."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }
        let nextValue = !SharedStorage.cachedSoundbarNightMode

        do {
            try await SonosAPI.setEQ(ip: ip, eqType: "NightMode", enabled: nextValue)
            SharedStorage.cachedSoundbarNightMode = nextValue
            await IntentHelper.updateLiveActivitySoundbarState(nightMode: nextValue)
            WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        } catch {
            await IntentHelper.refreshSoundbarEQ(playbackIP: ip)
        }

        return .result()
    }
}

struct ToggleSpeechEnhancementIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Speech Enhancement"
    static var description: IntentDescription = "Turn Sonos Speech Enhancement on or off for TV audio."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }
        let currentLevel = SpeechEnhancementLevel.from(
            rawLevel: SharedStorage.cachedSoundbarSpeechEnhancementRawLevel)
        let nextLevel: SpeechEnhancementLevel = currentLevel.isOn ? .off : .low

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

            SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = nextLevel.rawValue
            await IntentHelper.updateLiveActivitySoundbarState(speechEnhancement: nextLevel)
            WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        } catch {
            await IntentHelper.refreshSoundbarEQ(playbackIP: ip)
        }

        return .result()
    }
}

// MARK: - Volume Intents

struct VolumeUpIntent: AppIntent {
    static var title: LocalizedStringResource = "Volume Up"
    static var description: IntentDescription = "Increase volume by 2."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }
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

struct VolumeDownIntent: AppIntent {
    static var title: LocalizedStringResource = "Volume Down"
    static var description: IntentDescription = "Decrease volume by 2."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }
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
    static func refreshCache(playbackIP ip: String) async {
        if let info = try? await SonosAPI.getPositionInfo(ip: ip) {
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

            if let urlStr = info.albumArtURL, let url = URL(string: urlStr),
               let (data, _) = try? await noProxySession.data(from: url) {
                SharedStorage.albumArtData = data
            }
        }
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

    static func updateLiveActivitySoundbarState(
        nightMode: Bool? = nil,
        speechEnhancement: SpeechEnhancementLevel? = nil
    ) async {
        for activity in Activity<SonosActivityAttributes>.activities {
            var state = activity.content.state
            guard state.isTVSource else { continue }

            if let nightMode {
                state.soundbarNightMode = nightMode
            }
            if let speechEnhancement {
                state.soundbarSpeechEnhancementRawLevel = speechEnhancement.rawValue
            }

            await activity.update(
                ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(60 * 60)))
        }
    }
}
