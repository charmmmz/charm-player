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
    @State private var actionInFlight: LocalMusicDetailAction?

    @Environment(\.openURL) private var openURL

    private var displayAlbum: Album { detailedAlbum ?? album }
    private var coverURL: URL? {
        displayAlbum.artwork.flatMap {
            LocalMusicArtworkURL.url(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: displayAlbum) ?? store.catalogArtworkURL(for: album)
    }
    private var detailActions: [LocalMusicDetailAction] {
        LocalMusicDetailActions.album(hasAppleMusicURL: displayAlbum.url != nil)
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
                artworkURL: coverURL,
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
            ForEach(detailActions, id: \.self) { action in
                LocalMusicDetailActionButton(
                    action: action,
                    tint: actionTint,
                    isActive: isActionActive(action),
                    isDisabled: isActionDisabled(action)
                ) {
                    performAction(action)
                }
            }
        }
        .padding(.horizontal)
    }

    private var actionTint: Color {
        themeColor ?? manager.albumArtDominantColor ?? .white.opacity(0.15)
    }

    private func isActionActive(_ action: LocalMusicDetailAction) -> Bool {
        actionInFlight == action ||
            (store.isStartingPlayback && store.activePlaybackItemID == displayID(for: action))
    }

    private func isActionDisabled(_ action: LocalMusicDetailAction) -> Bool {
        (actionInFlight != nil && actionInFlight != action) ||
            (store.isStartingPlayback && !isActionActive(action))
    }

    private func displayID(for action: LocalMusicDetailAction) -> String {
        switch action {
        case .shuffle:
            return "\(displayAlbum.id.rawValue):shuffle"
        case .play, .playStation, .openAppleMusic:
            return displayAlbum.id.rawValue
        }
    }

    private func performAction(_ action: LocalMusicDetailAction) {
        switch action {
        case .play:
            playAlbum(shuffle: false, action: action)
        case .shuffle:
            playAlbum(shuffle: true, action: action)
        case .openAppleMusic:
            if let url = displayAlbum.url {
                openURL(url)
            }
        case .playStation:
            break
        }
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
                        numberStyle: .albumTrackNumber,
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

    private func playAlbum(shuffle: Bool, action: LocalMusicDetailAction) {
        guard actionInFlight == nil, !store.isStartingPlayback else { return }
        actionInFlight = action

        Task {
            await setSonosShuffleMode(shuffle)
            await store.playOnSonos(
                playable: LocalServiceAppleMusicPlayable.make(album: displayAlbum),
                displayID: displayID(for: action),
                fallbackKind: .album,
                fallbackTitle: displayAlbum.title,
                fallbackArtist: displayAlbum.artistName,
                fallbackAlbum: displayAlbum.title,
                manager: manager,
                searchManager: searchManager)
            withAnimation(.easeOut(duration: 0.2)) {
                actionInFlight = nil
            }
        }
    }

    private func setSonosShuffleMode(_ enabled: Bool) async {
        guard let ip = manager.selectedSpeaker?.playbackIP else { return }
        let current = try? await SonosAPI.getPlayMode(ip: ip)
        if enabled || current?.shuffle == true {
            try? await SonosAPI.setPlayMode(
                ip: ip,
                shuffle: enabled,
                repeat: current?.repeat ?? .off)
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
        } ?? store.catalogArtworkURL(for: displayPlaylist) ?? store.catalogArtworkURL(for: playlist)
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
        .task {
            logPlaylistDetailState(stage: "open", playlist: displayPlaylist)
            await loadDetails()
        }
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
                artworkURL: coverURL,
                fallbackSystemImage: "music.note.list",
                diagnosticLabel: "playlist-detail title='\(displayPlaylist.name)' id='\(displayPlaylist.id.rawValue)'"
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
                        numberStyle: .listPosition,
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
            SonosLog.debug(
                .localService,
                "Playlist detail load start \(playlistDiagnosticSummary(playlist))")
            let detailed = try await LocalMusicLibraryClient.shared.playlistDetails(for: playlist)
            detailedPlaylist = detailed
            SonosLog.debug(
                .localService,
                "Playlist detail load success tracks=\(detailed.tracks?.count ?? 0) " +
                    "\(playlistDiagnosticSummary(detailed)) coverURL=\(diagnosticURLStatus(coverURL?.absoluteString))")
        } catch {
            errorMessage = error.localizedDescription
            SonosLog.error(
                .localService,
                "Playlist detail load failed \(playlistDiagnosticSummary(playlist)) error=\(error)")
        }
    }

    private func loadCoverImage(from url: URL?) async {
        guard let url else {
            SonosLog.debug(
                .localService,
                "Playlist detail cover download skipped \(playlistDiagnosticSummary(displayPlaylist)) reason=no-cover-url")
            coverImage = nil
            themeColor = nil
            return
        }

        do {
            SonosLog.debug(
                .localService,
                "Playlist detail cover download start \(playlistDiagnosticSummary(displayPlaylist)) " +
                    "url=\(diagnosticURLStatus(url.absoluteString))")
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            let image = UIImage(data: data)
            let dominantColor = image?.dominantColor()
            coverImage = image
            themeColor = dominantColor
            SonosLog.debug(
                .localService,
                "Playlist detail cover download success \(playlistDiagnosticSummary(displayPlaylist)) " +
                    "bytes=\(data.count) image=\(image != nil) dominantColor=\(dominantColor != nil) " +
                    "url=\(diagnosticURLStatus(url.absoluteString))")
        } catch {
            guard !Task.isCancelled else { return }
            SonosLog.error(
                .localService,
                "Playlist detail cover download failed \(playlistDiagnosticSummary(displayPlaylist)) " +
                    "url=\(diagnosticURLStatus(url.absoluteString)) error=\(error)")
            coverImage = nil
            themeColor = nil
        }
    }

    private func logPlaylistDetailState(stage: String, playlist: Playlist) {
        SonosLog.debug(
            .localService,
            "Playlist detail state stage=\(stage) \(playlistDiagnosticSummary(playlist)) " +
                "coverURL=\(diagnosticURLStatus(coverURL?.absoluteString))")
    }

    private func playlistDiagnosticSummary(_ playlist: Playlist) -> String {
        let rawID = playlist.id.rawValue
        let urlString = playlist.url?.absoluteString
        let catalogID = LocalMusicCatalogIDExtractor.playlistCatalogID(
            rawID: rawID,
            urlString: urlString)
        let directArtworkURLString = playlist.artwork.flatMap {
            LocalMusicArtworkURL.url(for: $0, shortSidePixels: 600)?.absoluteString
        }
        let dimensions: String
        if let artwork = playlist.artwork {
            dimensions = "\(artwork.maximumWidth)x\(artwork.maximumHeight)"
        } else {
            dimensions = "nil"
        }

        return "title='\(playlist.name)' rawID='\(rawID)' catalogID=\(diagnosticValue(catalogID)) " +
            "curator=\(diagnosticValue(playlist.curatorName)) url=\(diagnosticValue(urlString)) " +
            "artworkDimensions=\(dimensions) directArtwork=\(diagnosticURLStatus(directArtworkURLString))"
    }

    private func diagnosticValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        return "'\(value)'"
    }

    private func diagnosticURLStatus(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        let status = LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(value) ? "loadable" : "not-loadable"
        return "\(status)('\(value)')"
    }
}

