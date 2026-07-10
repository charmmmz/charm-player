import Foundation
import SwiftUI

extension SearchManager {

    // MARK: - Playback Actions

    func playbackMetadata(for item: BrowseItem) -> String {
        if let resMD = item.resMD, !resMD.isEmpty {
            return resMD
        }

        // For Cloud search results, build metadata with correct service account
        if item.cloudType != nil, let sid = item.serviceId {
            let accountId = accountIdForLocalSid(sid) ?? "0"
            return buildCloudDIDLMetadata(item: item, localSid: sid, accountId: accountId)
        }

        // UPnP-browsed items (Sonos system playlist children `SQ:<n>`, local
        // library, queue, etc.) ship their track-level DIDL fragment in
        // `metaXML` — title / artist / album / service `<desc>` already set
        // by Sonos. Without a `<DIDL-Lite>` envelope Sonos rejects it and
        // synthesises a bare stub from the URI, which is why individual
        // tracks from a Sonos Playlist showed up as "Unknown" on the player.
        if let metaXML = item.metaXML, !metaXML.isEmpty,
           metaXML.contains("<item") || metaXML.contains("<container") {
            return wrapInDIDLLiteIfNeeded(metaXML)
        }

        return SonosAPI.buildDIDLMetadata(item: item)
    }

    /// Add the DIDL-Lite envelope around a raw `<item>` / `<container>`
    /// fragment so Sonos will accept it as enqueue metadata.
    func wrapInDIDLLiteIfNeeded(_ xml: String) -> String {
        if xml.contains("<DIDL-Lite") { return xml }
        return "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
            "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " +
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" +
            xml +
            "</DIDL-Lite>"
    }

    /// Find the Cloud account-id (sn) for a given local service ID.
    func accountIdForLocalSid(_ localSid: Int) -> String? {
        for (cloudId, sid) in cloudToLocalSid {
            if sid == localSid {
                return linkedAccounts.first { $0.serviceId == cloudId }?.accountId
            }
        }
        return nil
    }

    /// Build DIDL metadata for Cloud items, matching the exact field sets the
    /// official Sonos app produces for each `cloudType`. Sonos validates the
    /// inner DIDL strictly when used as `<r:resMD>` for favorites — including
    /// fields that don't belong (e.g. `<upnp:albumArtURI>` inside an ARTIST
    /// item, or empty `<dc:creator>` tags) causes SOAP fault 803.
    ///
    /// Per-type field whitelist (verified by dumping existing favorites):
    ///   - ARTIST   → title, class, desc                          (minimal)
    ///   - PROGRAM  → title, class, desc                          (radio station)
    ///   - ALBUM    → title, class, albumArtURI, creator, albumArtist, desc
    ///   - PLAYLIST → title, class, albumArtURI, creator, desc
    ///   - TRACK    → title, class, albumArtURI, creator, album, albumArtist, desc
    func buildCloudDIDLMetadata(item: BrowseItem, localSid: Int, accountId: String) -> String {
        let cloudSid = localToCloudSid[localSid] ?? String(localSid)
        let username = cloudServiceUsername(for: cloudSid, accountId: accountId)
        let desc = "SA_RINCON\(cloudSid)_\(username)"

        let encodedObjId = item.id.replacingOccurrences(of: ":", with: "%3a")
        let cloudType = item.cloudType ?? "TRACK"

        let (itemId, upnpClass, xmlTag) = metadataComponents(
            cloudType: cloudType, objectId: encodedObjId, uri: item.playbackDescriptor.directURI)

        // Only TRACK/ALBUM/PLAYLIST carry rich metadata in their inner DIDL.
        // ARTIST and PROGRAM use a bare-minimum item (title + class + desc).
        let wantsRichMetadata = (cloudType == "TRACK" ||
                                 cloudType == "ALBUM" ||
                                 cloudType == "PLAYLIST")
        let artist = wantsRichMetadata && !item.artist.isEmpty ? item.artist : nil
        let albumArtist = wantsRichMetadata && cloudType != "PLAYLIST" ? artist : nil
        let album = (cloudType == "TRACK" && !item.album.isEmpty) ? item.album : nil
        let albumArtURI = wantsRichMetadata &&
            item.includeAlbumArtInCloudMetadata &&
            item.albumArtURL?.isEmpty == false ? item.albumArtURL : nil

        return SonosDIDLBuilder.document([
            SonosDIDLElement(
                tag: xmlTag,
                id: itemId,
                title: item.title,
                upnpClass: upnpClass,
                creator: artist,
                album: album,
                albumArtist: albumArtist,
                albumArtURI: albumArtURI,
                desc: desc)
        ])
    }

