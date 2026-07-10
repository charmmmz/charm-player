import Foundation
import SwiftUI

extension SearchManager {

    func transferAppleMusicTrack(
        _ track: AppleMusicHandoffTrack,
        manager: SonosManager
    ) async throws -> HandoffResult {
        guard let selectedSpeaker = manager.selectedSpeaker else {
            throw HandoffTransferError.noSelectedSpeaker
        }
        configure(speakerIP: selectedSpeaker.playbackIP)

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            throw HandoffTransferError.sonosCloudDisconnected
        }
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        if !hasProbed {
            await probeLinkedServices()
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        }
        await refreshServiceIdMappingIfNeeded()
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        guard let appleMusicAccount = linkedAccounts.first(where: { isAppleMusicAccount($0) }),
              let serviceId = appleMusicAccount.serviceId,
              let accountId = appleMusicAccount.accountId else {
            throw HandoffTransferError.appleMusicNotLinkedOnSonos
        }

        let term = "\(track.title) \(track.artist)"
        let response = try await searchServiceWithTokenRefresh(
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId,
            term: term)
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        let cloudCandidates = response.allResources.compactMap { resource -> ForwardCloudTrackCandidate? in
            guard resource.type == "TRACK",
                  let item = convertToBrowseItem(resource, serviceId: serviceId, accountId: accountId) else {
                return nil
            }
            return ForwardCloudTrackCandidate(resource: resource, item: item)
        }
        let candidates = cloudCandidates.map(\.item)

        guard !candidates.isEmpty else {
            throw HandoffTransferError.noConfidentMatch
        }

        guard let match = HandoffMatcher.bestMatch(for: track, candidates: candidates),
              let matchedCloudCandidate = cloudCandidates.first(where: { $0.item == match.item }) else {
            throw HandoffTransferError.noConfidentMatch
        }

        let previousError = errorMessage
        errorMessage = nil
        let transferControlBackend = try await forwardHandoffControlBackend(
            selectedSpeaker: selectedSpeaker,
            manager: manager)
        var albumPlaybackError: String?
        if let albumAttempt = await forwardAlbumQueueAttempt(
            sourceTrack: track,
            matchedCandidate: matchedCloudCandidate,
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId,
            backend: transferControlBackend) {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            let albumPlayback = try await playForwardAlbumQueue(
                albumAttempt.plan,
                sourceTrack: track,
                selectedSpeaker: selectedSpeaker,
                backend: transferControlBackend,
                manager: manager)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            if albumPlayback.played {
                return HandoffResult(
                    matchedTitle: match.item.title,
                    targetName: selectedSpeaker.name,
                    seeked: albumPlayback.seeked,
                    transferredTrackCount: albumAttempt.plan.transferredTrackCount,
                    skippedUnsupportedItemCount: albumAttempt.plan.skippedUnsupportedItemCount,
                    warningMessage: nil,
                    usedAlbumQueue: true)
            }

            // Album queue sync is best-effort; do not leave its error visible if single-track fallback succeeds.
            albumPlaybackError = errorMessage
            errorMessage = nil
        }

        let played: Bool
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        switch transferControlBackend {
        case .cloud(let groupId, let cloudToken, _, _):
            played = try await playCloudForwardTrack(
                item: match.item,
                token: cloudToken,
                groupId: groupId,
                backend: transferControlBackend,
                selectedSpeaker: selectedSpeaker,
                manager: manager)
        case .lan:
            played = try await playForwardSingleTrack(
                item: match.item,
                selectedSpeaker: selectedSpeaker,
                backend: transferControlBackend,
                manager: manager)
        }
        guard played else {
            throw HandoffTransferError.sonosPlaybackFailed(
                errorMessage ?? albumPlaybackError ?? previousError ?? "Couldn’t start playback on Sonos.")
        }

        var didSeek = false
        if track.position > 3 {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            let maxPosition = track.duration.map {
                max(0, min(track.position, $0 - 2))
            } ?? track.position
            do {
                switch transferControlBackend {
                case .cloud(let groupId, let cloudToken, _, _):
                    try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                    try await SonosCloudAPI.seek(
                        token: cloudToken, groupId: groupId,
                        positionMillis: Int((maxPosition * 1000.0).rounded()))
                case .lan(let ip, _, _):
                    try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                    try await SonosAPI.seek(
                        ip: ip,
                        position: SonosTime.apiFormat(maxPosition))
                }
                didSeek = true
            } catch {
                SonosLog.error(.playback, "Forward single-track handoff seek failed: \(error)")
            }
        }

        try await refreshForwardHandoffState(
            selectedSpeaker: selectedSpeaker,
            backend: transferControlBackend,
            manager: manager,
            loadQueue: false)
        let warningMessage: String?
        switch transferControlBackend {
        case .cloud:
            warningMessage = "Queue sync requires the same network"
        case .lan:
            warningMessage = nil
        }

