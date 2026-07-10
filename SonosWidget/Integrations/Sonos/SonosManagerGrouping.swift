import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    // MARK: - Speaker Grouping

    var currentGroupMembers: [SonosPlayer] {
        guard let selected = selectedSpeaker else { return [] }
        let groupId = selected.groupId ?? selected.id
        if let status = groupStatuses.first(where: { status in
            status.id == groupId
                || status.coordinator.id == selected.id
                || status.coordinator.groupId == groupId
                || status.members.contains { member in
                    member.id == selected.id || member.groupId == groupId
                }
        }) {
            return status.members.filter { !$0.isInvisible }
        }
        return allSpeakers.filter { $0.groupId == groupId && !$0.isInvisible }
    }

    func musicAmbienceSnapshot() -> HueAmbiencePlaybackSnapshot {
        Self.musicAmbienceSnapshot(
            selectedSpeaker: selectedSpeaker,
            currentGroupMembers: currentGroupMembers,
            trackInfo: trackInfo,
            isPlaying: isPlaying,
            albumArtData: albumArtImage?.jpegData(compressionQuality: 0.85)
        )
    }

    var isEverywhereActive: Bool {
        let visible = allSpeakers.filter { !$0.isInvisible }
        guard visible.count > 1, let gid = selectedSpeaker.map({ $0.groupId ?? $0.id }) else { return false }
        return visible.allSatisfy { $0.groupId == gid }
    }

    nonisolated static func partyModeJoinTargets(
        selectedSpeaker: SonosPlayer?,
        allSpeakers: [SonosPlayer]
    ) -> [SonosPlayer] {
        guard let selectedSpeaker else { return [] }
        let currentGroupID = selectedSpeaker.groupId ?? selectedSpeaker.id
        var seen = Set<String>()

        return allSpeakers.filter { speaker in
            guard !speaker.isInvisible,
                  speaker.groupId != currentGroupID,
                  speaker.id != selectedSpeaker.id,
                  seen.insert(speaker.id).inserted else {
                return false
            }
            return true
        }
    }

    nonisolated static func partyModeLeaveTargets(
        selectedSpeaker: SonosPlayer?,
        allSpeakers: [SonosPlayer]
    ) -> [SonosPlayer] {
        guard let selectedSpeaker else { return [] }
        let currentGroupID = selectedSpeaker.groupId ?? selectedSpeaker.id
        var seen = Set<String>()

        return allSpeakers.filter { speaker in
            guard !speaker.isInvisible,
                  speaker.groupId == currentGroupID,
                  speaker.id != selectedSpeaker.id,
                  seen.insert(speaker.id).inserted else {
                return false
            }
            return true
        }
    }

    /// Sonos LAN "party mode": every visible zone outside the current group
    /// joins the selected coordinator via `SetAVTransportURI x-rincon:<uuid>`.
    func enablePartyMode() async {
        guard let coordinator = selectedSpeaker else { return }
        let targets = Self.partyModeJoinTargets(
            selectedSpeaker: coordinator,
            allSpeakers: allSpeakers
        )
        guard !targets.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        for speaker in targets {
            do {
                try await SonosAPI.joinGroup(
                    speakerIP: speaker.ipAddress,
                    coordinatorUUID: coordinator.id
                )
                try? await Task.sleep(for: .milliseconds(150))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        try? await Task.sleep(for: .milliseconds(500))
        await reloadTopology()
        await refreshAllGroupStatuses()
    }

    func disablePartyMode() async {
        let targets = Self.partyModeLeaveTargets(
            selectedSpeaker: selectedSpeaker,
            allSpeakers: allSpeakers
        )
        guard !targets.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        for speaker in targets {
            do {
                try await SonosAPI.leaveGroup(speakerIP: speaker.ipAddress)
                try? await Task.sleep(for: .milliseconds(150))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        try? await Task.sleep(for: .milliseconds(500))
        await reloadTopology()
        await refreshAllGroupStatuses()
    }

    func refreshSavedAreas() async {
        guard let target = await localControlAreaTarget() else {
            savedAreas = []
            return
        }

        do {
            let response = try await SonosLocalControlAPI.getAreas(
                ip: target.ip,
                householdId: target.householdId)
            savedAreas = response.areas
        } catch {
            SonosLog.debug(.sonosCloud, "refreshSavedAreas failed: \(error)")
        }
    }

    func applyArea(_ area: SonosArea) async {
        guard !area.playerIds.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        var createResponse: SonosCloudAPI.CreateGroupResponse?
        do {
            createResponse = try await createGroupFromAreaLocal(area)
        } catch {
            SonosLog.debug(.sonosCloud, "local area apply failed for \(area.name): \(error)")
            do {
                createResponse = try await createGroupFromAreaCloud(area)
            } catch {
                SonosLog.debug(.sonosCloud, "cloud area apply failed for \(area.name): \(error)")
                do {
                    try await applyAreaUsingLanJoinFallback(area)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(500))
        await reloadTopology()
        await selectSpeakerAfterApplyingArea(area, createResponse: createResponse)
        await fetchMemberVolumes()
    }

    func localControlAreaTarget() async -> (ip: String, playerId: String, householdId: String)? {
        guard let speaker = localControlCandidateSpeaker() else { return nil }

        if let localControlHouseholdId {
            return (speaker.ipAddress, speaker.id, localControlHouseholdId)
        }

        do {
            let info = try await SonosLocalControlAPI.playerInfo(
                ip: speaker.ipAddress,
                playerId: speaker.id)
            guard let householdId = info.householdId,
                  !householdId.isEmpty else {
                return nil
            }
            localControlHouseholdId = householdId
            return (speaker.ipAddress, speaker.id, householdId)
        } catch {
            SonosLog.debug(.sonosCloud, "localControlAreaTarget failed: \(error)")
            return nil
        }
    }

    func localControlCandidateSpeaker() -> SonosPlayer? {
        let candidates = allSpeakers + speakers + [selectedSpeaker].compactMap { $0 }
        var seen = Set<String>()
        return candidates.first { speaker in
            guard !speaker.ipAddress.isEmpty,
                  !speaker.id.isEmpty,
                  speaker.id.hasPrefix("RINCON_"),
                  seen.insert(speaker.id).inserted else {
                return false
            }
            return true
        }
    }

    func createGroupFromAreaLocal(_ area: SonosArea) async throws -> SonosCloudAPI.CreateGroupResponse {
        guard let target = await localControlAreaTarget() else {
            throw SonosAreaApplyError.localControlUnavailable
        }

        return try await SonosLocalControlAPI.createGroup(
            ip: target.ip,
            householdId: target.householdId,
            playerIds: area.playerIds,
            areaIds: [area.id],
            musicContextGroupId: selectedSpeaker?.groupId ?? selectedSpeaker?.id)
    }

    func createGroupFromAreaCloud(_ area: SonosArea) async throws -> SonosCloudAPI.CreateGroupResponse {
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            throw SonosCloudError.unauthorized
        }

        return try await SonosCloudAPI.createGroup(
            token: token,
            householdId: householdId,
            playerIds: area.playerIds,
            musicContextGroupId: cloudGroupId ?? selectedSpeaker?.groupId ?? selectedSpeaker?.id,
            areaIds: [area.id])
    }

    func applyAreaUsingLanJoinFallback(_ area: SonosArea) async throws {
        let areaPlayerIds = Set(area.playerIds)
        let visibleMembers = allSpeakers.filter {
            areaPlayerIds.contains($0.id) && !$0.isInvisible && !$0.ipAddress.isEmpty
        }
        guard let coordinator = areaFallbackCoordinator(in: visibleMembers) else {
            throw SonosAreaApplyError.noReachableAreaPlayers
        }

        for member in visibleMembers where member.id != coordinator.id {
            try await SonosAPI.joinGroup(
                speakerIP: member.ipAddress,
                coordinatorUUID: coordinator.id)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    func areaFallbackCoordinator(in members: [SonosPlayer]) -> SonosPlayer? {
        let currentIDs = Set(currentGroupMembers.map(\.id))
        return members.first { currentIDs.contains($0.id) }
            ?? members.first(where: \.isCoordinator)
            ?? members.first
    }

    func selectSpeakerAfterApplyingArea(
        _ area: SonosArea,
        createResponse: SonosCloudAPI.CreateGroupResponse?
    ) async {
        let areaPlayerIds = Set(area.playerIds)
        if let matchingGroup = groupStatuses.first(where: { status in
            let memberIds = Set(status.members.filter { !$0.isInvisible }.map(\.id))
            return !memberIds.isEmpty && memberIds == areaPlayerIds
        }) {
            await selectSpeaker(
                matchingGroup.coordinator,
                userInitiatedLiveActivityResume: true)
            return
        }

        let candidateIDs = [
            createResponse?.group.coordinatorId,
            createResponse?.group.playerIds.first,
            area.playerIds.first
        ].compactMap { $0 }

        for id in candidateIDs {
            if let speaker = speakers.first(where: { $0.id == id })
                ?? allSpeakers.first(where: { $0.id == id }) {
                await selectSpeaker(speaker, userInitiatedLiveActivityResume: true)
                return
            }
        }
    }

    func addSpeakerToGroup(_ speaker: SonosPlayer) async {
        guard let coordinator = selectedSpeaker else { return }
        let coordUUID = coordinator.id
        do {
            try await SonosAPI.joinGroup(speakerIP: speaker.ipAddress, coordinatorUUID: coordUUID)
            try? await Task.sleep(for: .milliseconds(500))
            await reloadTopology()
        } catch { errorMessage = error.localizedDescription }
    }

    func removeSpeakerFromGroup(_ speaker: SonosPlayer) async {
        do {
            try await SonosAPI.leaveGroup(speakerIP: speaker.ipAddress)
            try? await Task.sleep(for: .milliseconds(500))
            await reloadTopology()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Separates every non-coordinator member of the group, leaving each speaker standalone.
    func separateGroup(groupID: String) async {
        guard let source = groupStatuses.first(where: { $0.id == groupID }) else { return }
        let nonCoordinators = source.members.filter { $0.id != source.coordinator.id }
        guard !nonCoordinators.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        for member in nonCoordinators {
            do {
                try await SonosAPI.leaveGroup(speakerIP: member.ipAddress)
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        await reloadTopology()
        await refreshAllGroupStatuses()
    }

    /// Merges every member of `sourceGroupID` into `targetGroupID`.
    func mergeGroups(sourceGroupID: String, intoGroupID: String) async {
        guard sourceGroupID != intoGroupID,
              let target = groupStatuses.first(where: { $0.id == intoGroupID }),
              let source = groupStatuses.first(where: { $0.id == sourceGroupID }) else { return }

        isLoading = true
        defer { isLoading = false }

        for member in source.members {
            do {
                try await SonosAPI.joinGroup(speakerIP: member.ipAddress,
                                             coordinatorUUID: target.coordinator.id)
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        await reloadTopology()
        await refreshAllGroupStatuses()
    }

    func transferPlayback(to target: SonosPlayer) async {
        guard let current = selectedSpeaker, current.id != target.id else { return }
        do {
            let targetAlreadyInGroup = currentGroupMembers.contains { $0.id == target.id }

            if targetAlreadyInGroup {
                // Target is already in our group — just remove current coordinator
                // so target becomes the new coordinator and keeps playing.
                try await SonosAPI.leaveGroup(speakerIP: current.ipAddress)
            } else {
                // Target is standalone — add it to our group first, then remove current.
                try await SonosAPI.joinGroup(speakerIP: target.ipAddress, coordinatorUUID: current.id)
                try? await Task.sleep(for: .milliseconds(500))
                try await SonosAPI.leaveGroup(speakerIP: current.ipAddress)
            }

            try? await Task.sleep(for: .milliseconds(500))
            await reloadTopology()

            if let updated = speakers.first(where: { $0.id == target.id })
                ?? allSpeakers.first(where: { $0.id == target.id }) {
                await selectSpeaker(updated)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshAllGroupStatuses() async {
        await groupRefreshGate.run {
            await self.performRefreshAllGroupStatuses()
        }
    }

    func performRefreshAllGroupStatuses() async {
        isRefreshingHomeSpeakerCards = true
        defer { isRefreshingHomeSpeakerCards = false }

        switch transportBackend {
        case .lan:
            await refreshAllGroupStatusesLAN()
        case .cloud:
            await refreshAllGroupStatusesCloud()
        case .unknown:
            // Don't burn a LAN UPnP call (~30s timeout on cellular) while
            // the backend is still being probed. The next polling tick — or
            // whatever kicked off the probe — will re-route us into the
            // correct branch once `transportBackend` settles. Meanwhile the
            // Home tab's "Speaker unreachable" banner is the right terminal
            // state for a genuinely unreachable speaker.
            return
        }

        await refreshSavedAreas()

        if let token = SharedStorage.liveActivityPushToStartToken,
           RelayManager.shared.isAvailable {
            registerPushToStartTokenIfPossible(token, reason: "group-status-refresh")
        }
    }

    func refreshAllGroupStatusesLAN() async {
        guard let anyIP = allSpeakers.first?.ipAddress ?? selectedSpeaker?.ipAddress else { return }

        do {
            let fresh = try await SonosAPI.getZoneGroupState(ip: anyIP)
            allSpeakers = fresh
            speakers = Self.homeSpeakerCoordinatorCandidates(in: fresh)
            SharedStorage.savedSpeakers = fresh

            var statuses: [SpeakerGroupStatus] = []
            let coordinators = Self.homeSpeakerCoordinatorCandidates(in: fresh)

            for coord in coordinators {
                let members = fresh.filter { $0.groupId == coord.groupId && !$0.isInvisible }
                do {
                    async let t = SonosAPI.getTransportInfo(ip: coord.ipAddress)
                    async let p = SonosAPI.getPositionInfo(ip: coord.ipAddress)
                    async let v = SonosAPI.getGroupVolume(ip: coord.ipAddress)
                    let state = try await t
                    let positionInfo = try await p
                    let vol = (try? await v) ?? 0
                    let localMetadata: SonosCloudAPI.CloudPlaybackMetadata?
                    if Self.shouldFetchLocalControlMetadataForLANSpeakerStatus(positionInfo) {
                        localMetadata = await fetchLocalControlPlaybackMetadata(ip: coord.ipAddress)
                    } else {
                        localMetadata = nil
                    }
                    let track = Self.lanTrackInfo(
                        positionInfo,
                        localMetadata: localMetadata,
                        cachedCloudQuality: cachedCloudQuality,
                        cloudQualityIsAuthoritative: SonosAuth.shared.isLoggedIn
                            && isCloudQualityAuthoritative(positionInfo.source)
                    )
                    statuses.append(SpeakerGroupStatus(
                        id: coord.groupId ?? coord.id,
                        coordinator: coord, members: members,
                        trackInfo: track, transportState: state, volume: vol
                    ))
                } catch {
                    statuses.append(SpeakerGroupStatus(
                        id: coord.groupId ?? coord.id,
                        coordinator: coord, members: members,
                        trackInfo: nil, transportState: .unknown, volume: 0
                    ))
                }
            }
            applyPreferredSpeakerOrder(to: statuses)
            await loadGroupAlbumColors()
        } catch { /* keep existing data */ }
    }

    /// Cloud version of `refreshAllGroupStatuses`. Populates the Home tab
    /// speaker-group cards from the Sonos Cloud Control API's `getGroups`
    /// endpoint so the UI doesn't get stuck on "Loading speakers…" when the
    /// user is off-LAN. Per-group track info / volume can't be fetched
    /// cheaply for non-selected groups (would need one playbackMetadata call
    /// per group), so:
    ///   - The currently selected group gets the track info the main
    ///     `refreshStateCloud` already filled in.
    ///   - Other groups show the transport state from `playbackState` but
    ///     leave `trackInfo` empty.
    func refreshAllGroupStatusesCloud() async {
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            projectSkeletonGroupStatusesFromSavedSpeakers()
            return
        }
        do {
            let response = try await SonosCloudAPI.getGroups(
                token: token, householdId: householdId)

            // Merge cloud players with anything we already know locally
            // (e.g. from a previous LAN session that got persisted). This
            // keeps per-player IPs around even off-LAN — useful if Wi-Fi
            // comes back and the probe flips to .lan.
            //
            // Name collisions happen in practice: a single speaker often
            // appears twice in `allSpeakers` — the real entry plus a
            // hidden (`isInvisible: true`) shadow for stereo-pair / home
            // theater satellites. When both entries share a display name,
            // prefer the *visible* one; otherwise the Home card picks up
            // the hidden shadow and renders a blank speaker name (the
            // `visibleMembers` filter drops it).
            let savedByName = Dictionary(
                allSpeakers.map { ($0.name, $0) },
                uniquingKeysWith: { first, second in
                    first.isInvisible && !second.isInvisible ? second : first
                })

            // Fetch per-group playback metadata concurrently so every card
            // gets its track name / artist / album art — not just the
            // currently selected group. For a typical 2-4 group household
            // this is 2-4 parallel HTTPS calls, cheap enough to run every
            // ~6s alongside the `getGroups` call above.
            // Per-group fan-out: metadata (track name/art), playback status
            // (position + actual transport state), and group volume. Each
            // call is independent, so run them all in one big TaskGroup.
            // Total cost for a household of N groups is 3N parallel HTTPS
            // calls every ~6s — still small, and enough to give every
            // card on Home a fully-populated mini-now-playing + volume.
            typealias PerGroup = (
                meta: SonosCloudAPI.CloudPlaybackMetadata?,
                status: SonosCloudAPI.PlaybackStatus?,
                volume: SonosCloudAPI.GroupVolume?
            )
            var perGroup: [String: PerGroup] = [:]
            await withTaskGroup(of: (String, String, Any?).self) { group in
                for cloudGroup in response.groups {
                    let gid = cloudGroup.id
                    group.addTask {
                        let meta = try? await SonosCloudAPI.getPlaybackMetadata(
                            token: token, groupId: gid)
                        return (gid, "meta", meta as Any?)
                    }
                    group.addTask {
                        let status = try? await SonosCloudAPI.getPlaybackStatus(
                            token: token, groupId: gid)
                        return (gid, "status", status as Any?)
                    }
                    group.addTask {
                        let vol = try? await SonosCloudAPI.getGroupVolume(
                            token: token, groupId: gid)
                        return (gid, "volume", vol as Any?)
                    }
                }
                for await (gid, kind, value) in group {
                    var entry = perGroup[gid] ?? (nil, nil, nil)
                    switch kind {
                    case "meta":   entry.meta   = value as? SonosCloudAPI.CloudPlaybackMetadata
                    case "status": entry.status = value as? SonosCloudAPI.PlaybackStatus
                    case "volume": entry.volume = value as? SonosCloudAPI.GroupVolume
                    default: break
                    }
                    perGroup[gid] = entry
                }
            }

            var statuses: [SpeakerGroupStatus] = []
            for cloudGroup in response.groups {
                // Each group's members = cloud players whose ids match
                // `playerIds`. Fall back to name matching for savedSpeakers
                // which we saw via UPnP (those have RINCON ids, the cloud
                // uses a parallel id scheme).
                let players = response.players.filter { cloudGroup.playerIds.contains($0.id) }
                let members: [SonosPlayer] = players.map { cloudPlayer in
                    if let saved = savedByName[cloudPlayer.name] { return saved }
                    // Synthesize a LAN-less placeholder; ip is empty so LAN
                    // commands will no-op but group membership displays fine.
                    return SonosPlayer(
                        id: cloudPlayer.id, name: cloudPlayer.name,
                        ipAddress: "", isCoordinator: true,
                        groupId: cloudGroup.id)
                }
                let coord = members.first ?? SonosPlayer(
                    id: cloudGroup.id, name: cloudGroup.name,
                    ipAddress: "", isCoordinator: true,
                    groupId: cloudGroup.id)

                let isSelected = cloudGroup.id == cloudGroupId
                let entry = perGroup[cloudGroup.id] ?? (meta: nil, status: nil, volume: nil)

                // Prefer the live `playbackStatus` result for transport
                // state (more authoritative than the `getGroups`-embedded
                // `playbackState`); fall back to the main `transportState`
                // when this group is the selected one and already fresh.
                let state: TransportState = {
                    if isSelected { return transportState }
                    if let raw = entry.status?.playbackState {
                        return Self.transportState(fromCloudPlaybackState: raw)
                    }
                    return Self.transportState(fromCloudPlaybackState: cloudGroup.playbackState)
                }()

                // Assemble a TrackInfo for the card: selected group reuses
                // the one `refreshStateCloud` already enriched (has audio
                // quality etc.); other groups get a minimal version built
                // from their per-group metadata fetch above — now also
                // carrying `position` so the card's progress ring fills in.
                let track: TrackInfo? = {
                    if isSelected { return trackInfo }
                    guard let meta = entry.meta else { return nil }
                    return Self.cloudSpeakerCardTrackInfo(
                        from: meta,
                        positionMillis: entry.status?.positionMillis)
                }()

                // Group volume: selected group uses `manager.volume` (kept
                // live for the full player); others read from the cloud
                // `groupVolume` fan-out. Nil response → 0 as a safe sentinel.
                let vol: Int = isSelected
                    ? volume
                    : (entry.volume?.volume ?? 0)

                statuses.append(SpeakerGroupStatus(
                    id: cloudGroup.id,
                    name: cloudGroup.name,
                    coordinator: coord, members: members,
                    trackInfo: track, transportState: state, volume: vol
                ))
            }
            applyPreferredSpeakerOrder(to: statuses)
            await loadGroupAlbumColors()
        } catch {
            // `getGroups` failed (network blip, token drift, Sonos cloud
            // hiccup). Don't leave the Home tab stuck on "Loading speakers…"
            // — project whatever `savedSpeakers` we have into placeholder
            // cards with unknown transport state so the user at least sees
            // familiar scaffolding. The next refresh tick will overwrite
            // with real data if the cloud recovers.
            SonosLog.error(.sonosCloud, "refreshAllGroupStatusesCloud failed: \(error)")
            projectSkeletonGroupStatusesFromSavedSpeakers()
        }
    }

    /// Fallback used when the cloud-side group refresh fails but we still
    /// have a saved roster from a prior LAN session. Produces minimal
    /// `SpeakerGroupStatus` entries — enough to render speaker cards with
    /// names + membership, but `trackInfo` / `transportState` are blanked.
    /// Returns the first URL string that's actually reachable from the
    /// current network. Sonos Cloud's `playbackMetadata` often hands back
    /// a `track.imageUrl` pointing at the speaker's own LAN address
    /// (`http://192.168.x.x:1400/getaa?…`) — great when you're in the
    /// house, totally dead over cellular. Filter those out in cloud mode
    /// so the CDN fallbacks (`album.imageUrl`, `container.imageUrl`)
    /// actually get a chance to render.
    nonisolated static func cloudSpeakerCardTrackInfo(
        from metadata: SonosCloudAPI.CloudPlaybackMetadata,
        positionMillis: Int?
    ) -> TrackInfo? {
        let positionSeconds = (positionMillis).map { TimeInterval($0) / 1000.0 } ?? 0
        var info = TrackInfo(
            title: "",
            artist: "",
            album: "",
            duration: "00:00:00",
            position: SonosTime.apiFormat(positionSeconds)
        )
        info = trackInfo(info, applyingPlaybackMetadata: metadata)
        info.albumArtURL = pickPublicArtURL(
            metadata.currentItem?.track?.imageUrl,
            metadata.currentItem?.track?.album?.imageUrl,
            metadata.container?.imageUrl)

        guard homeSpeakerTrackHasUsefulMetadata(info) else { return nil }
        return info
    }

    nonisolated static func pickPublicArtURL(_ candidates: String?...) -> String? {
        for case let url? in candidates where isPubliclyReachable(url) {
            return url
        }
        return nil
    }

    nonisolated static func isPubliclyReachable(_ urlStr: String) -> Bool {
        guard let url = URL(string: urlStr), let host = url.host else { return false }
        // Accept https outright (mzstatic, aliyuncs, etc. — cross-network
        // CDN URLs). Plain http is only accepted if the host is *not* a
        // private IP literal — matches Sonos's pattern of serving art
        // off the speaker itself on port 1400.
        if url.scheme == "https" { return true }
        // Host is a literal IP?
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            let a = parts[0], b = parts[1]
            let isPrivate =
                a == 10 ||
                (a == 192 && b == 168) ||
                (a == 172 && (16...31).contains(b)) ||
                a == 127
            return !isPrivate
        }
        // Non-IP hostname over plain http — rare but let it through; ATS
        // will block it if it's actually insecure.
        return true
    }

    func projectSkeletonGroupStatusesFromSavedSpeakers() {
        guard groupStatuses.isEmpty, !allSpeakers.isEmpty else { return }
        let coordinators = Self.homeSpeakerCoordinatorCandidates(in: allSpeakers)
        let statuses = coordinators.map { coord in
            let members = allSpeakers.filter {
                $0.groupId == coord.groupId && !$0.isInvisible
            }
            return SpeakerGroupStatus(
                id: coord.groupId ?? coord.id,
                coordinator: coord, members: members,
                trackInfo: nil, transportState: .unknown, volume: 0)
        }
        applyPreferredSpeakerOrder(to: statuses)
    }

    func loadGroupAlbumColors() async {
        for status in groupStatuses {
            let key = status.id
            if status.coordinator.id == selectedSpeaker?.id {
                // Mirror the selected speaker's live values verbatim — the
                // earlier `if let` skipped writes when albumArtImage was
                // nil, which kept the previous track's cover lingering on
                // the home card after switching to TV input.
                groupAlbumColors[key] = albumArtDominantColor
                groupAlbumImages[key] = albumArtImage
                continue
            }
            guard let urlStr = status.trackInfo?.albumArtURL, !urlStr.isEmpty,
                  let url = URL(string: urlStr) else {
                groupAlbumColors[key] = nil
                groupAlbumImages[key] = nil
                groupLastArtURL[key] = nil
                continue
            }
            if groupAlbumImages[key] != nil, groupLastArtURL[key] == urlStr {
                continue
            }
            do {
                let data = try await Self.fetchAlbumArtData(from: url, originalURLString: urlStr)
                if let image = UIImage(data: data) {
                    groupAlbumImages[key] = image
                    groupLastArtURL[key] = urlStr
                    let color = dominantColorCache[urlStr] ?? image.dominantColor()
                    dominantColorCache[urlStr] = color
                    groupAlbumColors[key] = color
                }
            } catch {
                groupAlbumColors[key] = nil
                groupAlbumImages[key] = nil
                groupLastArtURL[key] = nil
            }
        }
    }

    func reloadTopology() async {
        guard let anyIP = allSpeakers.first?.ipAddress ?? selectedSpeaker?.ipAddress else { return }
        if let fresh = try? await SonosAPI.getZoneGroupState(ip: anyIP) {
            allSpeakers = fresh
            speakers = Self.homeSpeakerCoordinatorCandidates(in: fresh)
            SharedStorage.savedSpeakers = fresh
        }
        await refreshAllGroupStatuses()
    }

    /// Override track metadata (e.g. when Sonos can't resolve it) and reload album art.
    func patchTrackInfo(title: String, artist: String, album: String, albumArtURL: String?) {
        trackInfo?.title = title
        trackInfo?.artist = artist
        trackInfo?.album = album
        if let art = albumArtURL {
            trackInfo?.albumArtURL = art
        }
        syncCurrentGroupStatusFromPlaybackState()
        updateSharedCache()
        Task { await loadAlbumArt() }
    }

}