    func cloudServiceUsername(for cloudSid: String, accountId: String) -> String {
        if let username = cloudServiceUsername[cloudSid], !username.isEmpty {
            return username
        }
        if let username = linkedAccounts.first(where: { $0.serviceId == cloudSid })?.username,
           !username.isEmpty {
            return username
        }
        return "X_#Svc\(cloudSid)-\(accountId)-Token"
    }

    /// Returns (itemId, upnpClass, xmlTag) based on cloudType.
    /// Format derived from Wireshark capture of official Sonos app.
    func metadataComponents(cloudType: String, objectId: String,
                                    uri: String?) -> (String, String, String) {
        switch cloudType {
        case "TRACK":
            let flags = extractFlagsFromURI(uri)
            let flagsHex = String(format: "%04x", flags)
            return (trackMetadataObjectId(objectId: objectId, flagsHex: flagsHex),
                    "object.item.audioItem.musicTrack",
                    "item")
        case "ALBUM":
            return ("1004206c\(objectId)",
                    "object.container.album.musicAlbum.#AlbumView",
                    "item")
        case "PLAYLIST":
            return ("1006206c\(objectId)",
                    "object.container.playlistContainer",
                    "item")
        case "PROGRAM":
            return ("000c206c\(objectId)",
                    "object.item.audioItem.audioBroadcast.#programRadio",
                    "item")
        case "ARTIST":
            // Sonos Apple Music artist favorites use prefix `10052064` and
            // wrap the metadata in <item> (not <container>) — verified by
            // dumping existing artist favorites added via the official app.
            return ("10052064\(objectId)",
                    "object.container.person.musicArtist",
                    "item")
        default:
            return (objectId, "object.item.audioItem.musicTrack", "item")
        }
    }

    func trackMetadataObjectId(objectId: String, flagsHex: String) -> String {
        let catalogTrackId = appleMusicCatalogTrackId(from: objectId)
        return "1003\(flagsHex)\(catalogTrackId)"
    }

    func extractFlagsFromURI(_ uri: String?) -> Int {
        guard let uri = uri,
              let range = uri.range(of: "flags=") else { return 0 }
        let after = uri[range.upperBound...]
        let flagStr: Substring
        if let ampIdx = after.firstIndex(of: "&") {
            flagStr = after[..<ampIdx]
        } else {
            flagStr = after
        }
        return Int(flagStr) ?? 0
    }

    /// Inject `upnp:albumArtURI` into DIDL metadata when not already present.
    /// Sonos Favorites store the art URL in the outer browse item, but the inner
    /// `r:resMD` DIDL often omits it — which leaves "recently played" without cover art.
    func enrichMetadataWithArt(_ metadata: String, artURL: String?) -> String {
        guard let artURL = artURL, !artURL.isEmpty else { return metadata }
        if metadata.contains("albumArtURI") { return metadata }
        let artTag = "<upnp:albumArtURI>\(SonosAPI.escapeXML(artURL))</upnp:albumArtURI>"
        if metadata.contains("</item>") {
            return metadata.replacingOccurrences(of: "</item>", with: "\(artTag)</item>")
        }
        if metadata.contains("</container>") {
            return metadata.replacingOccurrences(of: "</container>", with: "\(artTag)</container>")
        }
        return metadata
    }

    func extractServiceParams() -> BrowseItemPlaybackResolver.ServiceParams? {
        playbackResolver.serviceParams(from: favorites + radio)
    }

    func constructFavoriteURI(resMD: String) -> String? {
        playbackResolver.favoriteTransportURI(
            resMD: resMD,
            seedItems: favorites + radio,
            defaultFlags: SonosRinconRadioFlags
        )
    }

