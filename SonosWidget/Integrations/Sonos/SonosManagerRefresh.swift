import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    // MARK: - State Refresh

    /// Drives both the LAN UPnP polling (fast, rich) and the Cloud Control
    /// API polling (slower, lighter) via `transportBackend`. `.unknown`
    /// triggers a probe first, then fills in whichever pipe succeeded.
    func refreshState() async {
        guard let expectedSpeakerID = selectedSpeaker?.id else { return }
        await refreshState(expectedSpeakerID: expectedSpeakerID)
    }

    func refreshState(expectedSpeakerID: String) async {
        guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }

        switch transportBackend {
        case .lan:
            await refreshStateLAN(expectedSpeakerID: expectedSpeakerID)
        case .cloud:
            await refreshStateCloud(expectedSpeakerID: expectedSpeakerID)
        case .unknown:
            _ = await probeBackend()
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            // After probe, route accordingly (one level of recursion max).
            if transportBackend == .lan { await refreshStateLAN(expectedSpeakerID: expectedSpeakerID) }
            else if transportBackend == .cloud { await refreshStateCloud(expectedSpeakerID: expectedSpeakerID) }
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

    func refreshLockedLANState(
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
            let localMetadata = await fetchLocalControlPlaybackMetadata(ip: ip)
            let incomingTrackInfo = Self.lanTrackInfo(
                positionInfo,
                localMetadata: localMetadata,
                cachedCloudQuality: cachedCloudQuality,
                cloudQualityIsAuthoritative: SonosAuth.shared.isLoggedIn
                    && isCloudQualityAuthoritative(positionInfo.source)
            )
            if localMetadata != nil {
                cacheAudioQualityIfPresent(incomingTrackInfo.audioQuality, for: incomingTrackInfo)
            }
            trackInfo = incomingTrackInfo
            await resolveCurrentAppleMusicArtworkIfNeeded()
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
                applyQueueResult(queueSnapshot)
            }

            consecutiveFailures = 0
            connectionState = .connected
            errorMessage = nil
            ensureEventSubscriptionsIfNeeded()
            updateSharedCache()
            managePositionTimer()
            manageLiveActivity()
            scheduleDelayedAudioQualityBadgeRetryIfNeeded(expectedSpeakerID: expectedSpeakerID)
            return selectedSpeaker?.id == expectedSpeakerID
        } catch {
            guard selectedSpeaker?.id == expectedSpeakerID else { return false }
            errorMessage = error.localizedDescription
            return true
        }
    }

    func refreshLockedCloudState(
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
            await resolveCurrentAppleMusicArtworkIfNeeded()

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
            scheduleDelayedAudioQualityBadgeRetryIfNeeded(expectedSpeakerID: expectedSpeakerID)
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

    func refreshStateLAN() async {
        guard let expectedSpeakerID = selectedSpeaker?.id else { return }
        await refreshStateLAN(expectedSpeakerID: expectedSpeakerID)
    }

    func refreshStateLAN(expectedSpeakerID: String) async {
        await lanRefreshGate.run { [weak self] in
            await self?.performRefreshStateLAN(expectedSpeakerID: expectedSpeakerID)
        }
    }

    /// RenderingControl events only change volume-related UI. Reading the
    /// complete transport, position, play mode, media URI, metadata, artwork,
    /// queue, and audio-quality state for every volume tick overloads Sonos
    /// during a slider gesture, so keep this path to one group-volume request.
    func refreshVolumeStateLAN(includeSoundbarEQ: Bool = false) async {
        guard let expectedSpeakerID = selectedSpeaker?.id else { return }
        await lanRefreshGate.run { [weak self] in
            await self?.performRefreshVolumeStateLAN(
                expectedSpeakerID: expectedSpeakerID,
                includeSoundbarEQ: includeSoundbarEQ
            )
        }
    }

    func performRefreshVolumeStateLAN(
        expectedSpeakerID: String,
        includeSoundbarEQ: Bool
    ) async {
        guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID),
              let playbackIP else { return }
        do {
            let groupVolume = try await SonosAPI.getGroupVolume(ip: playbackIP)
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            volume = groupVolume
            if let idx = currentGroupStatusIndex() {
                groupStatuses[idx].volume = groupVolume
            }
            connectionState = .connected
            consecutiveFailures = 0
            if includeSoundbarEQ, trackInfo?.source == .tv {
                await refreshSoundbarEQ()
                guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
                manageLiveActivity()
            }
            updateSharedCache()
            manageRemoteMediaSession()
        } catch {
            SonosLog.debug(.sonosEvents, "lightweight volume refresh failed: \(error)")
        }
    }

    func performRefreshStateLAN(expectedSpeakerID: String) async {
        guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
        guard let pIP = playbackIP else { return }
        do {
            async let t = SonosAPI.getTransportInfo(ip: pIP)
            async let p = SonosAPI.getPositionInfo(ip: pIP)
            async let v = SonosAPI.getGroupVolume(ip: pIP)
            async let m = SonosAPI.getPlayMode(ip: pIP)
            async let mediaURI = SonosAPI.getMediaInfo(ip: pIP)

            let incomingTransport = try await t
            // `getPositionInfo` already ran `PlaybackSource.from(trackURI:)`
            // which consults SharedStorage's sid → name map for services
            // whose local sid varies per install (NetEase etc.), so we no
            // longer need a manual second pass here.
            let positionInfo = try await p
            let groupVolume = try await v
            let mode = try await m
            let mediaURIValue = try? await mediaURI

            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }

            applyIncomingTransportState(incomingTransport)
            volume = groupVolume
            if let idx = currentGroupStatusIndex() {
                groupStatuses[idx].volume = groupVolume
            }
            // Soundbar TV-mode toggles only show up in the player UI when
            // source == .tv — fetching them off the music path would just
            // be wasted SOAP calls (and most non-soundbars 402 on it).
            if positionInfo.source == .tv {
                await refreshSoundbarEQ()
                guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            }
            isPlayingFromQueue = mediaURIValue?.hasPrefix("x-rincon-queue:") ?? true
            if Date() > playModeLockUntil {
                isShuffling = mode.shuffle
                repeatMode = mode.repeat
            }

            let localMetadata = await fetchLocalControlPlaybackMetadata(ip: pIP)
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            let incomingTrackInfo = Self.lanTrackInfo(
                positionInfo,
                localMetadata: localMetadata,
                cachedCloudQuality: cachedCloudQuality,
                cloudQualityIsAuthoritative: SonosAuth.shared.isLoggedIn
                    && isCloudQualityAuthoritative(positionInfo.source)
            )
            if localMetadata != nil {
                cacheAudioQualityIfPresent(incomingTrackInfo.audioQuality, for: incomingTrackInfo)
            }
            trackInfo = incomingTrackInfo
            await resolveCurrentAppleMusicArtworkIfNeeded()
            positionSeconds = incomingTrackInfo.positionSeconds
            durationSeconds = incomingTrackInfo.durationSeconds
            positionFetchedAt = Date()

            consecutiveFailures = 0
            connectionState = .connected
            errorMessage = nil
            ensureEventSubscriptionsIfNeeded()

            await enrichAudioQualityFromCloud(expectedSpeakerID: expectedSpeakerID)
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            syncCurrentGroupStatusFromPlaybackState()
            updateSharedCache()
            await loadAlbumArt()
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            MusicAmbienceManager.shared.receive(snapshot: musicAmbienceSnapshot())
            if queueLoaded { await loadQueue() }
            managePositionTimer()
            manageLiveActivity()
            scheduleDelayedAudioQualityBadgeRetryIfNeeded(expectedSpeakerID: expectedSpeakerID)
        } catch {
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
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
    func refreshStateCloud() async {
        guard let expectedSpeakerID = selectedSpeaker?.id else { return }
        await refreshStateCloud(expectedSpeakerID: expectedSpeakerID)
    }

    func refreshStateCloud(expectedSpeakerID: String) async {
        guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
        guard let gid = cloudGroupId,
              let token = await SonosAuth.shared.validAccessToken() else {
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
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

            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }

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
            await resolveCurrentAppleMusicArtworkIfNeeded()
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }

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
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            MusicAmbienceManager.shared.receive(snapshot: musicAmbienceSnapshot())
            managePositionTimer()
            manageLiveActivity()
        } catch SonosCloudError.unauthorized {
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            _ = await SonosAuth.shared.refreshAccessToken()
        } catch {
            guard speakerSelectionMatches(expectedSpeakerID: expectedSpeakerID) else { return }
            consecutiveFailures += 1
            if consecutiveFailures >= Self.maxConsecutiveRefreshFailures {
                connectionState = .disconnected
                errorMessage = "Remote control unavailable — check your connection."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    static func transportState(fromCloudPlaybackState raw: String?) -> TransportState {
        switch raw {
        case "PLAYBACK_STATE_PLAYING":   return .playing
        case "PLAYBACK_STATE_PAUSED":    return .paused
        case "PLAYBACK_STATE_BUFFERING": return .transitioning
        case "PLAYBACK_STATE_IDLE":      return .stopped
        default:                         return .stopped
        }
    }

    static func repeatMode(fromCloud raw: String?, one: Bool?) -> RepeatMode {
        if one == true { return .one }
        switch raw {
        case "REPEAT_ALL", "ALL":  return .all
        case "REPEAT_ONE", "ONE":  return .one
        default:                   return .off
        }
    }


}
