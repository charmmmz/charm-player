import Foundation
import SwiftUI

extension SearchManager {

    func playNow(item: BrowseItem, manager: SonosManager) async {
        _ = await playNowInternal(item: item, manager: manager)
    }

    @discardableResult
    func playNow(
        items: [BrowseItem],
        manager: SonosManager,
        displayTitle: String
    ) async -> Bool {
        let queueableItems = items.filter { item in
            item.playbackDescriptor.isQueueable
        }
        guard !queueableItems.isEmpty else {
            errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
            return false
        }

        guard !manager.isRemoteMode else {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Playing this item")
                .localizedDescription
            return false
        }
        guard let speaker = manager.selectedSpeaker else {
            errorMessage = HandoffTransferError.noSelectedSpeaker.localizedDescription
            return false
        }

        let ip = speaker.playbackIP
        let speakerUUID = speaker.id
        let playbackItems = await appleMusicLibraryTrackPlaybackResolver.resolvedItems(queueableItems)
        let queueItems = playbackItems.compactMap {
            $0.playbackDescriptor.queuePayload(metadata: playbackMetadata(for: $0))
        }
        guard let replacementPlan = SonosQueueReplacementPlaybackPlan(items: queueItems) else {
            errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
            return false
        }
        schedulePlaybackArtworkPrewarm(for: playbackItems)
        SonosLog.debug(
            .playbackLink,
            "playNow displayed-tracks start title='\(displayTitle)' count=\(queueItems.count) " +
                "speaker=\(ip) firstURI=\(SonosLog.playbackLinkValue(queueItems.first?.uri)) " +
                "lastURI=\(SonosLog.playbackLinkValue(queueItems.last?.uri)) " +
                "firstMetadata=\(queueItems.first.map { SonosLog.playbackMetadataSummary($0.metadata) } ?? "nil")")

        if let first = playbackItems.first {
            pushRecentlyPlayed(first)
        }

        do {
            try await replaceQueueAndPlayAudioFirst(
                ip: ip,
                speakerUUID: speakerUUID,
                plan: replacementPlan,
                manager: manager,
                context: "playNow '\(displayTitle)'")
            SonosLog.info(
                .playback,
                "playNow displayed tracks '\(displayTitle)' count=\(queueItems.count) " +
                    "mode=audioFirst remaining=\(replacementPlan.remaining.count)")
            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            await manager.refreshState()
            return true
        } catch {
            SonosLog.error(.playback, "playNow displayed tracks failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func playNowInternal(
        item: BrowseItem,
        manager: SonosManager,
        lockedTarget: SonosPlayer? = nil,
        recordRecentlyPlayed: Bool = true
    ) async -> Bool {
        // Push to recents before any await so a failed play still records
        // intent (mirrors Apple Music's "attempted plays" behaviour).
        if recordRecentlyPlayed {
            pushRecentlyPlayed(item)
        }
        schedulePlaybackArtworkPrewarm(for: item)
        let activeSpeaker = lockedTarget ?? manager.selectedSpeaker
        let activeBackend = manager.transportBackend
        let activeCloudGroupId = manager.currentCloudGroupId

        // Remote mode: if the item is a cloud-sourced favorite, use the
        // Control API's `loadFavorite` instead of the UPnP SetAVTransportURI
        // / queue path (which doesn't work off-LAN).
        if activeBackend == .cloud,
           let favId = item.cloudFavoriteId,
           let token = await SonosAuth.shared.validAccessToken(),
           let gid = activeCloudGroupId {
            do {
                SonosLog.debug(.playback, "remote playNow → loadFavorite(\(favId))")
                try await SonosCloudAPI.loadFavorite(token: token, groupId: gid,
                                                    favoriteId: favId)
                try? await Task.sleep(for: .milliseconds(800))
                await manager.refreshState()
                return true
            } catch {
                SonosLog.error(.playback, "loadFavorite failed: \(error)")
                errorMessage = error.localizedDescription
                return false
            }
        }

        if item.isArtist {
            return await startStation(item: item, manager: manager)
        }

        // Everything below this line uses UPnP — gate on .cloud mode so users
        // get a friendly "Requires LAN" error instead of a silent timeout.
        if activeBackend == .cloud {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Playing this item")
                .localizedDescription
            return false
        }

        guard let ip = activeSpeaker?.playbackIP else {
            SonosLog.error(.playback, "playNow: no speaker IP")
            return false
        }

        var playMeta = playbackMetadata(for: item)

        // For favorites, the resMD DIDL often lacks albumArtURI — inject it from
        // the browse item so Sonos records proper cover art in "recently played".
        if item.id.hasPrefix("FV:") {
            playMeta = enrichMetadataWithArt(playMeta, artURL: item.albumArtURL)
        }

        let fallbackURI: String?
        if item.playbackDescriptor.directURI == nil, let resMD = item.resMD {
            fallbackURI = constructFavoriteURI(resMD: resMD)
        } else {
            fallbackURI = nil
        }

        guard let playPayload = item.playbackDescriptor.transportPayload(
            metadata: playMeta,
            fallbackURI: fallbackURI
        ) else {
            SonosLog.error(.playback, "playNow: no URI for '\(item.title)'")
            return false
        }
        let uri = playPayload.uri
        playMeta = playPayload.metadata

        let metadataId = extractDIDLItemId(from: playMeta) ?? "nil"
        let metadataDesc = SonosAPI.extractTag("desc", from: playMeta) ?? "nil"
        SonosLog.info(
            .playback,
            "playNow enqueue title='\(item.title)' cloudType=\(item.cloudType ?? "nil") " +
            "itemId=\(item.id) serviceId=\(item.serviceId.map(String.init) ?? "nil") " +
            "uri=\(uri) metadataId=\(metadataId) desc=\(metadataDesc)")
        SonosLog.debug(
            .playbackLink,
            "playNow resolved title='\(item.title)' cloudType=\(item.cloudType ?? "nil") " +
                "itemId=\(SonosLog.playbackLinkValue(item.id, maxLength: 640)) " +
                "serviceId=\(item.serviceId.map(String.init) ?? "nil") " +
                "isContainer=\(item.isContainer) uri=\(SonosLog.playbackLinkValue(uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(playMeta))")
        let playNowStart = Date()

        do {
            guard let uuid = activeSpeaker?.id else {
                SonosLog.error(.playback, "playNow: no speaker UUID")
                return false
            }

            if ReplaceQueueBackgroundFillCancellationPolicy.shouldCancelBeforeForegroundPlayback(transport: .localUPnP) {
                cancelReplaceQueueBackgroundFill(reason: "playNow '\(item.title)' foreground")
            }

            let isRadio = uri.contains("x-sonosapi-radio:")
                || uri.contains("x-sonosapi-stream:")
                || uri.contains("x-sonosapi-hls:")

            if isRadio {
                let setURIStart = Date()
                try await SonosAPI.setAVTransportURI(ip: ip, uri: uri, metadata: playMeta)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=set-radio-uri " +
                    "ms=\(Int(Date().timeIntervalSince(setURIStart) * 1000))")
                let playStart = Date()
                try await SonosAPI.play(ip: ip)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=radio-play " +
                    "ms=\(Int(Date().timeIntervalSince(playStart) * 1000))")
                SonosLog.info(.playback, "playNow radio '\(item.title)'")
            } else {
                // Both container and single-track paths take the same shape
                // — only the source URI differs. Fold them to keep the log
                // story simple ("playNow queue → track N").
                let removeStart = Date()
                try? await SonosAPI.removeAllTracksFromQueue(ip: ip)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=remove-queue " +
                    "ms=\(Int(Date().timeIntervalSince(removeStart) * 1000))")
                let addStart = Date()
                let trackNr = try await SonosAPI.addURIToQueue(ip: ip, uri: uri, metadata: playMeta)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=add-uri-to-queue " +
                    "ms=\(Int(Date().timeIntervalSince(addStart) * 1000))")
                let setQueueStart = Date()
                try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: uuid)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=set-transport-queue " +
                    "ms=\(Int(Date().timeIntervalSince(setQueueStart) * 1000))")
                let seekStart = Date()
                try await SonosAPI.seekToTrack(ip: ip, trackNumber: trackNr)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=seek-track " +
                    "ms=\(Int(Date().timeIntervalSince(seekStart) * 1000))")
                let playStart = Date()
                try await SonosAPI.play(ip: ip)
                SonosLog.info(
                    .playback,
                    "playNow timing title='\(item.title)' step=queue-play " +
                    "ms=\(Int(Date().timeIntervalSince(playStart) * 1000))")
                SonosLog.info(.playback, "playNow queue '\(item.title)' → track \(trackNr)")
            }

            let settleStart = Date()
            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            SonosLog.info(
                .playback,
                "playNow timing title='\(item.title)' step=settle-delay " +
                "ms=\(Int(Date().timeIntervalSince(settleStart) * 1000))")
            let refreshStart = Date()
            await manager.refreshState()
            SonosLog.info(
                .playback,
                "playNow timing title='\(item.title)' step=refresh-state " +
                "ms=\(Int(Date().timeIntervalSince(refreshStart) * 1000)) " +
                "totalMs=\(Int(Date().timeIntervalSince(playNowStart) * 1000))")
            return true
        } catch {
            SonosLog.error(.playback, "playNow failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }


    @discardableResult
    func playNext(item: BrowseItem, manager: SonosManager) async -> Bool {
        schedulePlaybackArtworkPrewarm(for: item)
        // Queue insertion is LAN-only (Cloud Control API has no per-track
        // queue API). Show a friendly message instead of a stale timeout.
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Adding to the queue")
                .localizedDescription
            return false
        }
        let metadata = playbackMetadata(for: item)
        guard let payload = item.playbackDescriptor.queuePayload(metadata: metadata) else {
            errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
            return false
        }
        SonosLog.debug(
            .playbackLink,
            "playNext item title='\(item.title)' cloudType=\(item.cloudType ?? "nil") " +
                "itemId=\(SonosLog.playbackLinkValue(item.id, maxLength: 640)) " +
                "serviceId=\(item.serviceId.map(String.init) ?? "nil") " +
                "isContainer=\(item.isContainer) uri=\(SonosLog.playbackLinkValue(payload.uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(payload.metadata))")
        return await manager.playNext(uri: payload.uri, metadata: payload.metadata)
    }

    /// Start a personalized radio station from an artist.
    /// Searches Cloud API for the artist's Apple Music ID, then constructs radio:ra.{id}
    /// — the same format the official Sonos app uses for "Start Station".
    @discardableResult
    func startStation(item: BrowseItem, manager: SonosManager) async -> Bool {
        // Push to recents before network work so Browse shows the entry
        // even if cloud search below fails. Dedupes by id — safe to repeat.
        pushRecentlyPlayed(item)

        guard let ip = manager.selectedSpeaker?.playbackIP else {
            SonosLog.error(.station, "startStation: no speaker IP")
            return false
        }

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            SonosLog.error(.station, "startStation: no Cloud auth")
            errorMessage = "Not logged in to Sonos Cloud"
            return false
        }

        if !hasProbed { await probeLinkedServices() }
        let serviceIds = activeServiceIds
        guard !serviceIds.isEmpty else {
            SonosLog.error(.station, "startStation: no active services")
            errorMessage = "No music services linked"
            return false
        }

        do {
            let response = try await SonosCloudAPI.searchCatalog(
                token: token, householdId: householdId,
                term: item.title, serviceIds: serviceIds)

            // Find the ARTIST result to get the Apple Music artist ID
            var artistId: String?
            var cloudServiceId: String?
            var cloudAccountId: String?
            var artistArtURL: String?

            for svc in response.services ?? [] {
                for resource in svc.resources ?? [] {
                    let type = resource.type ?? ""
                    let objId = resource.id?.objectId ?? ""
                    let name = resource.name ?? ""

                    if type == "ARTIST" && name.localizedCaseInsensitiveCompare(item.title) == .orderedSame {
                        // Extract the numeric ID: "artist:137938148" → "137938148"
                        artistId = objId.replacingOccurrences(of: "artist:", with: "")
                        cloudServiceId = svc.serviceId
                        cloudAccountId = svc.accountId
                        artistArtURL = resource.images?.first?.url ?? item.albumArtURL
                        break
                    }
                }
                if artistId != nil { break }
            }

            // Fallback: take any ARTIST result if exact name match failed
            if artistId == nil {
                for svc in response.services ?? [] {
                    for resource in svc.resources ?? [] {
                        if resource.type == "ARTIST", let objId = resource.id?.objectId,
                           objId.hasPrefix("artist:") {
                            artistId = objId.replacingOccurrences(of: "artist:", with: "")
                            cloudServiceId = svc.serviceId
                            cloudAccountId = svc.accountId
                            artistArtURL = resource.images?.first?.url ?? item.albumArtURL
                            break
                        }
                    }
                    if artistId != nil { break }
                }
            }

            guard let amArtistId = artistId else {
                SonosLog.error(.station, "No artist found in search results")
                errorMessage = "Could not find artist \(item.title)"
                return false
            }

            // Construct radio:ra.{artist_id} — this is the "Start Station" format
            let radioId = "radio:ra.\(amArtistId)"
            let stationName = "\(item.title) Radio"

            return await playRadioStation(
                ip: ip, radioId: radioId, stationName: stationName,
                cloudServiceId: cloudServiceId, accountId: cloudAccountId,
                artURL: artistArtURL, resMD: item.resMD, manager: manager)

        } catch {
            SonosLog.error(.station, "startStation failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Play a selected radio station option (from station picker).
    func playStationOption(_ option: RadioStationOption, manager: SonosManager) async {
        guard let ip = manager.selectedSpeaker?.playbackIP else { return }
        _ = await playRadioStation(
            ip: ip, radioId: option.id, stationName: option.name,
            cloudServiceId: option.cloudServiceId, accountId: option.accountId,
            artURL: option.artURL, resMD: option.resMD, manager: manager)
    }

    /// Play a resolved radio station via UPnP.
    func playRadioStation(ip: String, radioId: String, stationName: String,
                                  streamObjectID: String? = nil,
                                  isLiveStreamStation: Bool = false,
                                  cloudServiceId: String?, accountId: String?,
                                  artURL: String?, resMD: String?,
                                  manager: SonosManager) async -> Bool {
        let payloads = stationTransportPayloads(
            radioId: radioId,
            streamObjectID: streamObjectID,
            isLiveStreamStation: isLiveStreamStation,
            stationName: stationName,
            cloudServiceId: cloudServiceId,
            accountId: accountId,
            artURL: artURL,
            resMD: resMD)
        var lastError: Error?

        for (index, payload) in payloads.enumerated() {
            let metadataId = extractDIDLItemId(from: payload.metadata) ?? "nil"
            let metadataDesc = extractDescTag(from: payload.metadata) ?? "nil"
            let hasArt = payload.metadata.contains("<upnp:albumArtURI>")
            SonosLog.info(
                .station,
                "playRadioStation request title='\(stationName)' label=\(payload.label) " +
                    "attempt=\(index + 1)/\(payloads.count) radioId=\(radioId) " +
                    "streamObjectID=\(streamObjectID ?? "nil") uri=\(payload.uri) " +
                    "metadataId=\(metadataId) desc=\(metadataDesc) art=\(hasArt)")

            do {
                try await SonosAPI.setAVTransportURI(ip: ip, uri: payload.uri, metadata: payload.metadata)
                try? await Task.sleep(for: .milliseconds(stationSetURISettleMs))
                try await SonosAPI.play(ip: ip)

                try? await Task.sleep(for: .milliseconds(stationPlayConfirmMs))
                let state = try? await SonosAPI.getTransportInfo(ip: ip)

                if state == .stopped {
                    // Some stations need a second nudge: first Play is acked,
                    // but Sonos sits in STOPPED until the cloud resolves the
                    // actual stream URL.
                    SonosLog.info(.station, "still STOPPED, retrying play label=\(payload.label)")
                    try? await Task.sleep(for: .milliseconds(stationRetryDelayMs))
                    try await SonosAPI.play(ip: ip)
                    try? await Task.sleep(for: .milliseconds(stationRetryDelayMs))
                }

                SonosLog.info(
                    .station,
                    "playRadioStation '\(stationName)' label=\(payload.label) uri=\(payload.uri)")
                await manager.refreshState()
                return true
            } catch {
                lastError = error
                SonosLog.error(
                    .station,
                    "playRadioStation failed label=\(payload.label) uri=\(payload.uri): \(error)")
            }
        }

        errorMessage = lastError?.localizedDescription
        return false
    }

    func stationTransportPayloads(
        radioId: String,
        streamObjectID: String?,
        isLiveStreamStation: Bool = false,
        stationName: String,
        cloudServiceId: String?,
        accountId: String?,
        artURL: String?,
        resMD: String?
    ) -> [StationTransportPayload] {
        var payloads: [StationTransportPayload] = []

        if isLiveStreamStation,
           let hlsObjectID = hlsStationObjectID(from: radioId) {
            payloads.append(
                stationTransportPayload(
                    radioId: hlsObjectID,
                    stationName: stationName,
                    cloudServiceId: cloudServiceId,
                    accountId: accountId,
                    artURL: artURL,
                    resMD: resMD,
                    uriScheme: "x-sonosapi-stream",
                    flags: SonosRinconLiveStationFlags,
                    metadataStyle: .hlsLiveRadio,
                    label: "hlsLiveRadio"))
        }

        payloads.append(
            stationTransportPayload(
                radioId: radioId,
                stationName: stationName,
                cloudServiceId: cloudServiceId,
                accountId: accountId,
                artURL: artURL,
                resMD: resMD,
                uriScheme: "x-sonosapi-radio",
                metadataStyle: .programRadio,
                label: "radioID"))

        return payloads
    }

    func stationTransportPayload(
        radioId: String,
        stationName: String,
        cloudServiceId: String?,
        accountId: String?,
        artURL: String?,
        resMD: String?,
        uriScheme: String = "x-sonosapi-radio",
        flags: Int = SonosRinconRadioFlags,
        metadataStyle: StationTransportMetadataStyle = .programRadio,
        label: String = "radioID"
    ) -> StationTransportPayload {
        let localSid = cloudServiceId.flatMap { cloudToLocalSid[$0] }
        let params = extractServiceParams()
        let sidInt = localSid ?? Int(params?.sid ?? "") ?? 204
        let sid = String(sidInt)
        let sn = accountId ?? params?.sn ?? "0"

        let encodedId = SonosPlayableURIBuilder.encodedObjectID(radioId)
        let radioURI = SonosPlayableURIBuilder.serviceURI(
            scheme: uriScheme,
            objectID: radioId,
            localSid: sidInt,
            flags: flags,
            accountID: sn)

        let descTag: String
        if let fromMD = extractDescTag(from: resMD ?? "") {
            descTag = fromMD
        } else if let cloudServiceId {
            descTag = "SA_RINCON\(cloudServiceId)_\(cloudServiceUsername(for: cloudServiceId, accountId: sn))"
        } else if let sidInt = localSid,
                  let cloudSid = localToCloudSid[sidInt] {
            descTag = "SA_RINCON\(cloudSid)_\(cloudServiceUsername(for: cloudSid, accountId: sn))"
        } else {
            descTag = "SA_RINCON\(sid)_X_#Svc\(sid)-\(sn)-Token"
        }
        let metadataPrefix: String
        let parentID: String
        let upnpClass: String
        let albumArtURI: String?
        switch metadataStyle {
        case .programRadio:
            metadataPrefix = "000c206c"
            parentID = ""
            upnpClass = "object.item.audioItem.audioBroadcast.#programRadio"
            albumArtURI = nil
        case .hlsLiveRadio:
            metadataPrefix = "10092064"
            parentID = ""
            upnpClass = "object.item.audioItem.audioBroadcast"
            albumArtURI = (artURL?.isEmpty == false) ? artURL : nil
        }
        let radioMeta = SonosDIDLBuilder.document([
            SonosDIDLElement(
                id: "\(metadataPrefix)\(encodedId)",
                parentID: parentID,
                title: stationName,
                upnpClass: upnpClass,
                albumArtURI: albumArtURI,
                desc: descTag)
        ])

        return StationTransportPayload(label: label, uri: radioURI, metadata: radioMeta)
    }

    func hlsStationObjectID(from radioId: String) -> String? {
        guard var stationID = normalizedStreamObjectID(radioId) else { return nil }
        if stationID.hasPrefix("hls:") {
            return stationID
        }
        if stationID.hasPrefix("radio:") {
            stationID.removeFirst("radio:".count)
        }
        guard stationID.hasPrefix("ra."), stationID.count > 3 else { return nil }
        return "hls:\(stationID)"
    }

    func normalizedStreamObjectID(_ streamObjectID: String?) -> String? {
        guard var streamObjectID = streamObjectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !streamObjectID.isEmpty else {
            return nil
        }
        streamObjectID = streamObjectID.removingPercentEncoding ?? streamObjectID
        if let fragmentStart = streamObjectID.firstIndex(of: "#") {
            streamObjectID = String(streamObjectID[..<fragmentStart])
        }
        if let queryStart = streamObjectID.firstIndex(of: "?") {
            streamObjectID = String(streamObjectID[..<queryStart])
        }
        streamObjectID = streamObjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        return streamObjectID.isEmpty ? nil : streamObjectID
    }

    func extractDescTag(from xml: String) -> String? {
        guard let start = xml.range(of: "<desc"),
              let contentStart = xml.range(of: ">", range: start.upperBound..<xml.endIndex),
              let end = xml.range(of: "</desc>", range: contentStart.upperBound..<xml.endIndex) else { return nil }
        return String(xml[contentStart.upperBound..<end.lowerBound])
    }

    @discardableResult
    func addToQueue(item: BrowseItem, manager: SonosManager) async -> Bool {
        schedulePlaybackArtworkPrewarm(for: item)
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Adding to the queue")
                .localizedDescription
            return false
        }
        guard let ip = manager.selectedSpeaker?.playbackIP else {
            errorMessage = HandoffTransferError.noSelectedSpeaker.localizedDescription
            return false
        }
        let meta = playbackMetadata(for: item)
        guard let payload = item.playbackDescriptor.queuePayload(metadata: meta) else {
            errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
            return false
        }
        SonosLog.debug(
            .playbackLink,
            "addToQueue item title='\(item.title)' cloudType=\(item.cloudType ?? "nil") " +
                "itemId=\(SonosLog.playbackLinkValue(item.id, maxLength: 640)) " +
                "serviceId=\(item.serviceId.map(String.init) ?? "nil") " +
                "isContainer=\(item.isContainer) uri=\(SonosLog.playbackLinkValue(payload.uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(payload.metadata))")
        do {
            try await SonosAPI.addURIToQueue(ip: ip, uri: payload.uri, metadata: payload.metadata)
            await manager.loadQueue()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Cloud `listFavorites` and UPnP shortcut favorites (artists, some
    /// collections) often ship **without** a top-level `<res>` URI, while
    /// `r:resMD` or DIDL `id` still has everything needed to build the
    /// `x-rincon-cpcontainer:…?sid=…&sn=…` form. `addToFavorites` and navigation
    /// into detail views need that resolved shape or the heart action fails
    /// (`guard` on `uri`) even though the entry is a valid favorite.
    func browseItemWithResolvedFavoriteURI(
        _ item: BrowseItem,
        preserveArtworkSize: Bool = false
    ) -> BrowseItem? {
        if item.playbackDescriptor.directURI != nil {
            guard preserveArtworkSize,
                  item.detailArtworkURL == nil,
                  let detailArtworkURL = item.preferredDetailArtworkURL else {
                return item
            }
            var enriched = item
            enriched.albumArtURL = ArtworkURLNormalizer.loadableURLString(
                from: detailArtworkURL,
                shortSidePixels: 400
            ) ?? item.albumArtURL
            enriched.detailArtworkURL = detailArtworkURL
            return enriched
        }
        guard let ids = parseCloudIds(from: item) else { return nil }
        let typeString: String? = item.cloudType ?? favoriteCategoryAsCloudType(item)
        guard let ts = typeString, let kind = CloudObjectType(rawValue: ts) else { return nil }
        let oid = ids.objectId
        let cloudSid = ids.cloudServiceId
        let aid = ids.accountId
        switch kind {
        case .artist:
            return makeArtistItem(
                objectId: oid, name: item.title, artURL: item.preferredDetailArtworkURL,
                cloudServiceId: cloudSid, accountId: aid,
                preserveArtworkSize: preserveArtworkSize)
        case .album:
            return makeAlbumItem(
                objectId: oid, title: item.title, artist: item.artist,
                artURL: item.preferredDetailArtworkURL,
                cloudServiceId: cloudSid, accountId: aid,
                preserveArtworkSize: preserveArtworkSize)
        case .playlist:
            return makePlaylistItem(
                objectId: oid, title: item.title, artist: item.artist,
                artURL: item.albumArtURL,
                cloudServiceId: cloudSid, accountId: aid)
        case .track:
            return makeTrackItem(
                objectId: oid, title: item.title, artist: item.artist,
                album: item.album, artURL: item.albumArtURL,
                mimeType: nil,
                cloudServiceId: cloudSid, accountId: aid)
        case .program:
            return makeStationItem(
                objectId: oid, title: item.title, artistName: item.artist,
                artURL: item.albumArtURL,
                cloudServiceId: cloudSid, accountId: aid)
        case .collection:
            return nil
        }
    }

    func favoriteCategoryAsCloudType(_ item: BrowseItem) -> String? {
        switch item.favoriteCategory {
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .playlist: return "PLAYLIST"
        case .collection: return "COLLECTION"
        case .station: return "PROGRAM"
        case .song: return "TRACK"
        }
    }

}
