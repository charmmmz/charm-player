import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    // MARK: - Queue

    func loadQueue() async {
        guard let ip = playbackIP else { return }
        do {
            let result = try await SonosAPI.getQueue(ip: ip)
            applyQueueResult(result)
        } catch {
            if queue.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    func queueReorderStatus(for item: QueueItem) -> QueueReorderStatus? {
        queueReorderStatusByItemID[item.id]
    }

    func applyQueueResult(_ result: QueueResult) {
        let registryResolvedItems: [QueueItem]
        if PlaybackArtworkCachingPolicy.isRegistryEnabled {
            let resolvedArtwork = PlaybackArtworkRegistry.shared.resolvedQueueItems(result.items)
            if resolvedArtwork.replacementCount > 0 {
                SonosLog.debug(
                    .nowPlaying,
                    "Queue artwork registry replaced count=\(resolvedArtwork.replacementCount) " +
                        "queue=\(result.items.count)")
            }
            registryResolvedItems = resolvedArtwork.items
        } else {
            registryResolvedItems = result.items
        }
        var cacheReplacementCount = 0
        let cacheResolvedItems: [QueueItem]
        if PlaybackArtworkCachingPolicy.isPlaybackURLCacheEnabled {
            cacheResolvedItems = registryResolvedItems.map { item -> QueueItem in
                guard Self.isAppleMusicQueueItem(item) else { return item }
                let next = PlaybackArtworkURLCache.shared.resolvedQueueItem(item, service: .appleMusic)
                if next.albumArtURL != item.albumArtURL {
                    cacheReplacementCount += 1
                }
                return next
            }
        } else {
            cacheResolvedItems = registryResolvedItems
        }
        if cacheReplacementCount > 0 {
            SonosLog.debug(
                .nowPlaying,
                "Queue artwork persistent cache replaced count=\(cacheReplacementCount) " +
                    "queue=\(result.items.count)")
        }
        queue = QueueReorderPolicy.confirmedQueue(cacheResolvedItems, preservingIDsFrom: queue)
        queueUpdateID = result.updateID
        queueLoaded = true
        pruneQueueReorderStatuses()
        schedulePrefetch()
    }

    func pruneQueueReorderStatuses() {
        guard !queueReorderStatusByItemID.isEmpty else { return }
        let visibleIDs = Set(queue.map(\.id))
        queueReorderStatusByItemID = queueReorderStatusByItemID.filter { visibleIDs.contains($0.key) }
    }

    func schedulePrefetch() {
        prefetchTask?.cancel()
        guard PlaybackArtworkCachingPolicy.isQueueDiskCacheEnabled else {
            SonosLog.debug(
                .nowPlaying,
                "Queue artwork prefetch skipped reason=cache_disabled queue=\(queue.count)")
            return
        }

        // Build fetch order: start from now-playing, go forward, then wrap to beginning.
        let nowIndex = queue.firstIndex(where: {
            $0.title == trackInfo?.title && $0.artist == trackInfo?.artist
        }) ?? 0
        let reordered = Array(queue[nowIndex...]) + Array(queue[..<nowIndex])
        let artworkURLs = reordered.compactMap { $0.albumArtURL }

        let ordered = QueueArtPrefetchPolicy.urlsToPrefetch(
            from: artworkURLs,
            cachedURLs: cachedArtURLs
        )
        let siblingURLsByURL = Self.queueArtworkSiblingURLsByURL(
            from: queue,
            cachedURLs: cachedArtURLs
        )
        let requests = ordered.map {
            QueueArtworkPrefetchRequest(
                urlString: $0,
                siblingURLStrings: siblingURLsByURL[$0] ?? []
            )
        }
        SonosLog.debug(
            .nowPlaying,
            "Queue artwork prefetch plan queue=\(queue.count) urls=\(artworkURLs.count) " +
                "scheduled=\(requests.count) cachedKnown=\(cachedArtURLs.count) " +
                "first=\(SonosLog.playbackLinkValue(ordered.first, maxLength: 240))")
        guard !requests.isEmpty else { return }

        let diskCache = QueueArtDiskCache.shared
        prefetchTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: QueueArtworkPrefetchResult?.self) { group in
                let maxConcurrent = QueueArtPrefetchPolicy.maxConcurrentFetches(for: ordered)
                var index = 0

                func addNext() {
                    guard index < requests.count else { return }
                    let request = requests[index]
                    index += 1
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await Self.loadQueueArtworkPrefetch(
                            request: request,
                            diskCache: diskCache
                        )
                    }
                }

                for _ in 0..<min(maxConcurrent, requests.count) { addNext() }
                for await result in group {
                    guard !Task.isCancelled else { continue }
                    if let result {
                        self.applyQueueArtworkPrefetchResult(result)
                    }
                    addNext()
                }
            }
        }
    }

    static func queueArtworkSiblingURLsByURL(
        from queue: [QueueItem],
        cachedURLs: Set<String>
    ) -> [String: [String]] {
        var keyByURL: [String: String] = [:]
        var urlsByKey: [String: [String]] = [:]
        var seenByKey: [String: Set<String>] = [:]

        for item in queue {
            guard let urlString = item.albumArtURL else { continue }
            let key = "\(item.album)||||\(item.artist)"
            keyByURL[urlString] = key

            var seen = seenByKey[key] ?? []
            guard seen.insert(urlString).inserted else { continue }
            seenByKey[key] = seen
            urlsByKey[key, default: []].append(urlString)
        }

        var siblingURLsByURL: [String: [String]] = [:]
        for (urlString, key) in keyByURL {
            siblingURLsByURL[urlString] = urlsByKey[key, default: []].filter {
                $0 != urlString && !cachedURLs.contains($0)
            }
        }
        return siblingURLsByURL
    }

    nonisolated static func loadQueueArtworkPrefetch(
        request: QueueArtworkPrefetchRequest,
        diskCache: QueueArtDiskCache
    ) async -> QueueArtworkPrefetchResult? {
        let urlStr = request.urlString
        guard !Task.isCancelled else { return nil }

        let imageData: Data
        let source: String
        if let d = diskCache.data(for: urlStr) {
            imageData = d
            source = "disk"
        } else {
            guard let url = URL(string: urlStr) else {
                SonosLog.debug(
                    .nowPlaying,
                    "Queue artwork prefetch invalid url=\(SonosLog.playbackLinkValue(urlStr, maxLength: 240))")
                return nil
            }
            SonosLog.debug(
                .nowPlaying,
                "Queue artwork prefetch network start url=\(SonosLog.playbackLinkValue(urlStr, maxLength: 240))")
            let downloaded: Data
            do {
                downloaded = try await Self.fetchAlbumArtData(from: url, originalURLString: urlStr)
            } catch {
                SonosLog.debug(
                    .nowPlaying,
                    "Queue artwork prefetch network failed url=\(SonosLog.playbackLinkValue(urlStr, maxLength: 240)) error=\(error)")
                return nil
            }
            imageData = downloaded
            source = "network"
            diskCache.store(imageData, for: urlStr)
        }

        guard !Task.isCancelled,
              let image = UIImage(data: imageData) else {
            return nil
        }
        let color = image.dominantColor()

        for sibling in request.siblingURLStrings {
            if !diskCache.contains(sibling) { diskCache.store(imageData, for: sibling) }
        }

        return QueueArtworkPrefetchResult(
            urlString: urlStr,
            siblingURLStrings: request.siblingURLStrings,
            image: image,
            imageCost: imageData.count,
            color: color,
            source: source
        )
    }

    func applyQueueArtworkPrefetchResult(_ result: QueueArtworkPrefetchResult) {
        queueArtCache.setObject(
            result.image,
            forKey: result.urlString as NSString,
            cost: result.imageCost
        )
        dominantColorCache[result.urlString] = result.color
        cachedArtURLs.insert(result.urlString)

        for sibling in result.siblingURLStrings {
            queueArtCache.setObject(
                result.image,
                forKey: sibling as NSString,
                cost: result.imageCost
            )
            dominantColorCache[sibling] = result.color
            cachedArtURLs.insert(sibling)
        }

        SonosLog.debug(
            .nowPlaying,
            "Queue artwork prefetch stored source=\(result.source) siblings=\(result.siblingURLStrings.count) " +
                "url=\(SonosLog.playbackLinkValue(result.urlString, maxLength: 240))")
    }

    func deleteFromQueue(item: QueueItem) async {
        guard let ip = playbackIP else { return }
        do {
            try await SonosAPI.removeTrackFromQueue(ip: ip, objectID: item.objectID, updateID: queueUpdateID)
            await loadQueue()
        } catch { errorMessage = error.localizedDescription }
    }

    func moveQueueItem(from source: IndexSet, to destination: Int) {
        guard let ip = playbackIP else { return }
        guard let fromIndex = source.first else { return }
        guard queue.indices.contains(fromIndex) else { return }
        let previousQueue = queue
        let movedItemIDs = source.sorted().compactMap { index in
            queue.indices.contains(index) ? queue[index].id : nil
        }
        let sonosFrom = fromIndex + 1
        let sonosDest = destination + 1
        let reorderedQueue = QueueReorderPolicy.reordered(queue, from: source, to: destination)
        guard reorderedQueue.map(\.id) != queue.map(\.id) else { return }
        queue = reorderedQueue
        queueReorderGeneration += 1
        let generation = queueReorderGeneration
        setQueueReorderStatus(.syncing, for: movedItemIDs)

        let capturedUpdateID = queueUpdateID
        Task {
            do {
                try await SonosAPI.reorderTracksInQueue(ip: ip, startIndex: sonosFrom,
                                                         numTracks: 1, insertBefore: sonosDest,
                                                         updateID: capturedUpdateID)
                let result = try await SonosAPI.getQueue(ip: ip)
                guard generation == queueReorderGeneration else { return }
                applyQueueResult(result)
                showQueueReorderConfirmation(for: movedItemIDs, generation: generation)
            } catch {
                guard generation == queueReorderGeneration else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    queue = previousQueue
                    setQueueReorderStatus(nil, for: movedItemIDs)
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    func setQueueReorderStatus(_ status: QueueReorderStatus?, for itemIDs: [String]) {
        guard !itemIDs.isEmpty else { return }
        for id in itemIDs {
            if let status {
                queueReorderStatusByItemID[id] = status
            } else {
                queueReorderStatusByItemID.removeValue(forKey: id)
            }
        }
    }

    func showQueueReorderConfirmation(for itemIDs: [String], generation: Int) {
        withAnimation(.easeInOut(duration: 0.16)) {
            setQueueReorderStatus(.confirmed, for: itemIDs)
        }

        Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard generation == queueReorderGeneration else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                setQueueReorderStatus(nil, for: itemIDs)
            }
        }
    }

    func playQueueItemNext(_ item: QueueItem) async {
        guard let ip = playbackIP else { return }
        guard let sourceIndex = queue.firstIndex(where: { $0.id == item.id }) else { return }
        let currentIndex = queue.firstIndex(where: {
            $0.title == trackInfo?.title && $0.artist == trackInfo?.artist
        }) ?? 0
        guard queue.indices.contains(currentIndex) else { return }

        let previousQueue = queue
        let movedItemIDs = [queue[sourceIndex].id]
        let targetPosition = currentIndex + 2 // Sonos uses 1-based, insert after current
        let sonosFrom = queue[sourceIndex].trackNumber
        let reorderedQueue = QueueReorderPolicy.playingNextQueue(
            queue,
            itemID: queue[sourceIndex].id,
            afterCurrentItemID: queue[currentIndex].id
        )
        guard reorderedQueue.map(\.id) != queue.map(\.id) else { return }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            queue = reorderedQueue
        }
        queueReorderGeneration += 1
        let generation = queueReorderGeneration
        setQueueReorderStatus(.syncing, for: movedItemIDs)
        let capturedUpdateID = queueUpdateID

        do {
            try await SonosAPI.reorderTracksInQueue(ip: ip, startIndex: sonosFrom,
                                                     numTracks: 1, insertBefore: targetPosition,
                                                     updateID: capturedUpdateID)
            let result = try await SonosAPI.getQueue(ip: ip)
            guard generation == queueReorderGeneration else { return }
            applyQueueResult(result)
            showQueueReorderConfirmation(for: movedItemIDs, generation: generation)
        } catch {
            guard generation == queueReorderGeneration else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                queue = previousQueue
                setQueueReorderStatus(nil, for: movedItemIDs)
            }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func playNext(uri: String, metadata: String) async -> Bool {
        guard let ip = playbackIP else {
            errorMessage = HandoffTransferError.noSelectedSpeaker.localizedDescription
            return false
        }
        let startedAt = Date()
        SonosLog.debug(
            .playbackLink,
            "manager.playNext start ip=\(ip) isPlayingFromQueue=\(isPlayingFromQueue) " +
                "uri=\(SonosLog.playbackLinkValue(uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(metadata))")
        do {
            // Sonos's `EnqueueAsNext=1` flag is unreliable across
            // firmwares — when an album/playlist is playing it often
            // gets interpreted as "after the current group ends",
            // landing the new track at the bottom of the queue. Compute
            // the insertion point ourselves: `currentTrack + 1` puts it
            // immediately after whatever's playing now.
            //
            // For non-queue sources (radio, TV, line-in) there's no
            // meaningful "current track number", so fall back to the
            // legacy append-at-end behavior.
            if isPlayingFromQueue,
               let current = try await SonosAPI.getCurrentTrackNumber(ip: ip) {
                SonosLog.debug(
                    .playbackLink,
                    "manager.playNext insert ip=\(ip) currentTrack=\(current) " +
                        "position=\(current + 1) asNext=true")
                try await SonosAPI.addURIToQueue(
                    ip: ip, uri: uri, metadata: metadata,
                    position: current + 1, asNext: true)
            } else {
                SonosLog.debug(
                    .playbackLink,
                    "manager.playNext insert ip=\(ip) currentTrack=nil position=0 asNext=true")
                try await SonosAPI.addURIToQueue(
                    ip: ip, uri: uri, metadata: metadata, asNext: true)
            }
            await loadQueue()
            SonosLog.debug(
                .playbackLink,
                "manager.playNext success ip=\(ip) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            return true
        } catch {
            SonosLog.error(
                .playbackLink,
                "manager.playNext failed ip=\(ip) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) " +
                    "error=\(error) uri=\(SonosLog.playbackLinkValue(uri))")
            errorMessage = error.localizedDescription
            return false
        }
    }

    func playTrackInQueue(_ item: QueueItem) async {
        guard let ip = playbackIP else { return }
        do {
            if !isPlayingFromQueue, let speaker = selectedSpeaker {
                try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: speaker.id)
            }
            try await SonosAPI.seekToTrack(ip: ip, trackNumber: item.trackNumber)
            try await SonosAPI.play(ip: ip)
            try? await Task.sleep(for: .milliseconds(300))
            await refreshState()
        } catch { errorMessage = error.localizedDescription }
    }

}
