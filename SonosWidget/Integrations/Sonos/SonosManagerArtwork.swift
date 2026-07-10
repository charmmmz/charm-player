import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    // MARK: - Private Helpers

    func syncSpeakerToStorage(_ speaker: SonosPlayer) {
        SharedStorage.speakerID = speaker.id
        SharedStorage.speakerIP = speaker.ipAddress
        SharedStorage.speakerName = speaker.name
        SharedStorage.coordinatorIP = speaker.coordinatorIP
    }

    func updateSharedCache() {
        let currentTitle = trackInfo?.title
        let trackChanged = currentTitle != lastWidgetTrackTitle

        SharedStorage.isPlaying = isPlaying
        SharedStorage.cachedTrackTitle = trackInfo?.title
        SharedStorage.cachedArtist = trackInfo?.artist
        SharedStorage.cachedAlbum = trackInfo?.album
        SharedStorage.cachedAlbumArtURL = trackInfo?.albumArtURL
        SharedStorage.cachedVolume = volume
        SharedStorage.cachedPlaybackSource = trackInfo?.source.rawValue
        // Music tracks ship `audioQuality` (Atmos / Lossless / Hi-Res …). TV
        // input has no `audioQuality` at all — its parallel is `tvFormat`.
        // Reuse the same widget cache slot so the home/medium widgets and
        // Live Activity can surface the format string ("Dolby Atmos · MAT",
        // "Multichannel PCM · 5.1", …) and the Atmos badge logic, which
        // already keys off `label.contains("atmos")`, still picks up the
        // right mark.
        let audioQualityLabel = trackInfo?.audioQuality?.label
            ?? trackInfo?.tvFormat?.geekLabel
        SharedStorage.cachedAudioQualityLabel = audioQualityLabel
        logLiveActivity(action: "quality-cache-write",
                        extra: [
                            "track=\(Self.liveActivityLogValue(trackInfo?.title ?? "nil"))",
                            "source=\(trackInfo?.source.rawValue ?? "nil")",
                            "trackQuality=\(Self.liveActivityLogValue(trackInfo?.audioQuality?.label ?? "nil"))",
                            "tvFormat=\(Self.liveActivityLogValue(trackInfo?.tvFormat?.geekLabel ?? "nil"))",
                            "cachedQuality=\(Self.liveActivityLogValue(audioQualityLabel ?? "nil"))",
                            "relayAvailable=\(RelayManager.shared.isAvailable)",
                            "relayWriterReady=\(liveActivityRelayWriterReady)"
                        ])
        SharedStorage.cachedIsLiveStream = trackInfo?.isLiveStream ?? false
        if trackInfo?.source == .tv {
            SharedStorage.cachedSoundbarNightMode = nightMode
            SharedStorage.cachedSoundbarSpeechEnhancementRawLevel = speechEnhancement.rawValue
        }
        SharedStorage.cachedGroupMemberCount = currentGroupMembers.filter { !$0.isInvisible }.count
        // Keep cloudGroupId in sync so the widget can call Cloud API independently.
        if let gid = cloudGroupId { SharedStorage.cloudGroupId = gid }

        // Reload widget only when something meaningful changed (track, play state).
        if trackChanged || isPlaying != SharedStorage.isPlaying {
            lastWidgetTrackTitle = currentTitle
            WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        }

    }

    func logAudioQualityDiagnostic(action: String, extra: [String] = []) {
        var parts = [
            "audio_quality_diag",
            "action=\(action)",
            "track=\(Self.liveActivityLogValue(trackInfo?.title ?? "nil"))",
            "artist=\(Self.liveActivityLogValue(trackInfo?.artist ?? "nil"))",
            "source=\(trackInfo?.source.rawValue ?? "nil")",
            "relayStatus=\(liveActivityRelayStatusLogValue())"
        ]
        parts.append(contentsOf: extra)
        SonosLog.info(.sonosCloud, parts.joined(separator: " "))
    }

    static func isAppleMusicQueueItem(_ item: QueueItem) -> Bool {
        let candidates = [item.uri, item.albumArtURL, item.metaXML]
        if candidates.compactMap({ $0 }).contains(where: {
            PlaybackSource.from(trackURI: $0) == .appleMusic || $0.localizedCaseInsensitiveContains("sid=204")
        }) {
            return true
        }
        return false
    }

    func resolveCurrentAppleMusicArtworkIfNeeded() async {
        guard let info = trackInfo,
              info.source == .appleMusic else {
            return
        }
        let currentURLString = info.albumArtURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let needsFallback = currentURLString.isEmpty || QueueArtPrefetchPolicy.isLocalSonosArtworkURL(currentURLString)
        if !needsFallback {
            let displayURLString = PlaybackArtworkImageSize.nowPlayingURLString(from: currentURLString)
            if displayURLString != currentURLString {
                trackInfo?.albumArtURL = displayURLString
            }
            SonosLog.debug(
                .nowPlaying,
                "Current artwork fallback skip_url_resolution reason=public_artwork " +
                    "url=\(SonosLog.playbackLinkValue(displayURLString, maxLength: 240))")
        }

        let originalTrackIdentity = AlbumArtTrackIdentity.make(from: info)
        let catalogID = SonosAppleMusicTrackResolver.storeID(fromTrackURI: info.trackURI)
        let request = PlaybackArtworkRequest(
            service: .appleMusic,
            kind: .song,
            catalogID: catalogID,
            title: info.title,
            artist: info.artist,
            album: info.album,
            currentArtworkURLString: info.albumArtURL,
            identity: .trackInfo(info),
            countryCode: Self.defaultArtworkCountryCode
        )

        SonosLog.debug(
            .nowPlaying,
            "Current artwork fallback start title='\(SonosLog.playbackLinkValue(info.title, maxLength: 120))' " +
                "artist='\(SonosLog.playbackLinkValue(info.artist, maxLength: 120))' " +
                "catalogID=\(SonosLog.playbackLinkValue(catalogID, maxLength: 120)) " +
                "current=\(SonosLog.playbackLinkValue(info.albumArtURL, maxLength: 240))")

        guard let resolution = await AppleMusicPlaybackArtworkResolver.shared.resolve(request: request) else {
            SonosLog.debug(.nowPlaying, "Current artwork fallback miss")
            return
        }

        guard AlbumArtTrackIdentity.make(from: trackInfo) == originalTrackIdentity else {
            SonosLog.debug(.nowPlaying, "Current artwork fallback stale result source=\(resolution.source.rawValue)")
            return
        }

        let resolvedURLString = resolution.sizedURLString(
            shortSidePixels: PlaybackArtworkImageSize.nowPlayingShortSidePixels
        )
        trackInfo?.albumArtURL = resolvedURLString
        if let artworkThemeColors = resolution.artworkThemeColors {
            trackInfo?.artworkThemeColors = artworkThemeColors
        }
        SonosLog.debug(
            .nowPlaying,
            "Current artwork fallback hit source=\(resolution.source.rawValue) " +
                "url=\(SonosLog.playbackLinkValue(resolvedURLString, maxLength: 240)) " +
                "colors=\(resolution.artworkThemeColors == nil ? "nil" : "yes")")
    }

    static var defaultArtworkCountryCode: String {
        Locale.current.region?.identifier ?? "US"
    }

    func loadAlbumArt() async {
        var urlStr = trackInfo?.albumArtURL ?? ""
        if trackInfo?.source == .appleMusic,
           !urlStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !QueueArtPrefetchPolicy.isLocalSonosArtworkURL(urlStr) {
            let displayURLString = PlaybackArtworkImageSize.nowPlayingURLString(from: urlStr)
            if displayURLString != urlStr {
                trackInfo?.albumArtURL = displayURLString
                urlStr = displayURLString
            }
        }
        let incomingTrackIdentity = AlbumArtTrackIdentity.make(from: trackInfo)

        // No artwork in the current track — TV input, line-in, idle, etc.
        // Old code `guard let urlStr = ...` short-circuited and the previous
        // album cover would linger on the home-tab speaker card. Treat the
        // empty case as "clear everything" so switching from music → TV
        // properly resets the art (the player view falls back to its `tv`
        // glyph; the home card falls back to the speaker glyph).
        if urlStr.isEmpty {
            let hasDeferredMissingArtwork = deferredMissingAlbumArtTrackIdentity == incomingTrackIdentity
            let shouldClearArtwork = AlbumArtLoadAttemptPolicy.shouldClearArtworkForMissingURL(
                trackSource: trackInfo?.source,
                hasDisplayedArtwork: albumArtImage != nil,
                displayedTrackIdentity: displayedAlbumArtTrackIdentity,
                incomingTrackIdentity: incomingTrackIdentity,
                hasDeferredMissingArtworkForIncomingTrack: hasDeferredMissingArtwork
            )
            guard shouldClearArtwork else {
                loadingAlbumArtURL = nil
                albumArtTask?.cancel()
                deferredMissingAlbumArtTrackIdentity = incomingTrackIdentity
                return
            }
            deferredMissingAlbumArtTrackIdentity = nil
            guard lastAlbumArtURL != "" || albumArtImage != nil else { return }
            lastAlbumArtURL = ""
            loadingAlbumArtURL = nil
            albumArtTask?.cancel()
            withAnimation(.easeInOut(duration: 0.5)) {
                albumArtImage = nil
                displayedAlbumArtTrackIdentity = nil
                albumArtDominantColor = nil
                if let gid = selectedSpeaker?.groupId ?? selectedSpeaker?.id {
                    groupAlbumImages[gid] = nil
                    groupAlbumColors[gid] = nil
                    groupLastArtURL[gid] = nil
                }
            }
            SharedStorage.albumArtData = nil
            SharedStorage.cachedAlbumArtDataURL = nil
            SharedStorage.cachedDominantColorHex = nil
            return
        }

        if albumArtImage == nil,
           let cachedData = AlbumArtSharedCacheRecoveryPolicy.reusableArtworkData(
               currentURLString: urlStr,
               cachedDataURLString: SharedStorage.cachedAlbumArtDataURL,
               cachedData: SharedStorage.albumArtData
           ),
           let cachedImage = UIImage(data: cachedData) {
            albumArtTask?.cancel()
            loadingAlbumArtURL = nil
            let color = dominantColorCache[urlStr] ?? cachedImage.dominantColor()
            applyLoadedAlbumArt(
                cachedImage,
                color: color,
                bottomEdge: cachedImage.bottomEdgeColor(),
                urlString: urlStr,
                trackIdentity: incomingTrackIdentity,
                preserveDisplayedArtwork: false
            )
            SharedStorage.cachedAlbumArtDataURL = urlStr
            SharedStorage.cachedDominantColorHex = cachedImage.dominantColorHex()
            return
        }

        guard AlbumArtLoadAttemptPolicy.shouldStartLoad(
            urlString: urlStr,
            lastLoadedURL: lastAlbumArtURL,
            hasDisplayedArtwork: albumArtImage != nil,
            loadingURL: loadingAlbumArtURL
        ) else {
            return
        }
        deferredMissingAlbumArtTrackIdentity = nil
        let shouldPreserveDisplayedArtwork = AlbumArtRefreshPolicy.shouldPreserveDisplayedArtwork(
            hasDisplayedArtwork: albumArtImage != nil,
            displayedTrackIdentity: displayedAlbumArtTrackIdentity,
            incomingTrackIdentity: incomingTrackIdentity
        )
        loadingAlbumArtURL = urlStr
        albumArtTask?.cancel()

        guard let url = URL(string: urlStr) else {
            await MainActor.run {
                self.finishAlbumArtLoadAttempt(urlString: urlStr, loadedImage: nil)
                withAnimation(.easeInOut(duration: 0.5)) {
                    albumArtImage = nil
                    displayedAlbumArtTrackIdentity = nil
                    albumArtDominantColor = nil
                }
            }
            SharedStorage.albumArtData = nil
            SharedStorage.cachedAlbumArtDataURL = nil
            SharedStorage.cachedDominantColorHex = nil
            return
        }

        let capturedURL = urlStr
        albumArtTask = Task {
            // Fast path: image already in memory cache.
            if let cached = self.queueArtCache.object(forKey: urlStr as NSString) {
                guard !Task.isCancelled, self.loadingAlbumArtURL == urlStr else { return }
                let color = self.dominantColorCache[urlStr] ?? cached.dominantColor()
                let bottomEdge = cached.bottomEdgeColor()
                // Keep disk entry warm so LRU eviction doesn't drop the current song's art.
                if PlaybackArtworkCachingPolicy.isQueueDiskCacheEnabled {
                    QueueArtDiskCache.shared.touch(urlStr)
                }
                await MainActor.run {
                    self.applyLoadedAlbumArt(
                        cached,
                        color: color,
                        bottomEdge: bottomEdge,
                        urlString: urlStr,
                        trackIdentity: incomingTrackIdentity,
                        preserveDisplayedArtwork: shouldPreserveDisplayedArtwork
                    )
                }
                if let data = cached.jpegData(compressionQuality: 0.9) {
                    SharedStorage.albumArtData = data
                    SharedStorage.cachedAlbumArtDataURL = urlStr
                }
                SharedStorage.cachedDominantColorHex = cached.dominantColorHex()
                return
            }

            // L2: check disk cache before hitting the network.
            if PlaybackArtworkCachingPolicy.isQueueDiskCacheEnabled,
               let cached = QueueArtDiskCache.shared.image(for: urlStr) {
                guard !Task.isCancelled, self.loadingAlbumArtURL == urlStr else { return }
                let color = self.dominantColorCache[urlStr] ?? cached.dominantColor()
                let bottomEdge = cached.bottomEdgeColor()
                self.queueArtCache.setObject(cached, forKey: urlStr as NSString,
                                             cost: Int(cached.size.width * cached.size.height * 4))
                await MainActor.run {
                    self.applyLoadedAlbumArt(
                        cached,
                        color: color,
                        bottomEdge: bottomEdge,
                        urlString: urlStr,
                        trackIdentity: incomingTrackIdentity,
                        preserveDisplayedArtwork: shouldPreserveDisplayedArtwork
                    )
                }
                if let data = cached.jpegData(compressionQuality: 0.9) {
                    SharedStorage.albumArtData = data
                    SharedStorage.cachedAlbumArtDataURL = urlStr
                }
                SharedStorage.cachedDominantColorHex = cached.dominantColorHex()
                return
            }

            // Slow path: download from network.
            do {
                let data = try await Self.fetchAlbumArtData(from: url, originalURLString: urlStr)
                guard !Task.isCancelled,
                      self.loadingAlbumArtURL == capturedURL,
                      self.trackInfo?.albumArtURL == capturedURL else { return }
                let image = UIImage(data: data)
                let dominantColor = self.dominantColorCache[urlStr] ?? image?.dominantColor()
                let bottomEdge = image?.bottomEdgeColor()
                if image != nil, PlaybackArtworkCachingPolicy.isQueueDiskCacheEnabled {
                    QueueArtDiskCache.shared.store(data, for: urlStr)
                }
                await MainActor.run {
                    self.applyLoadedAlbumArt(
                        image,
                        color: dominantColor,
                        bottomEdge: bottomEdge,
                        urlString: urlStr,
                        trackIdentity: incomingTrackIdentity,
                        preserveDisplayedArtwork: shouldPreserveDisplayedArtwork
                    )
                }
                SharedStorage.albumArtData = data
                SharedStorage.cachedAlbumArtDataURL = urlStr
                SharedStorage.cachedDominantColorHex = image?.dominantColorHex()
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.finishAlbumArtLoadAttempt(urlString: urlStr, loadedImage: nil)
                }
                guard !shouldPreserveDisplayedArtwork else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.albumArtImage = nil
                        self.displayedAlbumArtTrackIdentity = nil
                        self.albumArtDominantColor = nil
                        self.albumArtBottomEdgeColor = nil
                    }
                }
            }
        }
        await albumArtTask?.value
    }

    nonisolated static func fetchAlbumArtData(from url: URL, originalURLString: String) async throws -> Data {
        if AlbumArtDataFetchPolicy.shouldUseRelayArtworkProxy(sourceURLString: originalURLString),
           let relayURL = await MainActor.run(body: {
            RelayManager.shared.isAvailable ? RelayManager.shared.url : nil
        }) {
            do {
                return try await RelayClient.fetchArtwork(
                    baseURL: relayURL,
                    sourceURLString: originalURLString
                )
            } catch {
                SonosLog.debug(
                    .playback,
                    "relay artwork fetch failed; falling back direct url='\(originalURLString)' error=\(error)"
                )
            }
        }

        let (data, response) = try await Self.albumArtSession.data(from: url)
        try AlbumArtDataFetchPolicy.validateDirectResponse(response)
        return data
    }

    func applyLoadedAlbumArt(
        _ image: UIImage?,
        color: Color?,
        bottomEdge: Color?,
        urlString: String,
        trackIdentity: String?,
        preserveDisplayedArtwork: Bool
    ) {
        finishAlbumArtLoadAttempt(urlString: urlString, loadedImage: image)
        deferredMissingAlbumArtTrackIdentity = nil

        if preserveDisplayedArtwork {
            withAnimation(.easeInOut(duration: Self.albumArtColorTransitionDuration)) {
                albumArtDominantColor = color
                albumArtBottomEdgeColor = bottomEdge
                if let gid = selectedSpeaker?.groupId ?? selectedSpeaker?.id {
                    groupAlbumColors[gid] = color
                }
            }
            dominantColorCache[urlString] = color
            if let gid = selectedSpeaker?.groupId ?? selectedSpeaker?.id {
                if let image {
                    groupAlbumImages[gid] = image
                    groupLastArtURL[gid] = urlString
                }
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.65)) {
            albumArtImage = image
            displayedAlbumArtTrackIdentity = image == nil ? nil : trackIdentity
            albumArtDominantColor = color
            albumArtBottomEdgeColor = bottomEdge
            if let gid = selectedSpeaker?.groupId ?? selectedSpeaker?.id {
                groupAlbumColors[gid] = color
                groupAlbumImages[gid] = image
                groupLastArtURL[gid] = image == nil ? nil : urlString
            }
        }
        dominantColorCache[urlString] = color
    }

    func finishAlbumArtLoadAttempt(urlString: String, loadedImage image: UIImage?) {
        if loadingAlbumArtURL == urlString {
            loadingAlbumArtURL = nil
        }
        if image != nil {
            lastAlbumArtURL = urlString
        } else if lastAlbumArtURL == urlString {
            lastAlbumArtURL = nil
        }
    }
}