    func forwardAlbumQueueAttempt(
        sourceTrack: AppleMusicHandoffTrack,
        matchedCandidate: ForwardCloudTrackCandidate,
        token: String,
        householdId: String,
        serviceId: String,
        accountId: String,
        backend: SonosControl.Backend
    ) async -> ForwardAlbumQueueAttempt? {
        guard case .lan = backend else {
            SonosLog.info(.playback, "Forward album handoff skipped: backend is not LAN")
            return nil
        }

        SonosLog.info(
            .playback,
            "Forward album handoff attempt: source='\(sourceTrack.title)' artist='\(sourceTrack.artist)' " +
            "match='\(matchedCandidate.item.title)' matchId='\(matchedCandidate.item.id)' " +
            "resourceId='\(matchedCandidate.resource.id?.objectId ?? "nil")' " +
            "container='\(matchedCandidate.resource.container?.name ?? "nil")' " +
            "containerId='\(matchedCandidate.resource.container?.id?.objectId ?? "nil")'")

        guard let albumId = await forwardAlbumId(
            from: matchedCandidate.resource,
            matchedItem: matchedCandidate.item,
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId) else {
            SonosLog.info(.playback, "Forward album handoff fallback: album id could not be resolved")
            return nil
        }
        SonosLog.info(.playback, "Forward album handoff resolved albumId='\(albumId)'")

        do {
            let response = try await SonosCloudAPI.browseAlbum(
                token: token,
                householdId: householdId,
                serviceId: serviceId,
                accountId: accountId,
                albumId: albumId,
                count: AppleMusicForwardAlbumQueuePlanner.defaultMaxItems)
            let albumTitle = response.title ?? matchedCandidate.item.album
            let fallbackArtURL = response.images?.tile1x1
                ?? matchedCandidate.item.albumArtURL
                ?? matchedCandidate.resource.container?.images?.first?.url
                ?? matchedCandidate.resource.images?.first?.url
            let albumTracks = response.tracks?.items ?? response.section?.items ?? []
            let candidates = albumTracks.compactMap {
                forwardAlbumCandidate(
                    from: $0,
                    fallbackAlbumTitle: albumTitle,
                    fallbackArtURL: fallbackArtURL,
                    serviceId: serviceId,
                    accountId: accountId)
            }
            SonosLog.info(
                .playback,
                "Forward album handoff browsed album='\(albumTitle)' " +
                "rawTracks=\(albumTracks.count) candidates=\(candidates.count)")

            guard let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
                albumTracks: candidates,
                matchedItem: matchedCandidate.item,
                sourceTrack: sourceTrack) else {
                let matchedStoreID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: matchedCandidate.item) ?? "nil"
                let preview = candidates.prefix(5).map {
                    "\($0.ordinal.map(String.init) ?? "?"):\($0.item.title):" +
                    "\(SonosAppleMusicTrackResolver.storeID(fromBrowseItem: $0.item) ?? "nil")"
                }.joined(separator: " | ")
                SonosLog.info(
                    .playback,
                    "Forward album handoff fallback: planner returned nil " +
                    "matchedStoreID=\(matchedStoreID) candidatesPreview=\(preview)")
                return nil
            }