        return HandoffResult(
            matchedTitle: match.item.title,
            targetName: selectedSpeaker.name,
            seeked: didSeek,
            transferredTrackCount: 1,
            skippedUnsupportedItemCount: 0,
            warningMessage: warningMessage,
            usedAlbumQueue: false)
    }

    func transferSonosAppleMusicToPhone(
        manager: SonosManager
    ) async throws -> ReverseHandoffResult {
        guard let selectedSpeaker = manager.selectedSpeaker else {
            throw ReverseHandoffError.noSelectedSpeaker
        }
        configure(speakerIP: selectedSpeaker.playbackIP)

        if let trackInfo = manager.trackInfo,
           isKnownNonAppleSource(trackInfo) {
            throw ReverseHandoffError.notAppleMusicSource
        }

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            throw ReverseHandoffError.sonosCloudDisconnected
        }
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        guard let backend = await manager.controlBackendEnsured() else {
            throw ReverseHandoffError.noBackend
        }
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        if !hasProbed {
            await probeLinkedServices()
            try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        }
        await refreshServiceIdMappingIfNeeded()
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        await manager.refreshState()
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        guard let trackInfo = manager.trackInfo else {
            throw ReverseHandoffError.missingSonosTrackMetadata
        }

        guard isAppleMusicTrack(trackInfo) else {
            throw ReverseHandoffError.notAppleMusicSource
        }

        let track = try reverseSourceTrack(from: trackInfo)
        let storeID = try await resolveAppleMusicStoreID(
            for: track,
            trackInfo: trackInfo,
            token: token,
            householdId: householdId)

        let queuePlan = await reverseHandoffQueuePlan(
            manager: manager,
            selectedSpeaker: selectedSpeaker,
            currentTrackInfo: trackInfo,
            currentStoreID: storeID)
        try ensureReverseHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        let playbackStoreIDs = queuePlan?.storeIDs ?? [storeID]
        try await AppleMusicHandoffManager.shared.playAppleMusicQueue(
            storeIDs: playbackStoreIDs,
            position: track.position)

        var paused = true
        var warning: String?
        do {
            try await SonosControl.pause(backend)
        } catch {
            paused = false
            warning = "Playing on iPhone. Couldn’t pause Sonos."
            SonosLog.error(.playback, "Reverse handoff Sonos pause failed: \(error)")
        }

        await manager.refreshState()
        return ReverseHandoffResult(
            matchedTitle: track.title,
            targetName: selectedSpeaker.name,
            seeked: track.position > 3,
            sonosPaused: paused,
            warningMessage: warning,
            transferredTrackCount: queuePlan?.transferredTrackCount ?? 1,
            skippedUnsupportedItemCount: queuePlan?.skippedUnsupportedItemCount ?? 0)
    }

    func reverseHandoffQueuePlan(
        manager: SonosManager,
        selectedSpeaker: SonosPlayer,
        currentTrackInfo: TrackInfo,
        currentStoreID: String
    ) async -> AppleMusicQueueHandoffPlan? {
        guard manager.isPlayingFromQueue else { return nil }

        async let queueResultTask = reverseHandoffQueueResult(ip: selectedSpeaker.playbackIP)
        async let currentTrackNumberTask = reverseHandoffCurrentTrackNumber(
            ip: selectedSpeaker.playbackIP)
        let (queueResult, currentTrackNumber) = await (queueResultTask, currentTrackNumberTask)

        guard let queue = queueResult?.items, !queue.isEmpty else { return nil }
        return AppleMusicQueueHandoffPlanner.makePlan(
            queue: queue,
            currentTrackNumber: currentTrackNumber,
            currentTrackInfo: currentTrackInfo,
            currentStoreID: currentStoreID)
    }

    func reverseHandoffQueueResult(ip: String) async -> QueueResult? {
        do {
            return try await SonosAPI.getQueue(ip: ip)
        } catch {
            SonosLog.error(.playback, "Reverse handoff queue lookup failed: \(error)")
            return nil
        }
    }

    func reverseHandoffCurrentTrackNumber(ip: String) async -> Int? {
        do {
            return try await SonosAPI.getCurrentTrackNumber(ip: ip)
        } catch {
            SonosLog.error(.playback, "Reverse handoff queue track number lookup failed: \(error)")
            return nil
        }
    }

    func isAppleMusicAccount(_ account: SonosCloudAPI.CloudMusicServiceAccount) -> Bool {
        let values = [
            account.name,
            account.nickname,
            account.integrationId,
            account.username
        ]
        return values.contains { value in
            guard let value else { return false }
            let normalized = value
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            return normalized.contains("apple music") || normalized.contains("applemusic")
        }
    }

    func ensureReverseHandoffTargetStillSelected(
        _ selectedSpeaker: SonosPlayer,
        manager: SonosManager
    ) throws {
        guard manager.selectedSpeaker?.id == selectedSpeaker.id else {
            throw ReverseHandoffError.noSelectedSpeaker
        }
    }

    func ensureForwardHandoffTargetStillSelected(
        _ selectedSpeaker: SonosPlayer,
        manager: SonosManager
    ) throws {
        guard manager.selectedSpeaker?.id == selectedSpeaker.id else {
            throw HandoffTransferError.noSelectedSpeaker
        }
    }

    func refreshForwardHandoffState(
        selectedSpeaker: SonosPlayer,
        backend: SonosControl.Backend,
        manager: SonosManager,
        loadQueue: Bool
    ) async throws {
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        let stillSelected = await manager.refreshState(
            usingLockedBackend: backend,
            expectedSpeakerID: selectedSpeaker.id,
            loadQueue: loadQueue)
        guard stillSelected else {
            throw HandoffTransferError.noSelectedSpeaker
        }
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
    }

    func forwardHandoffControlBackend(
        selectedSpeaker: SonosPlayer,
        manager: SonosManager
    ) async throws -> SonosControl.Backend {
        try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

        if manager.transportBackend == .unknown {
            _ = await manager.probeBackend()
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        }

        if manager.transportBackend == .cloud, manager.currentCloudGroupId == nil {
            await manager.resolveCloudGroupId()
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
        }

        if let backend = manager.currentControlBackend() {
            return backend
        }

        if let backend = await manager.controlBackendEnsured() {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            return backend
        }

        throw HandoffTransferError.noBackend
    }

    func reverseSourceTrack(from trackInfo: TrackInfo) throws -> AppleMusicHandoffTrack {
        let title = trackInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = trackInfo.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            throw ReverseHandoffError.missingSonosTrackMetadata
        }

        let album = trackInfo.album.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppleMusicHandoffTrack(
            title: title,
            artist: artist,
            album: album.isEmpty ? nil : album,
            duration: trackInfo.durationSeconds > 0 ? trackInfo.durationSeconds : nil,
            position: max(0, trackInfo.positionSeconds),
            playbackStoreID: directAppleMusicStoreID(from: trackInfo.trackURI),
            persistentID: nil)
    }

    func directAppleMusicStoreID(from trackURI: String?) -> String? {
        guard let objectID = SonosAppleMusicTrackResolver
            .trackObjectIDForNowPlaying(fromTrackURI: trackURI),
              let storeID = SonosAppleMusicTrackResolver.storeID(fromObjectID: objectID) else {
            return nil
        }

        guard storeID != objectID else {
            return nil
        }
        return storeID
    }

    func isKnownNonAppleSource(_ trackInfo: TrackInfo) -> Bool {
        trackInfo.source != .unknown && trackInfo.source != .appleMusic
    }

    func isAppleMusicTrack(_ trackInfo: TrackInfo) -> Bool {
        if trackInfo.source == .appleMusic {
            return true
        }

        guard let trackURI = trackInfo.trackURI else { return false }
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(trackURI)
        guard let localServiceID = parsed.localServiceID,
              let cloudServiceID = cloudServiceId(forLocalSid: localServiceID),
              let account = linkedAccounts.first(where: { $0.serviceId == cloudServiceID }) else {
            return false
        }
        return isAppleMusicAccount(account)
    }

    func sourceAppleMusicAccount(
        from trackInfo: TrackInfo
    ) -> SonosCloudAPI.CloudMusicServiceAccount? {
        guard let trackURI = trackInfo.trackURI else { return nil }
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(trackURI)
        guard let localServiceID = parsed.localServiceID,
              let cloudServiceID = cloudServiceId(forLocalSid: localServiceID) else {
            return nil
        }

        if let accountID = parsed.accountID,
           let exactAccount = linkedAccounts.first(where: {
               $0.serviceId == cloudServiceID &&
               $0.accountId == accountID &&
               isAppleMusicAccount($0)
           }) {
            return exactAccount
        }

        return linkedAccounts.first {
            $0.serviceId == cloudServiceID && isAppleMusicAccount($0)
        }
    }

    func resolveAppleMusicStoreID(
        for track: AppleMusicHandoffTrack,
        trackInfo: TrackInfo,
        token: String,
        householdId: String
    ) async throws -> String {
        if let storeID = track.playbackStoreID {
            return storeID
        }

        if let nowPlayingStoreID = try await nowPlayingStoreID(
            trackInfo: trackInfo,
            token: token,
            householdId: householdId) {
            return nowPlayingStoreID
        }

        return try await searchMatchedStoreID(
            for: track,
            token: token,
            householdId: householdId,
            preferredAccount: sourceAppleMusicAccount(from: trackInfo))
    }

    func nowPlayingStoreID(
        trackInfo: TrackInfo,
        token: String,
        householdId: String
    ) async throws -> String? {
        guard let trackURI = trackInfo.trackURI else { return nil }
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(trackURI)
        guard let localServiceID = parsed.localServiceID,
              let serviceId = cloudServiceId(forLocalSid: localServiceID),
              let accountId = parsed.accountID,
              let trackObjectID = SonosAppleMusicTrackResolver
                .cloudTrackObjectIDForNowPlaying(fromTrackURI: trackURI) else {
            return nil
        }

        do {
            let response = try await SonosCloudAPI.nowPlaying(
                token: token,
                householdId: householdId,
                serviceId: serviceId,
                accountId: accountId,
                trackObjectId: trackObjectID)
            let objectID = response.item?.resource?.id?.objectId ?? response.item?.id
            return SonosAppleMusicTrackResolver.storeID(fromObjectID: objectID)
        } catch {
            SonosLog.error(.nowPlaying, "Reverse handoff nowPlaying lookup failed: \(error)")
            return nil
        }
    }

    func forwardAlbumId(
        from matchedResource: SonosCloudAPI.CloudResource,
        matchedItem: BrowseItem,
        token: String,
        householdId: String,
        serviceId: String,
        accountId: String
    ) async -> String? {
        if let containerId = browseAlbumId(from: matchedResource.container?.id?.objectId),
           !containerId.isEmpty {
            SonosLog.info(.playback, "Forward album id from search container: \(containerId)")
            return containerId
        }

        let trackObjectId = SonosAppleMusicTrackResolver
            .cloudTrackObjectIDForNowPlaying(fromTrackURI: matchedItem.uri)
            ?? matchedResource.id?.objectId
            ?? matchedItem.id
        let cleanedTrackObjectId = browseTrackId(from: trackObjectId)
        guard !cleanedTrackObjectId.isEmpty else { return nil }

        do {
            let response = try await SonosCloudAPI.nowPlaying(
                token: token,
                householdId: householdId,
                serviceId: serviceId,
                accountId: accountId,
                trackObjectId: cleanedTrackObjectId)
            let albumId = browseAlbumId(from: response.item?.albumId)
            SonosLog.info(
                .playback,
                "Forward album id from nowPlaying trackId='\(cleanedTrackObjectId)': \(albumId ?? "nil")")
            return albumId
        } catch {
            SonosLog.error(.nowPlaying, "Forward handoff album lookup failed: \(error)")
            return nil
        }
    }

    func browseAlbumId(from rawId: String?) -> String? {
        guard let rawId else { return nil }
        let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.firstIndex(of: "#").map { String(trimmed[..<$0]) } ?? trimmed
        let parts = base.components(separatedBy: ":")
        guard let albumIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("album") == .orderedSame }),
              albumIndex < parts.index(before: parts.endIndex) else {
            return base
        }
        return parts[albumIndex...].joined(separator: ":")
    }

    func browseTrackId(from rawId: String?) -> String {
        guard let rawId else { return "" }
        let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let base = trimmed.firstIndex(of: "#").map { String(trimmed[..<$0]) } ?? trimmed
        let parts = base.components(separatedBy: ":")
        guard let trackIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("track") == .orderedSame }),
              trackIndex < parts.index(before: parts.endIndex) else {
            return base
        }
        return parts[trackIndex...].joined(separator: ":")
    }

    func searchMatchedStoreID(
        for track: AppleMusicHandoffTrack,
        token: String,
        householdId: String,
        preferredAccount: SonosCloudAPI.CloudMusicServiceAccount?
    ) async throws -> String {
        let account = preferredAccount ?? linkedAccounts.first(where: { isAppleMusicAccount($0) })
        guard let appleMusicAccount = account,
              let serviceId = appleMusicAccount.serviceId,
              let accountId = appleMusicAccount.accountId else {
            throw ReverseHandoffError.appleMusicNotLinkedOnSonos
        }

        let term = "\(track.title) \(track.artist)"
        let response = try await searchServiceWithTokenRefresh(
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId,
            term: term)

        let candidates = response.allResources.compactMap { resource -> BrowseItem? in
            guard resource.type == "TRACK" else { return nil }
            return convertToBrowseItem(resource, serviceId: serviceId, accountId: accountId)
        }

        guard let match = HandoffMatcher.bestMatch(for: track, candidates: candidates),
              let storeID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: match.item) else {
            throw ReverseHandoffError.noConfidentMatch
        }
        return storeID
    }

}
