import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    // MARK: - Playback Controls

    func togglePlayPause() async {
        guard let backend = await controlBackendEnsured() else {
            errorMessage = SonosControlError.noBackend.localizedDescription
            return
        }
        let prev = transportState
        let wasPlaying = prev == .playing
        setCurrentTransportState(wasPlaying ? .paused : .playing)
        do {
            try await SonosControl.togglePlayPause(backend, currentlyPlaying: wasPlaying)
            try? await Task.sleep(for: .milliseconds(300))
            await refreshState()
        } catch {
            setCurrentTransportState(prev)
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
    func fallbackToCloudIfLANFailed(_ backend: SonosControl.Backend) async {
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
        setGroupTransportState(optimistic, forGroupID: groupID)
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
               state != .transitioning {
                setGroupTransportState(state, forGroupID: groupID)
            }
        } catch {
            setGroupTransportState(prev, forGroupID: groupID)
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

    /// Returns the in-memory cached image for a queue item URL.
    func queueMemoryImage(for urlStr: String) -> UIImage? {
        queueArtCache.object(forKey: urlStr as NSString)
    }

    /// Returns the cached image for a queue item URL, checking memory then disk.
    /// Avoid calling this from SwiftUI body; disk restore can decode image data.
    func queueImage(for urlStr: String) -> UIImage? {
        if let img = queueArtCache.object(forKey: urlStr as NSString) { return img }
        guard PlaybackArtworkCachingPolicy.isQueueDiskCacheEnabled else { return nil }
        return QueueArtDiskCache.shared.image(for: urlStr)
    }
}
