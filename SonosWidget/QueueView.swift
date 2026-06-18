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

            QueueArtView(urlStr: item.albumArtURL, manager: manager)
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

            queueSyncIndicator(status: reorderStatus, accent: accent)
        }
        .background {
            if reorderStatus != nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(reorderStatus == .syncing ? 0.10 : 0.16))
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

    @ViewBuilder
    private func queueSyncIndicator(status: SonosManager.QueueReorderStatus?, accent: Color) -> some View {
        ZStack {
            switch status {
            case .syncing:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .tint(accent)
                    .accessibilityLabel("Updating queue order")
            case .confirmed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .accessibilityLabel("Queue order updated")
            case nil:
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Queue Art View (cache-first with shared remote loader fallback)

private struct QueueArtView: View {
    let urlStr: String?
    let manager: SonosManager

    var body: some View {
        if let urlStr,
           manager.cachedArtURLs.contains(urlStr),
           let cached = manager.queueImage(for: urlStr) {
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

    private var placeholder: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
    }
}
