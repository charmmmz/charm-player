import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit
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
    @State private var isAppleMusicFavorited = false
    @State private var isAppleMusicFavoriteBusy = false
    @State private var appleMusicFavoritedTrackIDs: Set<String> = []

    private var displayPlaylist: Playlist { detailedPlaylist ?? playlist }
    private var coverURL: URL? {
        displayPlaylist.artwork.flatMap {
            LocalMusicArtworkURL.imageDownloadURL(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: displayPlaylist) ?? store.catalogArtworkURL(for: playlist)
    }
    private var playlistPlayable: LocalServiceAppleMusicPlayable? {
        LocalServiceAppleMusicPlayable.make(playlist: displayPlaylist)?
            .withPreferredArtworkURLString(coverURL?.absoluteString)
    }
    private var playlistSonosActionContext: LocalMusicContainerSonosActionContext {
        LocalMusicContainerSonosActionContext.playlist(
            containerID: displayPlaylist.id.rawValue,
            title: displayPlaylist.name,
            curator: displayPlaylist.curatorName
        )
    }
    private var playlistFavoriteResource: AppleMusicFavoriteResource? {
        AppleMusicFavoriteResource.fromLocalServicePlayable(playlistPlayable)
    }
    private var appleMusicURL: URL? {
        LocalMusicAppleMusicURL.externalURL(
            existingURL: displayPlaylist.url,
            catalogURL: nil,
            kind: .playlist)
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
                editorialDescriptionSection(
                    text: playlistDescription,
                    title: displayPlaylist.name
                )
                trackList
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                playlistMenu
            }
        }
        .task {
            logPlaylistDetailState(stage: "open", playlist: displayPlaylist)
            await loadDetails()
        }
        .task(id: coverURL) { await loadCoverImage(from: coverURL) }
        .task(id: playlistFavoriteResource?.id ?? "") {
            await loadAppleMusicFavoriteState()
        }
        .task(id: tracks.map(\.id.rawValue).joined(separator: "|")) {
            await loadAppleMusicTrackFavoriteStates()
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

            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private var playlistDescription: String? {
        EditorialDescriptionPolicy.text(
            standard: displayPlaylist.standardDescription,
            short: displayPlaylist.shortDescription,
            tagline: nil)
    }

    private var actionBar: some View {
        AlbumPrimaryActionBar(
            favoriteKind: .appleMusic,
            tint: actionTint,
            isPlayActive: isActionActive(.play),
            isShuffleActive: isActionActive(.shuffle),
            isFavoriteActive: isAppleMusicFavorited,
            isFavoriteBusy: isAppleMusicFavoriteBusy,
            isFavoriteDisabled: playlistFavoriteResource == nil,
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
        case .favorite:
            toggleAppleMusicFavorite()
        case .playStation:
            break
        }
    }

    private var playlistMenu: some View {
        Menu {
            LocalMusicContainerDetailMenuContent(
                actions: LocalMusicContainerDetailMenuPolicy.actions(
                    hasAppleMusicURL: appleMusicURL != nil
                ),
                perform: performPlaylistMenuAction
            )
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private func performPlaylistMenuAction(_ action: LocalMusicContainerDetailMenuAction) {
        performLocalMusicContainerMenuAction(
            action,
            playable: playlistPlayable,
            context: playlistSonosActionContext,
            store: store,
            manager: manager,
            searchManager: searchManager,
            openAppleMusic: { performAction(.openAppleMusic) }
        )
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
                        artwork: track.artwork,
                        artworkURL: selectedArtworkURL,
                        fallbackArtworkURL: nil,
                        numberStyle: .listPosition,
                        isPlaying: store.isStartingPlayback && store.activePlaybackItemID == track.id.rawValue,
                        contextMenuActions: AlbumTrackMenuActionPolicy.songActions(
                            isSonosFavoriteActive: false,
                            isAppleMusicFavoriteActive: appleMusicFavoritedTrackIDs.contains(track.id.rawValue),
                            isQueueable: true,
                            isAppleMusicFavoriteAvailable: favoriteResource(for: track) != nil
                        ),
                        menuAction: { action in
                            performPlaylistTrackMenuAction(action, track: track)
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
            .padding(.top, LocalMusicDetailSpacing.trackListTopPadding)
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

    private func toggleAppleMusicFavorite() {
        guard !isAppleMusicFavoriteBusy else { return }
        guard let resource = playlistFavoriteResource else {
            SonosLog.debug(
                .localService,
                "Apple Music playlist favorite unavailable title='\(displayPlaylist.name)' id='\(displayPlaylist.id.rawValue)'")
            return
        }
        isAppleMusicFavoriteBusy = true
        let targetState = !isAppleMusicFavorited
        isAppleMusicFavorited = targetState

        Task { @MainActor in
            defer { isAppleMusicFavoriteBusy = false }
            do {
                if targetState {
                    try await searchManager.addToAppleMusicFavorites(resource: resource)
                } else {
                    try await searchManager.removeFromAppleMusicFavorites(resource: resource)
                }
                SonosLog.debug(
                    .localService,
                    "Apple Music playlist favorite updated title='\(displayPlaylist.name)' " +
                        "resource='\(resource.id)' isFavorited=\(targetState)")
            } catch {
                isAppleMusicFavorited.toggle()
                SonosLog.error(
                    .localService,
                    "Apple Music playlist favorite failed title='\(displayPlaylist.name)' " +
                        "resource='\(resource.id)' target=\(targetState) error=\(error)")
            }
        }
    }

    private func performPlaylistTrackMenuAction(
        _ action: MusicResourceMenuAction,
        track: Track
    ) {
        switch action {
        case .playNow:
            Task {
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
        case .favorite(.sonos, _, _):
            Task {
                await store.toggleSonosFavorite(
                    playable: LocalServiceAppleMusicPlayable.make(track: track),
                    displayID: track.id.rawValue,
                    fallbackKind: .song,
                    fallbackTitle: track.title,
                    fallbackArtist: track.artistName,
                    fallbackAlbum: track.albumTitle,
                    manager: manager,
                    searchManager: searchManager)
            }
        case .favorite(.appleMusic, _, _):
            toggleAppleMusicTrackFavorite(track)
        case .startStation:
            break
        }
    }

    private func toggleAppleMusicTrackFavorite(_ track: Track) {
        guard let resource = favoriteResource(for: track) else {
            SonosLog.debug(
                .localService,
                "Apple Music playlist track favorite unavailable title='\(track.title)' id='\(track.id.rawValue)'")
            return
        }

        let trackID = track.id.rawValue
        let targetState = !appleMusicFavoritedTrackIDs.contains(trackID)
        if targetState {
            appleMusicFavoritedTrackIDs.insert(trackID)
        } else {
            appleMusicFavoritedTrackIDs.remove(trackID)
        }

        Task { @MainActor in
            do {
                if targetState {
                    try await searchManager.addToAppleMusicFavorites(resource: resource)
                } else {
                    try await searchManager.removeFromAppleMusicFavorites(resource: resource)
                }
                SonosLog.debug(
                    .localService,
                    "Apple Music playlist track favorite updated title='\(track.title)' " +
                        "resource='\(resource.id)' isFavorited=\(targetState)")
            } catch {
                if targetState {
                    appleMusicFavoritedTrackIDs.remove(trackID)
                } else {
                    appleMusicFavoritedTrackIDs.insert(trackID)
                }
                SonosLog.error(
                    .localService,
                    "Apple Music playlist track favorite failed title='\(track.title)' " +
                        "resource='\(resource.id)' target=\(targetState) error=\(error)")
            }
        }
    }

    private func loadAppleMusicFavoriteState() async {
        guard let resource = playlistFavoriteResource else {
            isAppleMusicFavorited = false
            return
        }

        do {
            isAppleMusicFavorited = try await searchManager.appleMusicFavoriteStatus(for: resource)
        } catch {
            SonosLog.debug(
                .localService,
                "Apple Music playlist favorite status skipped title='\(displayPlaylist.name)' " +
                    "resource='\(resource.id)' error=\(error)")
        }
    }

    private func loadAppleMusicTrackFavoriteStates() async {
        var favorited: Set<String> = []
        for track in tracks {
            guard !Task.isCancelled else { return }
            guard let resource = favoriteResource(for: track) else { continue }
            do {
                if try await searchManager.appleMusicFavoriteStatus(for: resource) {
                    favorited.insert(track.id.rawValue)
                }
            } catch {
                SonosLog.debug(
                    .localService,
                    "Apple Music playlist track favorite status skipped title='\(track.title)' " +
                        "resource='\(resource.id)' error=\(error)")
            }
        }

        guard !Task.isCancelled else { return }
        appleMusicFavoritedTrackIDs = favorited
    }

    private func favoriteResource(for track: Track) -> AppleMusicFavoriteResource? {
        AppleMusicFavoriteResource.fromLocalServicePlayable(
            LocalServiceAppleMusicPlayable.make(track: track)
        )
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