            SonosLog.info(
                .playback,
                "Forward album handoff plan ready: tracks=\(plan.transferredTrackCount) " +
                "target=\(plan.targetTrackNumber) skipped=\(plan.skippedUnsupportedItemCount)")
            return ForwardAlbumQueueAttempt(plan: plan)
        } catch {
            SonosLog.error(.cloudAPI, "Forward handoff album browse failed: \(error)")
            return nil
        }
    }

    func playForwardAlbumQueue(
        _ plan: AppleMusicForwardAlbumQueuePlan,
        sourceTrack: AppleMusicHandoffTrack,
        selectedSpeaker: SonosPlayer,
        backend: SonosControl.Backend,
        manager: SonosManager
    ) async throws -> (played: Bool, seeked: Bool) {
        guard case .lan(let ip, _, let speakerUUID) = backend else { return (false, false) }

        do {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            let currentPlayMode = try? await SonosAPI.getPlayMode(ip: ip)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            if currentPlayMode?.shuffle == true {
                do {
                    try await SonosAPI.setPlayMode(
                        ip: ip,
                        shuffle: false,
                        repeat: currentPlayMode?.repeat ?? .off)
                } catch {
                    SonosLog.error(.playback, "Forward album queue shuffle disable failed: \(error)")
                }
                try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            }

            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.removeAllTracksFromQueue(ip: ip)

            let queueItems = plan.items.compactMap { item in
                item.playbackDescriptor.queuePayload(metadata: playbackMetadata(for: item))
            }

            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            for item in queueItems {
                try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                _ = try await SonosAPI.addURIToQueue(
                    ip: ip,
                    uri: item.uri,
                    metadata: item.metadata)
            }
            SonosLog.info(.playback, "Forward album queue singleItem add finished count=\(queueItems.count)")

            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.setAVTransportToQueue(
                ip: ip,
                speakerUUID: speakerUUID)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.seekToTrack(
                ip: ip,
                trackNumber: plan.targetTrackNumber)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.play(ip: ip)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)

            var didSeek = false
            if sourceTrack.position > 3 {
                try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                let maxPosition = sourceTrack.duration.map {
                    max(0, min(sourceTrack.position, $0 - 2))
                } ?? sourceTrack.position
                do {
                    try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
                    try await SonosAPI.seek(
                        ip: ip,
                        position: SonosTime.apiFormat(maxPosition))
                    didSeek = true
                } catch {
                    SonosLog.error(.playback, "Forward album queue seek failed: \(error)")
                }
            }

            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            try await refreshForwardHandoffState(
                selectedSpeaker: selectedSpeaker,
                backend: backend,
                manager: manager,
                loadQueue: true)
            return (true, didSeek)
        } catch let error as HandoffTransferError {
            throw error
        } catch {
            SonosLog.error(.playback, "Forward album queue handoff failed: \(error)")
            errorMessage = error.localizedDescription
            return (false, false)
        }
    }

    func batchQueueFallbackItems(from queueItems: [SonosQueuedURI],
                                         after error: Error,
                                         context: String) -> [SonosQueuedURI] {
        guard let batchError = error as? SonosQueueBatchAddError else {
            SonosLog.info(
                .playback,
                "\(context) batch queue fallback path=fullRetry count=\(queueItems.count) " +
                    "errorType=\(type(of: error))")
            return queueItems
        }

        SonosLog.info(
            .playback,
            "\(context) batch queue fallback path=remainingRetry originalCount=\(queueItems.count) " +
                "retryCount=\(batchError.remainingItems.count) failedChunkStart=\(batchError.failedChunkStart)")
        return batchError.remainingItems
    }

    func cancelReplaceQueueBackgroundFill(reason: String) {
        let hadTask = replaceQueueFillTask != nil
        replaceQueueFillTask?.cancel()
        replaceQueueFillTask = nil
        replaceQueueFillGeneration += 1
        if hadTask {
            SonosLog.info(
                .playback,
                "replaceQueue backgroundFill cancel reason='\(reason)' generation=\(replaceQueueFillGeneration)")
        }
    }

    func replaceQueueAndPlayAudioFirst(ip: String,
                                               speakerUUID: String,
                                               plan: SonosQueueReplacementPlaybackPlan,
                                               manager: SonosManager,
                                               context: String) async throws {
        cancelReplaceQueueBackgroundFill(reason: "\(context) audioFirst start")
        let generation = replaceQueueFillGeneration

        SonosLog.info(
            .playback,
            "\(context) replaceQueue audioFirst start total=\(plan.totalCount) " +
                "remaining=\(plan.remaining.count) firstURI=\(SonosLog.playbackLinkValue(plan.first.uri))")

        let removeStart = Date()
        try await SonosAPI.removeAllTracksFromQueue(ip: ip)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=remove-queue " +
                "ms=\(Int(Date().timeIntervalSince(removeStart) * 1000))")

        let addFirstStart = Date()
        let firstTrack = try await SonosAPI.addURIToQueue(
            ip: ip,
            uri: plan.first.uri,
            metadata: plan.first.metadata)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=add-first " +
                "track=\(firstTrack) ms=\(Int(Date().timeIntervalSince(addFirstStart) * 1000))")

        let setQueueStart = Date()
        try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: speakerUUID)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=set-transport-queue " +
                "ms=\(Int(Date().timeIntervalSince(setQueueStart) * 1000))")

        let seekStart = Date()
        try await SonosAPI.seekToTrack(ip: ip, trackNumber: firstTrack)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=seek-first " +
                "track=\(firstTrack) ms=\(Int(Date().timeIntervalSince(seekStart) * 1000))")

        let playStart = Date()
        try await SonosAPI.play(ip: ip)
        SonosLog.info(
            .playback,
            "\(context) replaceQueue step=play-first " +
                "ms=\(Int(Date().timeIntervalSince(playStart) * 1000))")

        let fillPlayMode = try? await SonosAPI.getPlayMode(ip: ip)
        let reshuffleBackgroundBatches = fillPlayMode?.shuffle == true
        if reshuffleBackgroundBatches {
            SonosLog.info(
                .playback,
                "\(context) replaceQueue backgroundFill shuffle enabled batchSize=" +
                    "\(SonosQueueReplacementPlaybackPlan.defaultBackgroundBatchSize)")
        }

        startReplaceQueueBackgroundFill(
            ip: ip,
            speakerUUID: speakerUUID,
            batches: plan.remainingBatches(),
            manager: manager,
            generation: generation,
            reshuffleAfterEachBatch: reshuffleBackgroundBatches,
            repeatMode: fillPlayMode?.repeat ?? .off,
            context: context)
    }

    func startReplaceQueueBackgroundFill(ip: String,
                                                 speakerUUID: String,
                                                 batches: [[SonosQueuedURI]],
                                                 manager: SonosManager,
                                                 generation: Int,
                                                 reshuffleAfterEachBatch: Bool,
                                                 repeatMode: RepeatMode,
                                                 context: String) {
        guard !batches.isEmpty else {
            SonosLog.info(.playback, "\(context) replaceQueue backgroundFill skipped empty")
            replaceQueueFillTask = nil
            return
        }

        replaceQueueFillTask = Task { [weak self, weak manager] in
            guard let self, let manager else { return }
            try? await Task.sleep(for: .milliseconds(300))
            await self.fillReplaceQueueInBackground(
                ip: ip,
                speakerUUID: speakerUUID,
                batches: batches,
                manager: manager,
                generation: generation,
                reshuffleAfterEachBatch: reshuffleAfterEachBatch,
                repeatMode: repeatMode,
                context: context)
        }
    }

    func fillReplaceQueueInBackground(ip: String,
                                              speakerUUID: String,
                                              batches: [[SonosQueuedURI]],
                                              manager: SonosManager,
                                              generation: Int,
                                              reshuffleAfterEachBatch: Bool,
                                              repeatMode: RepeatMode,
                                              context: String) async {
        guard isReplaceQueueBackgroundFillCurrent(
            ip: ip,
            generation: generation,
            speakerUUID: speakerUUID,
            manager: manager
        ) else {
            SonosLog.info(.playback, "\(context) replaceQueue backgroundFill cancelled before start")
            return
        }

        SonosLog.info(
            .playback,
            "\(context) replaceQueue backgroundFill start batches=\(batches.count) " +
                "count=\(batches.reduce(0) { $0 + $1.count }) " +
                "batchSize=\(SonosQueueReplacementPlaybackPlan.defaultBackgroundBatchSize) " +
                "reshuffle=\(reshuffleAfterEachBatch) generation=\(generation)")

        for (batchIndex, batch) in batches.enumerated() {
            guard isReplaceQueueBackgroundFillCurrent(
                ip: ip,
                generation: generation,
                speakerUUID: speakerUUID,
                manager: manager
            ) else {
                SonosLog.info(
                    .playback,
                    "\(context) replaceQueue backgroundFill cancelled before batch " +
                        "\(batchIndex + 1)/\(batches.count)")
                return
            }

            if SonosQueueReplacementPlaybackPlan.defaultBackgroundBatchSize <= 1 {
                let addedCount = await addReplaceQueueFallbackItems(
                    ip: ip,
                    items: batch,
                    originalBatchSize: batch.count,
                    batchIndex: batchIndex,
                    batchCount: batches.count,
                    speakerUUID: speakerUUID,
                    generation: generation,
                    manager: manager,
                    context: context)
                if addedCount == nil { return }
            } else {
                do {
                    try await SonosAPI.addMultipleURIsToQueue(
                        ip: ip,
                        items: batch,
                        chunkSize: SonosQueueReplacementPlaybackPlan.defaultBackgroundBatchSize)
                    SonosLog.info(
                        .playback,
                        "\(context) replaceQueue backgroundFill batch success " +
                            "batch=\(batchIndex + 1)/\(batches.count) count=\(batch.count)")
                } catch {
                    let fallbackItems = batchQueueFallbackItems(
                        from: batch,
                        after: error,
                        context: "\(context) backgroundFill batch \(batchIndex + 1)")
                    SonosLog.error(
                        .playback,
                        "\(context) replaceQueue backgroundFill batch failed, falling back " +
                            "batch=\(batchIndex + 1)/\(batches.count) retryCount=\(fallbackItems.count): \(error)")
                    let addedCount = await addReplaceQueueFallbackItems(
                        ip: ip,
                        items: fallbackItems,
                        originalBatchSize: batch.count,
                        batchIndex: batchIndex,
                        batchCount: batches.count,
                        speakerUUID: speakerUUID,
                        generation: generation,
                        manager: manager,
                        context: context)
                    if addedCount == nil {
                        return
                    }
                }
            }

            if reshuffleAfterEachBatch {
                do {
                    try await SonosAPI.setPlayMode(ip: ip, shuffle: true, repeat: repeatMode)
                    SonosLog.info(
                        .playback,
                        "\(context) replaceQueue backgroundFill reshuffle " +
                            "batch=\(batchIndex + 1)/\(batches.count)")
                } catch {
                    SonosLog.error(
                        .playback,
                        "\(context) replaceQueue backgroundFill reshuffle failed " +
                            "batch=\(batchIndex + 1)/\(batches.count) error=\(error)")
                }
            }
        }

        guard isReplaceQueueBackgroundFillCurrent(
            ip: ip,
            generation: generation,
            speakerUUID: speakerUUID,
            manager: manager
        ) else {
            SonosLog.info(.playback, "\(context) replaceQueue backgroundFill cancelled after fill")
            return
        }
        await manager.loadQueue()
    }

    func addReplaceQueueFallbackItems(ip: String,
                                              items: [SonosQueuedURI],
                                              originalBatchSize: Int,
                                              batchIndex: Int,
                                              batchCount: Int,
                                              speakerUUID: String,
                                              generation: Int,
                                              manager: SonosManager,
                                              context: String) async -> Int? {
        var remainingItems = items
        var addedCount = 0

        for retryBatchSize in SonosQueueReplacementPlaybackPlan.fallbackBatchSizes(
            afterFailedBatchSize: originalBatchSize
        ) where remainingItems.count > 1 {
            guard isReplaceQueueBackgroundFillCurrent(
                ip: ip,
                generation: generation,
                speakerUUID: speakerUUID,
                manager: manager
            ) else {
                SonosLog.info(
                    .playback,
                    "\(context) replaceQueue backgroundFill cancelled during retryBatch " +
                        "batch=\(batchIndex + 1)/\(batchCount) added=\(addedCount)")
                return nil
            }

            let retryCount = remainingItems.count
            do {
                try await SonosAPI.addMultipleURIsToQueue(
                    ip: ip,
                    items: remainingItems,
                    chunkSize: retryBatchSize)
                addedCount += retryCount
                SonosLog.info(
                    .playback,
                    "\(context) replaceQueue backgroundFill retryBatch success " +
                        "batch=\(batchIndex + 1)/\(batchCount) " +
                        "chunkSize=\(retryBatchSize) added=\(retryCount)")
                remainingItems.removeAll()
                break
            } catch let error as SonosQueueBatchAddError {
                let succeededCount = max(0, retryCount - error.remainingItems.count)
                addedCount += succeededCount
                remainingItems = error.remainingItems
                SonosLog.error(
                    .playback,
                    "\(context) replaceQueue backgroundFill retryBatch failed " +
                        "batch=\(batchIndex + 1)/\(batchCount) " +
                        "chunkSize=\(retryBatchSize) succeeded=\(succeededCount) " +
                        "remaining=\(remainingItems.count) error=\(error)")
            } catch {
                SonosLog.error(
                    .playback,
                    "\(context) replaceQueue backgroundFill retryBatch failed " +
                        "batch=\(batchIndex + 1)/\(batchCount) " +
                        "chunkSize=\(retryBatchSize) remaining=\(remainingItems.count) error=\(error)")
            }
        }

        let singleFallbackCount = remainingItems.count
        for item in remainingItems {
            guard isReplaceQueueBackgroundFillCurrent(
                ip: ip,
                generation: generation,
                speakerUUID: speakerUUID,
                manager: manager
            ) else {
                SonosLog.info(
                    .playback,
                    "\(context) replaceQueue backgroundFill cancelled during singleItem fallback " +
                        "batch=\(batchIndex + 1)/\(batchCount) added=\(addedCount)")
                return nil
            }
            do {
                _ = try await SonosAPI.addURIToQueue(
                    ip: ip,
                    uri: item.uri,
                    metadata: item.metadata)
                addedCount += 1
            } catch {
                SonosLog.error(
                    .playback,
                    "\(context) replaceQueue backgroundFill singleItem fallback failed " +
                        "batch=\(batchIndex + 1)/\(batchCount) " +
                        "uri=\(SonosLog.playbackLinkValue(item.uri)) error=\(error)")
            }
        }

        SonosLog.info(
            .playback,
            "\(context) replaceQueue backgroundFill fallback finished " +
                "batch=\(batchIndex + 1)/\(batchCount) added=\(addedCount)/\(items.count) " +
                "singleFallbackCount=\(singleFallbackCount)")
        return addedCount
    }

    func isReplaceQueueBackgroundFillCurrent(ip: String,
                                                     generation: Int,
                                                     speakerUUID: String,
                                                     manager: SonosManager) -> Bool {
        !Task.isCancelled
            && replaceQueueFillGeneration == generation
            && manager.selectedSpeaker?.id == speakerUUID
            && manager.selectedSpeaker?.playbackIP == ip
    }

    func playCloudForwardTrack(
        item: BrowseItem,
        token: String,
        groupId: String,
        backend: SonosControl.Backend,
        selectedSpeaker: SonosPlayer,
        manager: SonosManager
    ) async throws -> Bool {
        pushRecentlyPlayed(item)
        guard let uri = item.playbackDescriptor.directURI else {
            SonosLog.error(.playback, "Cloud forward handoff: no URI for '\(item.title)'")
            errorMessage = "The Apple Music track could not be loaded remotely."
            return false
        }

        do {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            SonosLog.debug(.playback, "remote forward handoff -> loadStreamUrl(\(item.id))")
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosCloudAPI.loadStreamUrl(
                token: token,
                groupId: groupId,
                streamUrl: uri,
                itemId: item.id)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            try await refreshForwardHandoffState(
                selectedSpeaker: selectedSpeaker,
                backend: backend,
                manager: manager,
                loadQueue: false)
            return true
        } catch let error as HandoffTransferError {
            throw error
        } catch {
            SonosLog.error(.playback, "Cloud forward handoff loadStreamUrl failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    func playForwardSingleTrack(
        item: BrowseItem,
        selectedSpeaker: SonosPlayer,
        backend: SonosControl.Backend,
        manager: SonosManager
    ) async throws -> Bool {
        guard case .lan(let ip, _, let speakerUUID) = backend else { return false }

        pushRecentlyPlayed(item)
        let metadata = playbackMetadata(for: item)
        guard let payload = item.playbackDescriptor.queuePayload(metadata: metadata) else {
            SonosLog.error(.playback, "Forward handoff: no URI for '\(item.title)'")
            return false
        }

        do {
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try? await SonosAPI.removeAllTracksFromQueue(ip: ip)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            let trackNr = try await SonosAPI.addURIToQueue(
                ip: ip,
                uri: payload.uri,
                metadata: payload.metadata)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: speakerUUID)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.seekToTrack(ip: ip, trackNumber: trackNr)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            try await SonosAPI.play(ip: ip)
            try ensureForwardHandoffTargetStillSelected(selectedSpeaker, manager: manager)
            SonosLog.info(.playback, "forward handoff queue '\(item.title)' -> track \(trackNr)")

            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            try await refreshForwardHandoffState(
                selectedSpeaker: selectedSpeaker,
                backend: backend,
                manager: manager,
                loadQueue: true)
            return true
        } catch let error as HandoffTransferError {
            throw error
        } catch {
            SonosLog.error(.playback, "Forward handoff play failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

}