struct LocalMusicArtistDetailView: View {
    let artist: Artist
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?
    @State private var actionInFlight: LocalMusicDetailAction?

    @Environment(\.openURL) private var openURL

    private var coverURL: URL? {
        artist.artwork.flatMap {
            LocalMusicArtworkURL.url(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: artist)
    }
    private var detailActions: [LocalMusicDetailAction] {
        LocalMusicDetailActions.artist(hasAppleMusicURL: artist.url != nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                actionBar
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                songList
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSongs() }
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
            LocalMusicArtistArtwork(
                artwork: artist.artwork,
                artworkURL: store.catalogArtworkURL(for: artist)
            )

            VStack(spacing: 5) {
                Text(artist.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Text("Artist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SourceBadgeView(source: .appleMusic, tintColor: nil)
                    .padding(.top, 2)

                if !isLoading {
                    Text("\(songs.count) songs")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            ForEach(detailActions, id: \.self) { action in
                LocalMusicDetailActionButton(
                    action: action,
                    tint: actionTint,
                    isActive: isActionActive(action),
                    isDisabled: isActionDisabled(action)
                ) {
                    performAction(action)
                }
            }
        }
        .padding(.horizontal)
    }

    private var actionTint: Color {
        themeColor ?? manager.albumArtDominantColor ?? .white.opacity(0.15)
    }

    private func isActionActive(_ action: LocalMusicDetailAction) -> Bool {
        actionInFlight == action ||
            (store.isStartingPlayback && store.activePlaybackItemID == displayID(for: action))
    }

    private func isActionDisabled(_ action: LocalMusicDetailAction) -> Bool {
        (actionInFlight != nil && actionInFlight != action) ||
            (store.isStartingPlayback && !isActionActive(action))
    }

    private func displayID(for action: LocalMusicDetailAction) -> String {
        switch action {
        case .playStation:
            return "\(artist.id.rawValue):station"
        case .play, .shuffle, .openAppleMusic:
            return artist.id.rawValue
        }
    }

    private func performAction(_ action: LocalMusicDetailAction) {
        switch action {
        case .playStation:
            playArtistStation()
        case .openAppleMusic:
            if let url = artist.url {
                openURL(url)
            }
        case .play, .shuffle:
            break
        }
    }

    @ViewBuilder
    private var songList: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 36)
        } else if let errorMessage {
            LocalMusicDetailStatusBanner(message: errorMessage)
                .padding(.top, 20)
        } else if songs.isEmpty {
            ContentUnavailableView("No Songs", systemImage: "music.note.list")
                .padding(.top, 48)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    LocalMusicSongRow(
                        song: song,
                        index: index,
                        isPlaying: store.isStartingPlayback && store.activePlaybackItemID == song.id.rawValue
                    ) {
                        await store.playOnSonos(
                            playable: LocalServiceAppleMusicPlayable.make(song: song),
                            displayID: song.id.rawValue,
                            fallbackKind: .song,
                            fallbackTitle: song.title,
                            fallbackArtist: song.artistName,
                            fallbackAlbum: song.albumTitle,
                            manager: manager,
                            searchManager: searchManager)
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    private func loadSongs() async {
        guard songs.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            songs = try await store.songs(for: artist)
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
            SonosLog.error(.artistDetail, "Local Music artist image load failed: \(error)")
            coverImage = nil
            themeColor = nil
        }
    }

    private func playArtistStation() {
        guard actionInFlight == nil, !store.isStartingPlayback else { return }
        actionInFlight = .playStation

        Task {
            await store.playOnSonos(
                playable: LocalServiceAppleMusicPlayable.make(artist: artist),
                displayID: displayID(for: .playStation),
                fallbackKind: .artist,
                fallbackTitle: artist.name,
                fallbackArtist: artist.name,
                manager: manager,
                searchManager: searchManager)
            withAnimation(.easeOut(duration: 0.2)) {
                actionInFlight = nil
            }
        }
    }
}

private struct LocalMusicDetailActionButton: View {
    let action: LocalMusicDetailAction
    let tint: Color?
    let isActive: Bool
    let isDisabled: Bool
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 7) {
                if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: action.systemImage)
                        .font(.subheadline.weight(.semibold))
                }

                if !action.isCompact {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: action.isCompact ? nil : .infinity)
            .frame(width: action.isCompact ? 52 : nil, height: 44)
            .background(tint ?? .white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel(action.title)
    }
}

private struct LocalMusicDetailArtwork: View {
    let artwork: Artwork?
    let artworkURL: URL?
    let fallbackSystemImage: String
    let diagnosticLabel: String?

