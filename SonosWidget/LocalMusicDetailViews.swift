import Foundation
import MusicKit
import SwiftUI
import UIKit

struct LocalMusicAlbumDetailView: View {
    let album: Album
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var detailedAlbum: Album?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?

    private var displayAlbum: Album { detailedAlbum ?? album }
    private var coverURL: URL? {
        displayAlbum.artwork.flatMap {
            LocalMusicArtworkURL.url(for: $0, shortSidePixels: 600)
        }
    }
    private var tracks: [Track] {
        guard let tracks = detailedAlbum?.tracks else { return [] }
        return Array(tracks)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                actionBar
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                trackList
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetails() }
        .task(id: coverURL) { await loadCoverImage(from: coverURL) }
    }

    private var detailBackground: some View {
        SonosArtworkBackground(
            image: coverImage ?? manager.albumArtImage,
            fallbackColor: themeColor ?? manager.albumArtDominantColor
        )
        .animation(.easeInOut(duration: 0.8), value: coverURL)
        .animation(.easeInOut(duration: 0.8), value: themeColor)
    }

    private var header: some View {
        VStack(spacing: 12) {
            LocalMusicDetailArtwork(
                artwork: displayAlbum.artwork,
                fallbackSystemImage: "square.stack"
            )

            VStack(spacing: 5) {
                Text(displayAlbum.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Text(displayAlbum.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(albumMetadata)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private var albumMetadata: String {
        var parts: [String] = []
        if let releaseDate = displayAlbum.releaseDate {
            parts.append(releaseDate.formatted(.dateTime.year()))
        }
        if !displayAlbum.genreNames.isEmpty {
            parts.append(displayAlbum.genreNames.prefix(2).joined(separator: ", "))
        }
        parts.append("\(displayAlbum.trackCount) tracks")
        return parts.joined(separator: " · ")
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await store.playOnSonos(
                        playable: LocalServiceAppleMusicPlayable.make(album: displayAlbum),
                        displayID: displayAlbum.id.rawValue,
                        fallbackKind: .album,
                        fallbackTitle: displayAlbum.title,
                        fallbackArtist: displayAlbum.artistName,
                        fallbackAlbum: displayAlbum.title,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isStartingPlayback)

            if let url = displayAlbum.url {
                Link(destination: url) {
                    Image(systemName: "music.note")
                        .frame(width: 44, height: 34)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 36)
        } else if let errorMessage {
            LocalMusicDetailStatusBanner(message: errorMessage)
                .padding(.top, 20)
        } else if tracks.isEmpty {
            ContentUnavailableView("No Tracks", systemImage: "music.note.list")
                .padding(.top, 48)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    LocalMusicTrackRow(
                        track: track,
                        index: index,
                        isPlaying: store.isStartingPlayback && store.activePlaybackItemID == track.id.rawValue
                    ) {
                        await store.playOnSonos(
                            playable: LocalServiceAppleMusicPlayable.make(track: track),
                            displayID: track.id.rawValue,
                            fallbackKind: .song,
                            fallbackTitle: track.title,
                            fallbackArtist: track.artistName,
                            fallbackAlbum: track.albumTitle,
                            manager: manager,
                            searchManager: searchManager)
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    private func loadDetails() async {
        guard detailedAlbum == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            detailedAlbum = try await LocalMusicLibraryClient.shared.albumDetails(for: album)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCoverImage(from url: URL?) async {
        guard let url else {
            coverImage = nil
            themeColor = nil
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            let image = UIImage(data: data)
            coverImage = image
            themeColor = image?.dominantColor()
        } catch {
            guard !Task.isCancelled else { return }
            SonosLog.error(.albumDetail, "Local Music cover image load failed: \(error)")
            coverImage = nil
            themeColor = nil
        }
    }
}

struct LocalMusicPlaylistDetailView: View {
    let playlist: Playlist
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var detailedPlaylist: Playlist?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?

    private var displayPlaylist: Playlist { detailedPlaylist ?? playlist }
    private var coverURL: URL? {
        displayPlaylist.artwork.flatMap {
            LocalMusicArtworkURL.url(for: $0, shortSidePixels: 600)
        }
    }
    private var tracks: [Track] {
        guard let tracks = detailedPlaylist?.tracks else { return [] }
        return Array(tracks)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                actionBar
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                trackList
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetails() }
        .task(id: coverURL) { await loadCoverImage(from: coverURL) }
    }

    private var detailBackground: some View {
        SonosArtworkBackground(
            image: coverImage ?? manager.albumArtImage,
            fallbackColor: themeColor ?? manager.albumArtDominantColor
        )
        .animation(.easeInOut(duration: 0.8), value: coverURL)
        .animation(.easeInOut(duration: 0.8), value: themeColor)
    }

    private var header: some View {
        VStack(spacing: 12) {
            LocalMusicDetailArtwork(
                artwork: displayPlaylist.artwork,
                fallbackSystemImage: "music.note.list"
            )

            VStack(spacing: 5) {
                Text(displayPlaylist.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Text(displayPlaylist.curatorName ?? "Playlist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let description = playlistDescription {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private var playlistDescription: String? {
        displayPlaylist.shortDescription ?? displayPlaylist.standardDescription
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await store.playOnSonos(
                        playable: LocalServiceAppleMusicPlayable.make(playlist: displayPlaylist),
                        displayID: displayPlaylist.id.rawValue,
                        fallbackKind: .playlist,
                        fallbackTitle: displayPlaylist.name,
                        fallbackArtist: displayPlaylist.curatorName,
                        manager: manager,
                        searchManager: searchManager)
                }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isStartingPlayback)

            if let url = displayPlaylist.url {
                Link(destination: url) {
                    Image(systemName: "music.note")
                        .frame(width: 44, height: 34)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 36)
        } else if let errorMessage {
            LocalMusicDetailStatusBanner(message: errorMessage)
                .padding(.top, 20)
        } else if tracks.isEmpty {
            ContentUnavailableView("No Tracks", systemImage: "music.note.list")
                .padding(.top, 48)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    LocalMusicTrackRow(
                        track: track,
                        index: index,
                        isPlaying: store.isStartingPlayback && store.activePlaybackItemID == track.id.rawValue
                    ) {
                        await store.playOnSonos(
                            playable: LocalServiceAppleMusicPlayable.make(track: track),
                            displayID: track.id.rawValue,
                            fallbackKind: .song,
                            fallbackTitle: track.title,
                            fallbackArtist: track.artistName,
                            fallbackAlbum: track.albumTitle,
                            manager: manager,
                            searchManager: searchManager)
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    private func loadDetails() async {
        guard detailedPlaylist == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            detailedPlaylist = try await LocalMusicLibraryClient.shared.playlistDetails(for: playlist)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCoverImage(from url: URL?) async {
        guard let url else {
            coverImage = nil
            themeColor = nil
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            let image = UIImage(data: data)
            coverImage = image
            themeColor = image?.dominantColor()
        } catch {
            guard !Task.isCancelled else { return }
            SonosLog.error(.playlistDetail, "Local Music cover image load failed: \(error)")
            coverImage = nil
            themeColor = nil
        }
    }
}

private struct LocalMusicDetailArtwork: View {
    let artwork: Artwork?
    let fallbackSystemImage: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.08))

            fallbackIcon

            if let artwork {
                LocalMusicArtworkView(artwork: artwork)
                    .frame(width: 240, height: 240)
            }
        }
        .frame(width: 240, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSystemImage)
            .font(.system(size: 56))
            .foregroundStyle(.secondary)
    }
}

private struct LocalMusicTrackRow: View {
    let track: Track
    let index: Int
    let isPlaying: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                Text(trackNumber)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isPlaying {
                    ProgressView()
                        .frame(width: 36)
                } else {
                    Text(durationText(track.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    private var trackNumber: String {
        if let trackNumber = track.trackNumber {
            return "\(trackNumber)"
        }
        return "\(index + 1)"
    }
}

private struct LocalMusicDetailStatusBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }
}

private func durationText(_ duration: TimeInterval?) -> String {
    guard let duration else { return "--:--" }
    let seconds = max(0, Int(duration.rounded()))
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}
