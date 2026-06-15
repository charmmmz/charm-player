import Foundation
import MusicKit
import SwiftUI
import UIKit

@MainActor
private func openLocalMusicAppleMusicURL(_ url: URL, context: String) {
    AppleMusicExternalLinkOpener.open(url, context: context)
}

struct LocalMusicAlbumDetailView: View {
    let album: Album
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var detailedAlbum: Album?
    @State private var completeCatalogAlbum: Album?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?
    @State private var actionInFlight: LocalMusicDetailAction?
    @State private var catalogAppleMusicURL: URL?
    @State private var isAppleMusicFavorited = false
    @State private var isAppleMusicFavoriteBusy = false
    @State private var appleMusicFavoritedTrackIDs: Set<String> = []

    private var displayAlbum: Album { detailedAlbum ?? album }
    private var coverURL: URL? {
        displayAlbum.artwork.flatMap {
            LocalMusicArtworkURL.imageDownloadURL(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: displayAlbum) ?? store.catalogArtworkURL(for: album)
    }
    private var albumPlayable: LocalServiceAppleMusicPlayable? {
        LocalServiceAppleMusicPlayable.make(album: displayAlbum)
    }
    private var playbackAlbumID: String {
        LocalMusicAlbumDetailPresentation.playbackAlbumID(
            currentAlbumID: displayAlbum.id.rawValue,
            completeAlbumID: completeCatalogAlbum?.id.rawValue)
    }
    private var currentTrackCount: Int {
        tracks.isEmpty ? displayAlbum.trackCount : tracks.count
    }
    private var completeAlbumTrackCount: Int? {
        completeCatalogAlbum.flatMap { album in
            album.tracks.map { Array($0).count }
        } ?? completeCatalogAlbum?.trackCount
    }
    private var shouldShowCompleteAlbumButton: Bool {
        LocalMusicAlbumDetailPresentation.shouldShowCompleteAlbumButton(
            currentAlbumID: displayAlbum.id.rawValue,
            currentTrackCount: currentTrackCount,
            completeAlbumID: completeCatalogAlbum?.id.rawValue,
            completeTrackCount: completeAlbumTrackCount)
    }
    private var appleMusicURL: URL? {
        LocalMusicAppleMusicURL.externalURL(
            existingURL: displayAlbum.url,
            catalogURL: catalogAppleMusicURL,
            kind: .album,
            requiresCatalogURL: true)
    }
    private var appleMusicURLLookupID: String {
        "\(displayAlbum.id.rawValue)|\(displayAlbum.title)|\(displayAlbum.artistName)"
    }
    private var tracks: [Track] {
        guard let tracks = detailedAlbum?.tracks else { return [] }
        return Array(tracks)
    }

    init(
        album: Album,
        store: LocalLibraryStore,
        manager: SonosManager,
        searchManager: SearchManager,
        initialDetailedAlbum: Album? = nil
    ) {
        self.album = album
        self.store = store
        self.manager = manager
        self.searchManager = searchManager
        _detailedAlbum = State(initialValue: initialDetailedAlbum)
        _isLoading = State(initialValue: initialDetailedAlbum == nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                actionBar
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                trackList
                completeAlbumFooter
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                albumMenu
            }
        }
        .task {
            await loadDetails()
            await loadCompleteCatalogAlbumIfNeeded()
        }
        .task(id: coverURL) { await loadCoverImage(from: coverURL) }
        .task(id: appleMusicURLLookupID) {
            catalogAppleMusicURL = nil
            await resolveAppleMusicURLIfNeeded()
        }
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
            Button {
                openAppleMusicFromArtwork()
            } label: {
                LocalMusicDetailArtwork(
                    artwork: displayAlbum.artwork,
                    artworkURL: coverURL,
                    fallbackSystemImage: "square.stack",
                    size: 280
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(displayAlbum.title) in Apple Music")

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
        AlbumPrimaryActionBar(
            favoriteKind: .appleMusic,
            tint: actionTint,
            isPlayActive: isActionActive(.play),
            isShuffleActive: isActionActive(.shuffle),
            isFavoriteActive: isAppleMusicFavorited,
            isFavoriteBusy: isAppleMusicFavoriteBusy,
            isFavoriteDisabled: false,
            isPlaybackDisabled: actionInFlight != nil || store.isStartingPlayback,
            play: { performAction(.play) },
            shuffle: { performAction(.shuffle) },
            toggleFavorite: toggleAppleMusicFavorite
        )
    }

    private var actionTint: Color {
        themeColor ?? manager.albumArtDominantColor ?? .white.opacity(0.15)
    }

    private func isActionActive(_ action: LocalMusicDetailAction) -> Bool {
        actionInFlight == action ||
            (store.isStartingPlayback && store.activePlaybackItemID == displayID(for: action))
    }

    private func displayID(for action: LocalMusicDetailAction) -> String {
        switch action {
        case .shuffle:
            return "\(playbackAlbumID):shuffle"
        case .play, .favorite, .playStation, .openAppleMusic:
            return playbackAlbumID
        }
    }

    private func performAction(_ action: LocalMusicDetailAction) {
        switch action {
        case .play:
            playAlbum(shuffle: false, action: action)
        case .shuffle:
            playAlbum(shuffle: true, action: action)
        case .openAppleMusic:
            if let url = appleMusicURL {
                openLocalMusicAppleMusicURL(url, context: "album-action title='\(displayAlbum.title)'")
            }
        case .favorite:
            toggleAppleMusicFavorite()
        case .playStation:
            break
        }
    }

    private var albumMenu: some View {
        Menu {
            if appleMusicURL != nil {
                Button {
                    performAction(.openAppleMusic)
                } label: {
                    Label("Open in Apple Music", systemImage: "music.note")
                }

                Divider()
            }

            Button {
                queueAlbum(.playNext)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                queueAlbum(.addToQueue)
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private func queueAlbum(_ action: MusicResourceMenuAction) {
        Task {
            await store.performSonosQueueAction(
                action,
                playable: albumPlayable,
                displayID: "\(playbackAlbumID):\(action.id)",
                fallbackKind: .album,
                fallbackTitle: displayAlbum.title,
                fallbackArtist: displayAlbum.artistName,
                fallbackAlbum: displayAlbum.title,
                manager: manager,
                searchManager: searchManager)
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
                    let isPlaying = store.isStartingPlayback && store.activePlaybackItemID == track.id.rawValue
                    AlbumTrackRow(
                        number: LocalMusicTrackNumberLabel.text(
                            trackNumber: track.trackNumber,
                            index: index,
                            style: .albumTrackNumber
                        ),
                        title: track.title,
                        subtitle: AlbumTrackSubtitlePolicy.subtitle(
                            trackArtist: track.artistName,
                            albumArtist: displayAlbum.artistName
                        ),
                        duration: durationText(track.duration),
                        isExplicit: false,
                        isPlaying: isPlaying,
                        isDisabled: store.isStartingPlayback && !isPlaying,
                        isLast: index == tracks.count - 1,
                        action: {
                            Task {
                                await playTrack(track)
                            }
                        }
                    ) {
                        localAlbumTrackContextMenu(track)
                    }
                }
            }
            .padding(.top, 10)
            .padding(.horizontal)
        }
    }

    private func localAlbumTrackContextMenu(_ track: Track) -> some View {
        let isFavoriteActive = appleMusicFavoritedTrackIDs.contains(track.id.rawValue)

        return MusicResourceContextMenu(
            actions: AlbumTrackMenuActionPolicy.actions(
                favoriteKind: .appleMusic,
                isFavoriteActive: isFavoriteActive,
                isQueueable: true
            )
        ) { action in
            performLocalAlbumTrackMenuAction(action, track: track)
        }
    }

    private func performLocalAlbumTrackMenuAction(
        _ action: MusicResourceMenuAction,
        track: Track
    ) {
        switch action {
        case .playNow:
            Task { await playTrack(track) }
        case .playNext, .addToQueue:
            Task {
                await store.performSonosQueueAction(
                    action,
                    playable: LocalServiceAppleMusicPlayable.make(track: track),
                    displayID: track.id.rawValue,
                    fallbackKind: .song,
                    fallbackTitle: track.title,
                    fallbackArtist: track.artistName,
                    fallbackAlbum: track.albumTitle,
                    manager: manager,
                    searchManager: searchManager)
            }
        case .favorite(.appleMusic, _):
            toggleAppleMusicTrackFavorite(track)
        case .favorite(.sonos, _), .startStation:
            break
        }
    }

    private func playTrack(_ track: Track) async {
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

    @ViewBuilder
    private var completeAlbumFooter: some View {
        if shouldShowCompleteAlbumButton,
           let completeCatalogAlbum {
            NavigationLink {
                LocalMusicAlbumDetailView(
                    album: completeCatalogAlbum,
                    store: store,
                    manager: manager,
                    searchManager: searchManager,
                    initialDetailedAlbum: completeCatalogAlbum)
            } label: {
                HStack(spacing: 8) {
                    Text("Show Complete Album")
                        .font(.body)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
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

    private func loadCompleteCatalogAlbumIfNeeded() async {
        guard completeCatalogAlbum == nil else { return }

        do {
            let catalogAlbum = try await LocalMusicLibraryClient.shared.completeCatalogAlbumDetails(for: displayAlbum)
            guard !Task.isCancelled else { return }
            completeCatalogAlbum = catalogAlbum
            SonosLog.debug(
                .albumDetail,
                "Local Music complete album resolved current='\(displayAlbum.title)' " +
                    "currentID='\(displayAlbum.id.rawValue)' currentTracks=\(currentTrackCount) " +
                    "catalogID='\(catalogAlbum.id.rawValue)' catalogTracks=\(catalogAlbum.tracks?.count ?? catalogAlbum.trackCount)")
        } catch {
            guard !Task.isCancelled else { return }
            SonosLog.debug(
                .albumDetail,
                "Local Music complete album lookup skipped current='\(displayAlbum.title)' " +
                    "currentID='\(displayAlbum.id.rawValue)' error=\(error)")
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
            if let uiColor = image?.dominantUIColor() {
                themeColor = AlbumThemeColorPolicy.mutedColor(from: uiColor)
            } else {
                themeColor = image?.dominantColor()?.opacity(0.55)
            }
        } catch {
            guard !Task.isCancelled else { return }
            SonosLog.error(.albumDetail, "Local Music cover image load failed: \(error)")
            coverImage = nil
            themeColor = nil
        }
    }

    private func openAppleMusicFromArtwork() {
        Task {
            guard let url = await resolveAppleMusicURLIfNeeded() else {
                SonosLog.debug(
                    .localService,
                    "Album Apple Music artwork tap has no resolved URL title='\(displayAlbum.title)' " +
                        "rawURL='\(displayAlbum.url?.absoluteString ?? "nil")' " +
                        "playableID='\(albumPlayable?.catalogID ?? "nil")'")
                return
            }
            openLocalMusicAppleMusicURL(url, context: "album-artwork title='\(displayAlbum.title)'")
        }
    }

    private func toggleAppleMusicFavorite() {
        guard !isAppleMusicFavoriteBusy else { return }
        isAppleMusicFavoriteBusy = true

        Task { @MainActor in
            defer { isAppleMusicFavoriteBusy = false }
            SonosLog.debug(
                .localService,
                "Apple Music album favorite tapped title='\(displayAlbum.title)' id='\(displayAlbum.id.rawValue)'")
            isAppleMusicFavorited.toggle()
        }
    }

    private func toggleAppleMusicTrackFavorite(_ track: Track) {
        if appleMusicFavoritedTrackIDs.contains(track.id.rawValue) {
            appleMusicFavoritedTrackIDs.remove(track.id.rawValue)
        } else {
            appleMusicFavoritedTrackIDs.insert(track.id.rawValue)
        }

        SonosLog.debug(
            .localService,
            "Apple Music track favorite tapped title='\(track.title)' id='\(track.id.rawValue)' " +
            "isFavorited=\(appleMusicFavoritedTrackIDs.contains(track.id.rawValue))")
    }

    @discardableResult
    private func resolveAppleMusicURLIfNeeded() async -> URL? {
        if let appleMusicURL { return appleMusicURL }

        if let playable = albumPlayable,
           let catalogID = LocalMusicAppleMusicURL.publicCatalogID(from: playable.catalogID, kind: .album) {
            do {
                let urlString = try await AppleMusicCatalogSearchClient.shared.appleMusicURLString(
                    kind: LocalMusicAppleMusicURL.Kind.album,
                    catalogID: catalogID)
                if let urlString,
                   let url = URL(string: urlString),
                   let resolved = LocalMusicAppleMusicURL.externalURL(
                    existingURL: nil,
                    catalogURL: url,
                    kind: .album
                   ) {
                    guard !Task.isCancelled else { return nil }
                    SonosLog.debug(
                        .localService,
                        "Album Apple Music link resolved by catalog id title='\(displayAlbum.title)' " +
                            "catalogID='\(catalogID)' url='\(urlString)'")
                    catalogAppleMusicURL = resolved
                    return resolved
                }
            } catch {
                guard !Task.isCancelled else { return nil }
                SonosLog.debug(
                    .localService,
                    "Album Apple Music catalog id lookup failed title='\(displayAlbum.title)' " +
                        "catalogID='\(catalogID)' error=\(error)")
            }
        }

        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: .album,
            title: displayAlbum.title,
            artist: displayAlbum.artistName,
            album: displayAlbum.title)
        guard !term.isEmpty else { return nil }

        do {
            let items = try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: 8)
            let urlString = LocalMusicCatalogWebURLFallback.urlString(
                in: items,
                kind: .album,
                title: displayAlbum.title,
                artist: displayAlbum.artistName,
                album: displayAlbum.title,
                allowGeneratedFallback: false)
            guard !Task.isCancelled,
                  let urlString,
                  let url = URL(string: urlString),
                  let resolved = LocalMusicAppleMusicURL.externalURL(
                    existingURL: nil,
                    catalogURL: url,
                    kind: .album
                  ) else {
                SonosLog.debug(
                    .localService,
                    "Album Apple Music link search produced no usable URL title='\(displayAlbum.title)' term='\(term)'")
                return nil
            }

            SonosLog.debug(.localService, "Album Apple Music link resolved title='\(displayAlbum.title)' url='\(urlString)'")
            catalogAppleMusicURL = resolved
            return resolved
        } catch {
            guard !Task.isCancelled else { return nil }
            SonosLog.debug(.localService, "Album Apple Music link lookup failed title='\(displayAlbum.title)' error=\(error)")
            return nil
        }
    }

    private func playAlbum(shuffle: Bool, action: LocalMusicDetailAction) {
        guard actionInFlight == nil, !store.isStartingPlayback else { return }
        actionInFlight = action
        let displayedTracks = tracks

        Task {
            await setSonosShuffleMode(shuffle)
            if LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(trackCount: displayedTracks.count) {
                await store.playDisplayedTracksOnSonos(
                    tracks: displayedTracks,
                    displayID: displayID(for: action),
                    albumTitle: displayAlbum.title,
                    manager: manager,
                    searchManager: searchManager)
            } else {
                await store.playOnSonos(
                    playable: albumPlayable,
                    displayID: displayID(for: action),
                    fallbackKind: .album,
                    fallbackTitle: displayAlbum.title,
                    fallbackArtist: displayAlbum.artistName,
                    fallbackAlbum: displayAlbum.title,
                    manager: manager,
                    searchManager: searchManager)
            }
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
    @State private var actionInFlight: LocalMusicDetailAction?

    private var displayPlaylist: Playlist { detailedPlaylist ?? playlist }
    private var coverURL: URL? {
        displayPlaylist.artwork.flatMap {
            LocalMusicArtworkURL.imageDownloadURL(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: displayPlaylist) ?? store.catalogArtworkURL(for: playlist)
    }
    private var playlistPlayable: LocalServiceAppleMusicPlayable? {
        LocalServiceAppleMusicPlayable.make(playlist: displayPlaylist)
    }
    private var appleMusicURL: URL? {
        LocalMusicAppleMusicURL.externalURL(
            existingURL: displayPlaylist.url,
            catalogURL: nil,
            kind: .playlist)
    }
    private var detailActions: [LocalMusicDetailAction] {
        LocalMusicDetailActions.playlist(hasAppleMusicURL: appleMusicURL != nil)
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
            Button {
                openAppleMusicFromArtwork()
            } label: {
                LocalMusicDetailArtwork(
                    artwork: displayPlaylist.artwork,
                    artworkURL: coverURL,
                    fallbackSystemImage: "music.note.list",
                    diagnosticLabel: "playlist-detail title='\(displayPlaylist.name)' id='\(displayPlaylist.id.rawValue)'"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(displayPlaylist.name) in Apple Music")

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
            return "\(displayPlaylist.id.rawValue):shuffle"
        case .play, .favorite, .playStation, .openAppleMusic:
            return displayPlaylist.id.rawValue
        }
    }

    private func performAction(_ action: LocalMusicDetailAction) {
        switch action {
        case .play:
            playPlaylist(shuffle: false, action: action)
        case .shuffle:
            playPlaylist(shuffle: true, action: action)
        case .openAppleMusic:
            if let url = appleMusicURL {
                openLocalMusicAppleMusicURL(url, context: "playlist-action title='\(displayPlaylist.name)'")
            }
        case .favorite, .playStation:
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
                    let trackArtworkURL = playlistTrackDirectArtworkURL(for: track)
                    let catalogArtworkURL = store.catalogArtworkURL(forPlaylistTrack: track)
                    let selectedArtworkURL = playlistTrackArtworkURL(
                        trackArtworkURL: trackArtworkURL,
                        catalogArtworkURL: catalogArtworkURL)
                    LocalMusicTrackRow(
                        track: track,
                        index: index,
                        leadingPolicy: .playlistTrack,
                        artworkURL: selectedArtworkURL,
                        fallbackArtworkURL: nil,
                        numberStyle: .listPosition,
                        isPlaying: store.isStartingPlayback && store.activePlaybackItemID == track.id.rawValue,
                        contextMenuActions: MusicResourceActionPolicy.actions(kind: .song, isQueueable: true),
                        menuAction: { action in
                            Task {
                                await store.performSonosQueueAction(
                                    action,
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
                    .onAppear {
                        logPlaylistTrackRowDecision(
                            stage: "row-appear",
                            index: index,
                            track: track,
                            trackArtworkURL: trackArtworkURL,
                            catalogArtworkURL: catalogArtworkURL,
                            selectedArtworkURL: selectedArtworkURL)
                    }
                    .onChange(of: catalogArtworkURL) { _, newCatalogArtworkURL in
                        let refreshedTrackArtworkURL = playlistTrackDirectArtworkURL(for: track)
                        let refreshedSelectedArtworkURL = playlistTrackArtworkURL(
                            trackArtworkURL: refreshedTrackArtworkURL,
                            catalogArtworkURL: newCatalogArtworkURL)
                        logPlaylistTrackRowDecision(
                            stage: "catalog-change",
                            index: index,
                            track: track,
                            trackArtworkURL: refreshedTrackArtworkURL,
                            catalogArtworkURL: newCatalogArtworkURL,
                            selectedArtworkURL: refreshedSelectedArtworkURL)
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
            if let tracks = detailed.tracks {
                let trackArray = Array(tracks)
                logPlaylistTrackData(stage: "detail-loaded", playlist: detailed, tracks: trackArray)
                store.ensureCatalogArtwork(forPlaylistTracks: trackArray)
            }
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

    private func playlistTrackDirectArtworkURL(for track: Track) -> URL? {
        track.artwork.flatMap {
            LocalMusicArtworkURL.url(for: $0, shortSidePixels: 120)
        }
    }

    private func playlistTrackArtworkURL(
        trackArtworkURL: URL?,
        catalogArtworkURL: URL?
    ) -> URL? {
        LocalMusicPlaylistTrackArtworkLookup.selectedArtworkURL(
            trackArtworkURL: trackArtworkURL,
            catalogArtworkURL: catalogArtworkURL,
            playlistArtworkURL: coverURL)
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

    private func openAppleMusicFromArtwork() {
        guard let url = appleMusicURL else {
            SonosLog.debug(
                .localService,
                "Playlist Apple Music artwork tap has no resolved URL title='\(displayPlaylist.name)' " +
                    "rawURL='\(displayPlaylist.url?.absoluteString ?? "nil")' " +
                    "playableID='\(playlistPlayable?.catalogID ?? "nil")'")
            return
        }
        openLocalMusicAppleMusicURL(url, context: "playlist-artwork title='\(displayPlaylist.name)'")
    }

    private func playPlaylist(shuffle: Bool, action: LocalMusicDetailAction) {
        guard actionInFlight == nil, !store.isStartingPlayback else { return }
        actionInFlight = action

        Task {
            await setSonosShuffleMode(shuffle)
            await store.playOnSonos(
                playable: playlistPlayable,
                displayID: displayID(for: action),
                fallbackKind: .playlist,
                fallbackTitle: displayPlaylist.name,
                fallbackArtist: displayPlaylist.curatorName,
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
            LocalMusicArtworkURL.imageDownloadURL(for: $0, shortSidePixels: 600)?.absoluteString
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

    private func logPlaylistTrackData(stage: String, playlist: Playlist, tracks: [Track]) {
        SonosLog.debug(
            .localService,
            "LSPlaylistTrackArtwork detail stage=\(stage) playlist='\(playlist.name)' " +
                "playlistID='\(playlist.id.rawValue)' trackCount=\(tracks.count)")

        for (index, track) in tracks.prefix(40).enumerated() {
            let directArtworkURL = playlistTrackDirectArtworkURL(for: track)
            SonosLog.debug(
                .localService,
                "LSPlaylistTrackArtwork detail-item index=\(index) " +
                    "\(playlistTrackDiagnosticSummary(track)) " +
                    "directArtwork=\(diagnosticURLStatus(directArtworkURL?.absoluteString))")
        }

        if tracks.count > 40 {
            SonosLog.debug(
                .localService,
                "LSPlaylistTrackArtwork detail omitted=\(tracks.count - 40) playlist='\(playlist.name)'")
        }
    }

    private func logPlaylistTrackRowDecision(
        stage: String,
        index: Int,
        track: Track,
        trackArtworkURL: URL?,
        catalogArtworkURL: URL?,
        selectedArtworkURL: URL?
    ) {
        SonosLog.debug(
            .localService,
            "LSPlaylistTrackArtwork row stage=\(stage) index=\(index) " +
                "\(playlistTrackDiagnosticSummary(track)) " +
                "trackArtwork=\(diagnosticURLStatus(trackArtworkURL?.absoluteString)) " +
                "catalogArtwork=\(diagnosticURLStatus(catalogArtworkURL?.absoluteString)) " +
                "selectedArtwork=\(diagnosticURLStatus(selectedArtworkURL?.absoluteString))")
    }

    private func playlistTrackDiagnosticSummary(_ track: Track) -> String {
        let dimensions: String
        if let artwork = track.artwork {
            dimensions = "\(artwork.maximumWidth)x\(artwork.maximumHeight)"
        } else {
            dimensions = "nil"
        }
        return "trackID='\(track.id.rawValue)' title='\(track.title)' artist='\(track.artistName)' " +
            "album=\(diagnosticValue(track.albumTitle)) artworkDimensions=\(dimensions)"
    }

    private func diagnosticValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        return "'\(value)'"
    }

    private func diagnosticURLStatus(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        let status: String
        if LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(value) {
            status = "loadable"
        } else if URL(string: value)?.scheme?.lowercased() == "musickit" {
            status = "musicKit"
        } else {
            status = "not-loadable"
        }
        return "\(status)('\(value)')"
    }
}

struct LocalMusicArtistDetailView: View {
    let artist: Artist
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?
    @State private var actionInFlight: LocalMusicDetailAction?
    @State private var catalogAppleMusicURL: URL?

    private var coverURL: URL? {
        artist.artwork.flatMap {
            LocalMusicArtworkURL.imageDownloadURL(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: artist)
    }
    private var artistPlayable: LocalServiceAppleMusicPlayable? {
        LocalServiceAppleMusicPlayable.make(artist: artist)
    }
    private var appleMusicURL: URL? {
        LocalMusicAppleMusicURL.externalURL(
            existingURL: artist.url,
            catalogURL: catalogAppleMusicURL,
            kind: .artist,
            requiresCatalogURL: true)
    }
    private var appleMusicURLLookupID: String {
        "\(artist.id.rawValue)|\(artist.name)"
    }
    private var detailActions: [LocalMusicDetailAction] {
        LocalMusicDetailActions.artist(hasAppleMusicURL: appleMusicURL != nil)
    }
    private var visibleActionBarActions: [LocalMusicDetailAction] {
        detailActions.filter { $0 == .openAppleMusic }
    }
    private var albumSummaries: [LocalMusicArtistAlbumSummary] {
        LocalMusicArtistAlbumSummaryBuilder.summaries(
            from: songs.map(albumSummaryInput))
    }
    private var albumSections: [LocalMusicArtistAlbumSection] {
        LocalMusicArtistAlbumSection.sections(from: songs)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                actionBar
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                albumOverview
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadArtistContent() }
        .task(id: coverURL) { await loadCoverImage(from: coverURL) }
        .task(id: appleMusicURLLookupID) {
            catalogAppleMusicURL = nil
            await resolveAppleMusicURLIfNeeded()
        }
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
            ZStack(alignment: .topTrailing) {
                Button {
                    openAppleMusicFromArtwork()
                } label: {
                    LocalMusicArtistArtwork(
                        artwork: artist.artwork,
                        artworkURL: store.catalogArtworkURL(for: artist)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(artist.name) in Apple Music")

                stationBadge
                    .offset(x: 6, y: 6)
            }

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

                Text(isLoading ? "0 songs" : "\(songs.count) songs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(isLoading ? 0 : 1)
                    .accessibilityHidden(isLoading)
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private var actionBar: some View {
        Group {
            if !visibleActionBarActions.isEmpty {
                HStack(spacing: 12) {
                    ForEach(visibleActionBarActions, id: \.self) { action in
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
        }
    }

    private var stationBadge: some View {
        Button {
            playArtistStation()
        } label: {
            ZStack {
                Circle()
                    .fill(actionTint)
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

                if isActionActive(.playStation) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: LocalMusicDetailAction.playStation.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isActionDisabled(.playStation))
        .opacity(isActionDisabled(.playStation) ? 0.45 : 1)
        .accessibilityLabel(LocalMusicDetailAction.playStation.title)
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
        case .play, .shuffle, .favorite, .openAppleMusic:
            return artist.id.rawValue
        }
    }

    private func performAction(_ action: LocalMusicDetailAction) {
        switch action {
        case .playStation:
            playArtistStation()
        case .openAppleMusic:
            if let url = appleMusicURL {
                openLocalMusicAppleMusicURL(url, context: "artist-action title='\(artist.name)'")
            }
        case .play, .shuffle, .favorite:
            break
        }
    }

    @ViewBuilder
    private var albumOverview: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 36)
        } else if let errorMessage {
            LocalMusicDetailStatusBanner(message: errorMessage)
                .padding(.top, 20)
        } else if albums.isEmpty && albumSummaries.isEmpty {
            ContentUnavailableView("No Albums", systemImage: "square.stack")
                .padding(.top, 48)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Albums")
                    .font(.headline)
                    .padding(.horizontal)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 16
                ) {
                    if !albums.isEmpty {
                        ForEach(albums) { album in
                            NavigationLink {
                                LocalMusicAlbumDetailView(
                                    album: album,
                                    store: store,
                                    manager: manager,
                                    searchManager: searchManager)
                            } label: {
                                LocalMusicArtistLibraryAlbumCard(
                                    album: album,
                                    artworkURL: albumArtworkURL(for: album))
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        ForEach(albumSummaries) { summary in
                            NavigationLink {
                                LocalMusicArtistAlbumSongsView(
                                    summary: summary,
                                    songs: songs(for: summary),
                                    store: store,
                                    manager: manager,
                                    searchManager: searchManager)
                            } label: {
                                LocalMusicArtistAlbumCard(
                                    summary: summary,
                                    artworkURL: albumArtworkURL(for: summary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
    }

    private func loadArtistContent() async {
        guard albums.isEmpty && songs.isEmpty else {
            ensureArtistAlbumArtwork()
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var firstError: Error?

        do {
            albums = try await store.albums(for: artist)
            store.ensureCatalogArtwork(forArtistAlbums: albums)
        } catch {
            firstError = error
            SonosLog.debug(
                .localService,
                "Local Music artist albums load failed title='\(artist.name)' error=\(error)")
        }

        do {
            songs = try await store.songs(for: artist)
        } catch {
            if firstError == nil {
                firstError = error
            }
            SonosLog.debug(
                .localService,
                "Local Music artist songs load failed title='\(artist.name)' error=\(error)")
        }

        ensureArtistAlbumArtwork()

        if albums.isEmpty, songs.isEmpty, let firstError {
            errorMessage = firstError.localizedDescription
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

    private func albumSummaryInput(for song: Song) -> LocalMusicArtistAlbumSummaryInput {
        LocalMusicArtistAlbumSummaryInput(
            id: song.id.rawValue,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            artworkURL: song.artwork.flatMap {
                LocalMusicArtworkURL.url(for: $0, shortSidePixels: 420)
            }
                ?? store.catalogArtworkURL(for: song))
    }

    private func albumArtworkURL(for summary: LocalMusicArtistAlbumSummary) -> URL? {
        summary.artworkURL ?? store.catalogArtworkURL(forArtistAlbum: summary)
    }

    private func albumArtworkURL(for album: Album) -> URL? {
        album.artwork.flatMap {
            LocalMusicArtworkURL.url(for: $0, shortSidePixels: 420)
        } ?? store.catalogArtworkURL(for: album)
    }

    private func ensureArtistAlbumArtwork() {
        if albums.isEmpty {
            store.ensureCatalogArtwork(forArtistAlbumSummaries: albumSummaries)
        } else {
            store.ensureCatalogArtwork(forArtistAlbums: albums)
        }
    }

    private func songs(for summary: LocalMusicArtistAlbumSummary) -> [Song] {
        albumSections.first { $0.title == summary.title }?.songs ?? []
    }

    private func openAppleMusicFromArtwork() {
        Task {
            guard let url = await resolveAppleMusicURLIfNeeded() else {
                SonosLog.debug(
                    .localService,
                    "Artist Apple Music artwork tap has no resolved URL title='\(artist.name)' " +
                        "rawURL='\(artist.url?.absoluteString ?? "nil")' " +
                        "playableID='\(artistPlayable?.catalogID ?? "nil")'")
                return
            }
            openLocalMusicAppleMusicURL(url, context: "artist-artwork title='\(artist.name)'")
        }
    }

    @discardableResult
    private func resolveAppleMusicURLIfNeeded() async -> URL? {
        if let appleMusicURL { return appleMusicURL }

        if let playable = artistPlayable,
           let catalogID = LocalMusicAppleMusicURL.publicCatalogID(from: playable.catalogID, kind: .artist) {
            do {
                let urlString = try await AppleMusicCatalogSearchClient.shared.appleMusicURLString(
                    kind: LocalMusicAppleMusicURL.Kind.artist,
                    catalogID: catalogID)
                if let urlString,
                   let url = URL(string: urlString),
                   let resolved = LocalMusicAppleMusicURL.externalURL(
                    existingURL: nil,
                    catalogURL: url,
                    kind: .artist
                   ) {
                    guard !Task.isCancelled else { return nil }
                    SonosLog.debug(
                        .localService,
                        "Artist Apple Music link resolved by catalog id title='\(artist.name)' " +
                            "catalogID='\(catalogID)' url='\(urlString)'")
                    catalogAppleMusicURL = resolved
                    return resolved
                }
            } catch {
                guard !Task.isCancelled else { return nil }
                SonosLog.debug(
                    .localService,
                    "Artist Apple Music catalog id lookup failed title='\(artist.name)' " +
                        "catalogID='\(catalogID)' error=\(error)")
            }
        }

        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: .artist,
            title: artist.name,
            artist: artist.name,
            album: nil)
        guard !term.isEmpty else { return nil }

        do {
            let items = try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: 8)
            let urlString = LocalMusicCatalogWebURLFallback.urlString(
                in: items,
                kind: .artist,
                title: artist.name,
                artist: artist.name,
                album: nil,
                allowGeneratedFallback: false)
            guard !Task.isCancelled,
                  let urlString,
                  let url = URL(string: urlString),
                  let resolved = LocalMusicAppleMusicURL.externalURL(
                    existingURL: nil,
                    catalogURL: url,
                    kind: .artist
                  ) else {
                SonosLog.debug(
                    .localService,
                    "Artist Apple Music link search produced no usable URL title='\(artist.name)' term='\(term)'")
                return nil
            }

            SonosLog.debug(.localService, "Artist Apple Music link resolved title='\(artist.name)' url='\(urlString)'")
            catalogAppleMusicURL = resolved
            return resolved
        } catch {
            guard !Task.isCancelled else { return nil }
            SonosLog.debug(.localService, "Artist Apple Music link lookup failed title='\(artist.name)' error=\(error)")
            return nil
        }
    }

    private func playArtistStation() {
        guard actionInFlight == nil, !store.isStartingPlayback else { return }
        actionInFlight = .playStation

        Task {
            await store.playOnSonos(
                playable: artistPlayable,
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

struct LocalMusicCatalogSearchDetailView: View {
    let item: AppleMusicCatalogSearchItem
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var resource: LocalMusicCatalogSearchDetailResource?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let resource {
                switch resource {
                case .album(let album):
                    LocalMusicAlbumDetailView(
                        album: album,
                        store: store,
                        manager: manager,
                        searchManager: searchManager,
                        initialDetailedAlbum: album)
                case .artist(let artist):
                    LocalMusicCatalogArtistDetailView(
                        artist: artist,
                        store: store,
                        manager: manager,
                        searchManager: searchManager)
                case .playlist(let playlist):
                    LocalMusicPlaylistDetailView(
                        playlist: playlist,
                        store: store,
                        manager: manager,
                        searchManager: searchManager)
                }
            } else if isLoading {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Loading \(item.title)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    SonosArtworkBackground(
                        image: manager.albumArtImage,
                        fallbackColor: manager.albumArtDominantColor
                    )
                    .ignoresSafeArea()
                )
            } else {
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: catalogFallbackSystemImage,
                    description: Text(errorMessage ?? "Try again later.")
                )
                .background(
                    SonosArtworkBackground(
                        image: manager.albumArtImage,
                        fallbackColor: manager.albumArtDominantColor
                    )
                    .ignoresSafeArea()
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.id) { await loadResource() }
    }

    private var catalogFallbackSystemImage: String {
        switch item.type {
        case .song:
            return "music.note"
        case .album:
            return "square.stack"
        case .artist:
            return "music.mic"
        case .playlist:
            return "music.note.list"
        }
    }

    private func loadResource() async {
        guard resource == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = AppleMusicCatalogSearchClient()
        do {
            switch item.type {
            case .album:
                resource = .album(try await client.album(catalogID: item.id))
            case .artist:
                resource = .artist(try await client.artist(catalogID: item.id))
            case .playlist:
                resource = .playlist(try await client.playlist(catalogID: item.id))
            case .song:
                errorMessage = "Songs play directly from search results."
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            SonosLog.error(
                .localService,
                "Catalog search detail load failed type=\(item.type) id='\(item.id)' title='\(item.title)' error=\(error)")
        }
    }
}

private enum LocalMusicCatalogSearchDetailResource {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

private struct LocalMusicCatalogArtistDetailView: View {
    let artist: Artist
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var coverImage: UIImage?
    @State private var themeColor: Color?
    @State private var actionInFlight: LocalMusicDetailAction?

    private var coverURL: URL? {
        artist.artwork.flatMap {
            LocalMusicArtworkURL.imageDownloadURL(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: artist)
    }
    private var artistPlayable: LocalServiceAppleMusicPlayable? {
        LocalServiceAppleMusicPlayable.make(artist: artist)
    }
    private var albums: [Album] {
        LocalMusicCatalogArtistContent.albums(for: artist)
    }
    private var topSongs: [Song] {
        Array(artist.topSongs ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                albumOverview
                topSongsSection
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
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
            ZStack(alignment: .topTrailing) {
                Button {
                    openAppleMusicFromArtwork()
                } label: {
                    LocalMusicArtistArtwork(
                        artwork: artist.artwork,
                        artworkURL: store.catalogArtworkURL(for: artist)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(artist.name) in Apple Music")

                stationBadge
                    .offset(x: 6, y: 6)
            }

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

                Text("\(albums.count) albums · \(topSongs.count) songs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private var stationBadge: some View {
        Button {
            playArtistStation()
        } label: {
            ZStack {
                Circle()
                    .fill(actionTint)
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

                if isActionActive(.playStation) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: LocalMusicDetailAction.playStation.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isActionDisabled(.playStation))
        .opacity(isActionDisabled(.playStation) ? 0.45 : 1)
        .accessibilityLabel(LocalMusicDetailAction.playStation.title)
    }

    private var albumOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Albums")
                .font(.headline)
                .padding(.horizontal)

            if albums.isEmpty {
                ContentUnavailableView("No Albums", systemImage: "square.stack")
                    .padding(.top, 24)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 16
                ) {
                    ForEach(albums) { album in
                        NavigationLink {
                            LocalMusicAlbumDetailView(
                                album: album,
                                store: store,
                                manager: manager,
                                searchManager: searchManager)
                        } label: {
                            LocalMusicArtistLibraryAlbumCard(
                                album: album,
                                artworkURL: albumArtworkURL(for: album))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.top, 22)
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private var topSongsSection: some View {
        if !topSongs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Top Songs")
                    .font(.headline)
                    .padding(.horizontal)

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                        LocalMusicSongRow(
                            song: song,
                            index: index,
                            isPlaying: store.isStartingPlayback && store.activePlaybackItemID == song.id.rawValue,
                            contextMenuActions: MusicResourceActionPolicy.actions(kind: .song, isQueueable: true),
                            menuAction: { action in
                                Task {
                                    await store.performSonosQueueAction(
                                        action,
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
            }
        }
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
        case .play, .shuffle, .favorite, .openAppleMusic:
            return artist.id.rawValue
        }
    }

    private func albumArtworkURL(for album: Album) -> URL? {
        album.artwork.flatMap {
            LocalMusicArtworkURL.url(for: $0, shortSidePixels: 420)
        } ?? store.catalogArtworkURL(for: album)
    }

    private func openAppleMusicFromArtwork() {
        guard let url = LocalMusicAppleMusicURL.externalURL(
            existingURL: artist.url,
            catalogURL: nil,
            kind: .artist,
            requiresCatalogURL: true
        ) else { return }
        openLocalMusicAppleMusicURL(url, context: "catalog-artist-artwork title='\(artist.name)'")
    }

    private func playArtistStation() {
        guard actionInFlight == nil, !store.isStartingPlayback else { return }
        actionInFlight = .playStation

        Task {
            await store.playOnSonos(
                playable: artistPlayable,
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
            SonosLog.error(.artistDetail, "Catalog artist image load failed: \(error)")
            coverImage = nil
            themeColor = nil
        }
    }
}

enum LocalMusicCatalogArtistContent {
    static func albums(for artist: Artist) -> [Album] {
        var seen = Set<String>()
        var result: [Album] = []

        func append(_ album: Album?) {
            guard let album else { return }
            let id = album.id.rawValue
            guard !seen.contains(id) else { return }
            seen.insert(id)
            result.append(album)
        }

        func append(_ albums: MusicItemCollection<Album>?) {
            guard let albums else { return }
            for album in albums {
                append(album)
            }
        }

        append(artist.latestRelease)
        append(artist.fullAlbums)
        append(artist.singles)
        append(artist.albums)

        return result
    }
}

private struct LocalMusicArtistAlbumSongsView: View {
    let summary: LocalMusicArtistAlbumSummary
    let songs: [Song]
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var coverImage: UIImage?
    @State private var themeColor: Color?

    private var coverURL: URL? {
        summary.artworkURL ?? store.catalogArtworkURL(forArtistAlbum: summary)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                songList
                    .padding(.top, 18)
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
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
                artwork: nil,
                artworkURL: coverURL,
                fallbackSystemImage: "square.stack"
            )

            VStack(spacing: 5) {
                Text(summary.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Text(summary.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text("\(songs.count) songs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private var songList: some View {
        if songs.isEmpty {
            ContentUnavailableView("No Songs", systemImage: "music.note.list")
                .padding(.top, 48)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    LocalMusicSongRow(
                        song: song,
                        index: index,
                        isPlaying: store.isStartingPlayback && store.activePlaybackItemID == song.id.rawValue,
                        contextMenuActions: MusicResourceActionPolicy.actions(kind: .song, isQueueable: true),
                        menuAction: { action in
                            Task {
                                await store.performSonosQueueAction(
                                    action,
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
            SonosLog.error(.albumDetail, "Local Music artist album image load failed: \(error)")
            coverImage = nil
            themeColor = nil
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
            .frame(width: action.isCompact ? 48 : nil)
            .padding(.vertical, 10)
            .background(tint ?? .white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel(action.title)
    }
}

private struct LocalMusicArtistAlbumSection: Identifiable {
    let title: String
    let songs: [Song]

    var id: String { title }

    nonisolated static func sections(from songs: [Song]) -> [LocalMusicArtistAlbumSection] {
        let grouped = Dictionary(grouping: songs) { song in
            let title = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "Unknown Album" : title
        }

        return grouped
            .map { title, songs in
                LocalMusicArtistAlbumSection(
                    title: title,
                    songs: songs.sorted(by: songSort))
            }
            .sorted { lhs, rhs in
                if lhs.title == "Unknown Album" { return false }
                if rhs.title == "Unknown Album" { return true }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    nonisolated private static func songSort(_ lhs: Song, _ rhs: Song) -> Bool {
        switch (lhs.trackNumber, rhs.trackNumber) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

private struct LocalMusicArtistAlbumHeader: View {
    let section: LocalMusicArtistAlbumSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(section.songs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}

private struct LocalMusicArtistLibraryAlbumCard: View {
    let album: Album
    let artworkURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            squareArtwork

            Text(album.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 4) {
                if !album.artistName.isEmpty {
                    Text(album.artistName)
                    Text("·")
                }
                Text("\(album.trackCount) songs")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var squareArtwork: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork = album.artwork {
                    LocalMusicArtworkView(artwork: artwork, contentMode: .fill)
                } else if let artworkURL {
                    AsyncImage(url: artworkURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            fallbackArtwork
                        }
                    }
                } else {
                    fallbackArtwork
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var fallbackArtwork: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .overlay {
                Image(systemName: "opticaldisc")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
    }
}

private struct LocalMusicArtistAlbumCard: View {
    let summary: LocalMusicArtistAlbumSummary
    let artworkURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            squareArtwork

            Text(summary.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 4) {
                if !summary.artistName.isEmpty {
                    Text(summary.artistName)
                }
                if !summary.artistName.isEmpty {
                    Text("·")
                }
                Text("\(summary.songCount) songs")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var squareArtwork: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(.white.opacity(0.08))
                            .overlay {
                                Image(systemName: "opticaldisc")
                                    .font(.title)
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct LocalMusicDetailArtwork: View {
    let artwork: Artwork?
    let artworkURL: URL?
    let fallbackSystemImage: String
    let diagnosticLabel: String?
    let size: CGFloat

    init(
        artwork: Artwork?,
        artworkURL: URL?,
        fallbackSystemImage: String,
        diagnosticLabel: String? = nil,
        size: CGFloat = 240
    ) {
        self.artwork = artwork
        self.artworkURL = artworkURL
        self.fallbackSystemImage = fallbackSystemImage
        self.diagnosticLabel = diagnosticLabel
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.08))

            fallbackIcon

            if let artwork {
                LocalMusicArtworkView(artwork: artwork, diagnosticLabel: diagnosticLabel)
                    .frame(width: size, height: size)
            }

            if let artworkURL {
                LocalMusicDetailRemoteArtworkView(url: artworkURL, diagnosticLabel: diagnosticLabel)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
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

struct LocalMusicArtistArtwork: View {
    let artwork: Artwork?
    let artworkURL: URL?
    let size: CGFloat
    let shadow: Bool

    init(
        artwork: Artwork?,
        artworkURL: URL?,
        size: CGFloat = 200,
        shadow: Bool = true
    ) {
        self.artwork = artwork
        self.artworkURL = artworkURL
        self.size = size
        self.shadow = shadow
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))

            Image(systemName: "music.mic")
                .font(.system(size: max(18, size * 0.26)))
                .foregroundStyle(.secondary)

            if let artwork {
                LocalMusicArtworkView(artwork: artwork)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }

            if let artworkURL {
                remoteArtwork(url: artworkURL)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(shadow ? 0.3 : 0), radius: shadow ? 16 : 0, y: shadow ? 8 : 0)
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
    let leadingPolicy: MusicResourceTrackLeadingPolicy
    let artworkURL: URL?
    let fallbackArtworkURL: URL?
    let numberStyle: LocalMusicTrackNumberStyle
    let isPlaying: Bool
    let contextMenuActions: [MusicResourceMenuAction]
    let menuAction: (MusicResourceMenuAction) -> Void
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                leadingArtworkOrNumber

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
        .contextMenu {
            MusicResourceContextMenu(actions: contextMenuActions, perform: menuAction)
        }
    }

    @ViewBuilder
    private var leadingArtworkOrNumber: some View {
        if let selectedArtworkURL {
            LocalMusicDetailRemoteArtworkView(url: selectedArtworkURL, diagnosticLabel: nil)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text(trackNumber)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var selectedArtworkURL: URL? {
        leadingPolicy.selectedArtworkURL(
            primaryArtworkURL: artworkURL,
            fallbackArtworkURL: fallbackArtworkURL)
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
    let contextMenuActions: [MusicResourceMenuAction]
    let menuAction: (MusicResourceMenuAction) -> Void
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
        .contextMenu {
            MusicResourceContextMenu(actions: contextMenuActions, perform: menuAction)
        }
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
