import SwiftUI

struct QueueView: View {
    @Bindable var manager: SonosManager
    /// When false the NavigationStack chrome is omitted — used for the landscape inline panel.
    var showNavigation: Bool = true

    var body: some View {
        if showNavigation {
            NavigationStack {
                queueContent
                    .navigationTitle("Queue")
                    .navigationBarTitleDisplayMode(.inline)
            }
        } else {
            queueContent
        }
    }

    // MARK: - Core content (shared between sheet and landscape inline)

    var queueContent: some View {
        Group {
            if manager.queue.isEmpty {
                ContentUnavailableView("Queue is empty",
                                       systemImage: "music.note.list",
                                       description: Text("Start playing music on your Sonos speaker."))
            } else {
                ScrollViewReader { proxy in
                    List {
                        if !manager.isPlayingFromQueue {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .font(.caption2)
                                Text("QUEUE NOT IN USE")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.5)
                                Text("— Tap a track to switch")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(manager.queue) { item in
                            let isNowPlaying = item.id == nowPlayingID

                            queueRow(item, isNowPlaying: isNowPlaying)
                                .id(item.id)
                                // Make row background transparent when embedded so the
                                // blurred album-art background shows through.
                                .listRowBackground(
                                    showNavigation ? nil : Color.clear
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: !isNowPlaying) {
                                    if !isNowPlaying {
                                        Button(role: .destructive) {
                                            Task { await manager.deleteFromQueue(item: item) }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: !isNowPlaying) {
                                    if !isNowPlaying {
                                        Button {
                                            Task { await manager.playQueueItemNext(item) }
                                        } label: {
                                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                        }
                                        .tint(.blue)
                                    }
                                }
                                .deleteDisabled(isNowPlaying)
                        }
                        .onMove { source, destination in
                            manager.moveQueueItem(from: source, to: destination)
                        }
                    }
                    .listStyle(.plain)
                    // Hide List's own background when embedded so the blurred art shows through.
                    .scrollContentBackground(showNavigation ? .automatic : .hidden)
                    .onAppear {
                        if let id = nowPlayingID {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                    .onChange(of: nowPlayingID) { _, newID in
                        if let id = newID {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var nowPlayingID: String? {
        guard manager.isPlayingFromQueue else { return nil }
        return manager.queue.first(where: {
            $0.title == manager.trackInfo?.title && $0.artist == manager.trackInfo?.artist
        })?.id
    }

    func queueRow(_ item: QueueItem, isNowPlaying: Bool) -> some View {
        let accent = manager.albumArtDominantColor ?? .accentColor
        let reorderStatus = manager.queueReorderStatus(for: item)

        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isNowPlaying ? accent : .clear)
                .frame(width: 3, height: 40)

            QueueArtView(item: item, manager: manager)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                if isNowPlaying {
                    Text("NOW PLAYING")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(accent)
                }
                Text(item.title)
                    .font(.subheadline.weight(isNowPlaying ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .background {
            if reorderStatus == .confirmed {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .padding(.horizontal, -12)
                    .padding(.vertical, -9)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(isNowPlaying ? 1.05 : 1.0, anchor: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isNowPlaying)
        .animation(.easeInOut(duration: 0.18), value: reorderStatus)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await manager.playTrackInQueue(item) }
        }
    }
}

// MARK: - Queue Art View (cache-first with shared remote loader fallback)

private struct QueueArtView: View {
    let item: QueueItem
    let manager: SonosManager
    @State private var queueCachedImage: UIImage?
    @State private var queueCachedImageURL: String?
    @State private var resolvedArtworkURLString: String?
    @State private var artworkResolutionKey: String?
    @State private var didMissPlaybackArtworkResolution = false

    var body: some View {
        let urlStr = displayArtworkURLString

        Group {
            if let urlStr,
               queueCachedImageURL == urlStr,
               let cached = queueCachedImage {
                Image(uiImage: cached)
                    .resizable().aspectRatio(contentMode: .fill)
            } else if let urlStr,
                      let cached = manager.queueMemoryImage(for: urlStr) {
                Image(uiImage: cached)
                    .resizable().aspectRatio(contentMode: .fill)
            } else if let urlStr,
                      let url = URL(string: urlStr),
                      let cached = RemoteArtworkImageLoader.shared.cachedImage(for: url) {
                Image(uiImage: cached)
                    .resizable().aspectRatio(contentMode: .fill)
            } else if let urlStr, let url = URL(string: urlStr) {
                RemoteArtworkImageView(url: url, contentMode: .fill) { _ in
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .task(id: urlStr) {
            await loadQueueCachedImage(for: urlStr)
        }
        .task(id: currentArtworkResolutionKey) {
            await resolvePlaybackArtworkIfNeeded()
        }
    }

    private var currentArtworkResolutionKey: String {
        [
            item.id,
            item.objectID,
            item.uri ?? "",
            item.albumArtURL ?? "",
            item.title,
            item.artist,
            item.album
        ].joined(separator: "|")
    }

    private var displayArtworkURLString: String? {
        if artworkResolutionKey == currentArtworkResolutionKey,
           let resolvedArtworkURLString = nonEmpty(resolvedArtworkURLString) {
            return PlaybackArtworkImageSize.queueThumbnailURLString(from: resolvedArtworkURLString)
        }

        guard let originalURLString = nonEmpty(item.albumArtURL) else { return nil }
        guard QueueArtworkLoadPolicy.shouldLoadRemoteArtwork(
            urlString: originalURLString,
            isAppleMusicQueueItem: QueueArtworkLoadPolicy.isAppleMusicQueueItem(item),
            didMissPlaybackArtworkResolution: artworkResolutionKey == currentArtworkResolutionKey
                && didMissPlaybackArtworkResolution
        ) else {
            return nil
        }
        return PlaybackArtworkImageSize.queueThumbnailURLString(from: originalURLString)
    }

    private var placeholder: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
    }

    @MainActor
    private func loadQueueCachedImage(for urlStr: String?) async {
        guard let urlStr,
              !urlStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            queueCachedImage = nil
            queueCachedImageURL = nil
            return
        }

        if let cached = manager.queueMemoryImage(for: urlStr) {
            queueCachedImage = cached
            queueCachedImageURL = urlStr
            return
        }

        guard QueueArtworkLoadPolicy.shouldLoadQueueDiskCacheAsync(
            urlString: urlStr,
            hasQueueMemoryImage: false,
            isKnownDiskCached: manager.cachedArtURLs.contains(urlStr)
        ) else {
            queueCachedImage = nil
            queueCachedImageURL = nil
            return
        }

        let image = await Task.detached(priority: .utility) {
            QueueArtDiskCache.shared.image(for: urlStr)
        }.value

        guard !Task.isCancelled, displayArtworkURLString == urlStr else { return }
        queueCachedImage = image
        queueCachedImageURL = image == nil ? nil : urlStr
    }

    @MainActor
    private func resolvePlaybackArtworkIfNeeded() async {
        let resolutionKey = currentArtworkResolutionKey
        let originalURLString = nonEmpty(item.albumArtURL)
        let isAppleMusicQueueItem = QueueArtworkLoadPolicy.isAppleMusicQueueItem(item)

        guard QueueArtworkLoadPolicy.shouldAttemptPlaybackArtworkResolution(
            urlString: originalURLString,
            isAppleMusicQueueItem: isAppleMusicQueueItem
        ) else {
            artworkResolutionKey = resolutionKey
            resolvedArtworkURLString = nil
            didMissPlaybackArtworkResolution = false
            return
        }

        artworkResolutionKey = resolutionKey
        resolvedArtworkURLString = nil
        didMissPlaybackArtworkResolution = false

        let catalogID = SonosAppleMusicTrackResolver.storeID(fromTrackURI: item.uri)
            ?? SonosAppleMusicTrackResolver.storeID(fromObjectID: item.objectID)
        let request = PlaybackArtworkRequest(
            service: .appleMusic,
            kind: .song,
            catalogID: catalogID,
            title: item.title,
            artist: item.artist,
            album: item.album,
            currentArtworkURLString: item.albumArtURL,
            identity: .queueItem(item),
            countryCode: Locale.current.region?.identifier ?? "US"
        )

        SonosLog.debug(
            .nowPlaying,
            "Queue artwork fallback start title='\(SonosLog.playbackLinkValue(item.title, maxLength: 120))' " +
                "artist='\(SonosLog.playbackLinkValue(item.artist, maxLength: 120))' " +
                "catalogID=\(SonosLog.playbackLinkValue(catalogID, maxLength: 120)) " +
                "current=\(SonosLog.playbackLinkValue(item.albumArtURL, maxLength: 240))")

        guard let resolution = await AppleMusicPlaybackArtworkResolver.shared.resolve(request: request) else {
            guard !Task.isCancelled, artworkResolutionKey == resolutionKey else { return }
            didMissPlaybackArtworkResolution = true
            SonosLog.debug(.nowPlaying, "Queue artwork fallback miss title='\(SonosLog.playbackLinkValue(item.title, maxLength: 120))'")
            return
        }

        guard !Task.isCancelled, artworkResolutionKey == resolutionKey else {
            SonosLog.debug(.nowPlaying, "Queue artwork fallback stale result source=\(resolution.source.rawValue)")
            return
        }

        let resolvedURLString = resolution.sizedURLString(
            shortSidePixels: PlaybackArtworkImageSize.queueThumbnailShortSidePixels
        )
        resolvedArtworkURLString = resolvedURLString
        didMissPlaybackArtworkResolution = false
        SonosLog.debug(
            .nowPlaying,
            "Queue artwork fallback hit source=\(resolution.source.rawValue) " +
                "url=\(SonosLog.playbackLinkValue(resolvedURLString, maxLength: 240))")
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