    init(
        artwork: Artwork?,
        artworkURL: URL?,
        fallbackSystemImage: String,
        diagnosticLabel: String? = nil
    ) {
        self.artwork = artwork
        self.artworkURL = artworkURL
        self.fallbackSystemImage = fallbackSystemImage
        self.diagnosticLabel = diagnosticLabel
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.08))

            fallbackIcon

            if let artwork {
                LocalMusicArtworkView(artwork: artwork, diagnosticLabel: diagnosticLabel)
                    .frame(width: 240, height: 240)
            }

            if let artworkURL {
                LocalMusicDetailRemoteArtworkView(url: artworkURL, diagnosticLabel: diagnosticLabel)
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

private struct LocalMusicDetailRemoteArtworkView: View {
    let url: URL
    let diagnosticLabel: String?

    @State private var didLogSuccess = false
    @State private var didLogFailure = false

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
                    .onAppear { logSuccessIfNeeded() }
            } else if case .failure(let error) = phase {
                Color.clear
                    .onAppear { logFailureIfNeeded(error) }
            } else {
                Color.clear
            }
        }
    }

    private func logSuccessIfNeeded() {
        guard !didLogSuccess,
              let diagnosticLabel else {
            return
        }
        didLogSuccess = true
        SonosLog.debug(
            .localService,
            "Detail remote artwork image loaded \(diagnosticLabel) url='\(url.absoluteString)'")
    }

    private func logFailureIfNeeded(_ error: Error) {
        guard !didLogFailure,
              let diagnosticLabel else {
            return
        }
        didLogFailure = true
        SonosLog.error(
            .localService,
            "Detail remote artwork image failed \(diagnosticLabel) url='\(url.absoluteString)' error=\(error)")
    }
}

private struct LocalMusicArtistArtwork: View {
    let artwork: Artwork?
    let artworkURL: URL?

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))

            Image(systemName: "music.mic")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            if let artwork {
                LocalMusicArtworkView(artwork: artwork)
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
            }

            if let artworkURL {
                remoteArtwork(url: artworkURL)
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
            }
        }
        .frame(width: 200, height: 200)
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }

    private func remoteArtwork(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
    }
}

private struct LocalMusicTrackRow: View {
    let track: Track
    let index: Int
    let numberStyle: LocalMusicTrackNumberStyle
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
        LocalMusicTrackNumberLabel.text(
            trackNumber: track.trackNumber,
            index: index,
            style: numberStyle)
    }
}

private struct LocalMusicSongRow: View {
    let song: Song
    let index: Int
    let isPlaying: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isPlaying {
                    ProgressView()
                        .frame(width: 36)
                } else {
                    Text(durationText(song.duration))
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
}

enum LocalMusicTrackNumberStyle {
    case albumTrackNumber
    case listPosition
}

enum LocalMusicTrackNumberLabel {
    static func text(
        trackNumber: Int?,
        index: Int,
        style: LocalMusicTrackNumberStyle
    ) -> String {
        switch style {
        case .albumTrackNumber:
            if let trackNumber {
                return "\(trackNumber)"
            }
            return "\(index + 1)"
        case .listPosition:
            return "\(index + 1)"
        }
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
