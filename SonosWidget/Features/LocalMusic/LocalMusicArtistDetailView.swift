import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit
struct LocalMusicArtistDetailView: View {
    let artist: Artist
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var detailedArtist: Artist?
    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?
    @State private var actionInFlight: LocalMusicDetailAction?
    @State private var catalogAppleMusicURL: URL?

    private var displayArtist: Artist { detailedArtist ?? artist }
    private var coverURL: URL? {
        displayArtist.artwork.flatMap {
            LocalMusicArtworkURL.imageDownloadURL(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: displayArtist) ?? store.catalogArtworkURL(for: artist)
    }
    private var artistPlayable: LocalServiceAppleMusicPlayable? {
        LocalServiceAppleMusicPlayable.make(artist: displayArtist)?
            .withPreferredArtworkURLString(coverURL?.absoluteString)
    }
    private var appleMusicURL: URL? {
        LocalMusicAppleMusicURL.externalURL(
            existingURL: displayArtist.url,
            catalogURL: catalogAppleMusicURL,
            kind: .artist,
            requiresCatalogURL: true)
    }
    private var appleMusicURLLookupID: String {
        "\(displayArtist.id.rawValue)|\(displayArtist.name)"
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
    private var artistTopSongs: [Song] {
        let catalogTopSongs = Array(displayArtist.topSongs ?? [])
        return catalogTopSongs.isEmpty ? songs : catalogTopSongs
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                actionBar
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                topSongsSection
                albumOverview
            }
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadArtistContent() }
        .task(id: "\(artist.id.rawValue)|\(artist.name)") { await loadArtistDetails() }
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
                        artwork: displayArtist.artwork,
                        artworkURL: store.catalogArtworkURL(for: displayArtist) ?? store.catalogArtworkURL(for: artist)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(displayArtist.name) in Apple Music")

                stationBadge
                    .offset(x: 6, y: 6)
            }

            VStack(spacing: 5) {
                Text(displayArtist.name)
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

                if let description = artistDescription {
                    ExpandableText(
                        text: description,
                        title: displayArtist.name,
                        collapsedLineLimit: 3,
                        font: .caption,
                        uiTextStyle: .caption1,
                        textColor: Color.secondary.opacity(0.72),
                        toggleColor: .white.opacity(0.92),
                        multilineTextAlignment: .center
                    )
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private var artistDescription: String? {
        EditorialDescriptionPolicy.text(
            standard: displayArtist.editorialNotes?.standard,
            short: displayArtist.editorialNotes?.short,
            tagline: displayArtist.editorialNotes?.tagline)
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
            return "\(displayArtist.id.rawValue):station"
        case .play, .shuffle, .favorite, .openAppleMusic:
            return displayArtist.id.rawValue
        }
    }

    private func performAction(_ action: LocalMusicDetailAction) {
        switch action {
        case .playStation:
            playArtistStation()
        case .openAppleMusic:
            if let url = appleMusicURL {
                openLocalMusicAppleMusicURL(url, context: "artist-action title='\(displayArtist.name)'")
            }
        case .play, .shuffle, .favorite:
            break
        }
    }

    @ViewBuilder
    private var topSongsSection: some View {
        if !artistTopSongs.isEmpty {
            LocalMusicArtistTopSongsSection(
                artistName: displayArtist.name,
                songs: artistTopSongs,
                store: store,
                manager: manager,
                searchManager: searchManager
            )
            .padding(.top, 10)
            .padding(.bottom, 22)
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

    private func loadArtistDetails() async {
        do {
            detailedArtist = try await LocalMusicLibraryClient.shared.artistDetails(for: artist)
        } catch {
            SonosLog.debug(
                .localService,
                "Local Music artist catalog detail load failed title='\(artist.name)' error=\(error)")
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
                    "Artist Apple Music artwork tap has no resolved URL title='\(displayArtist.name)' " +
                        "rawURL='\(displayArtist.url?.absoluteString ?? "nil")' " +
                        "playableID='\(artistPlayable?.catalogID ?? "nil")'")
                return
            }
            openLocalMusicAppleMusicURL(url, context: "artist-artwork title='\(displayArtist.name)'")
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
                        "Artist Apple Music link resolved by catalog id title='\(displayArtist.name)' " +
                            "catalogID='\(catalogID)' url='\(urlString)'")
                    catalogAppleMusicURL = resolved
                    return resolved
                }
            } catch {
                guard !Task.isCancelled else { return nil }
                SonosLog.debug(
                    .localService,
                    "Artist Apple Music catalog id lookup failed title='\(displayArtist.name)' " +
                        "catalogID='\(catalogID)' error=\(error)")
            }
        }

        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: .artist,
            title: displayArtist.name,
            artist: displayArtist.name,
            album: nil)
        guard !term.isEmpty else { return nil }

        do {
            let items = try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: 8)
            let urlString = LocalMusicCatalogWebURLFallback.urlString(
                in: items,
                kind: .artist,
                title: displayArtist.name,
                artist: displayArtist.name,
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
                    "Artist Apple Music link search produced no usable URL title='\(displayArtist.name)' term='\(term)'")
                return nil
            }

            SonosLog.debug(.localService, "Artist Apple Music link resolved title='\(displayArtist.name)' url='\(urlString)'")
            catalogAppleMusicURL = resolved
            return resolved
        } catch {
            guard !Task.isCancelled else { return nil }
            SonosLog.debug(.localService, "Artist Apple Music link lookup failed title='\(displayArtist.name)' error=\(error)")
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
                fallbackTitle: displayArtist.name,
                fallbackArtist: displayArtist.name,
                manager: manager,
                searchManager: searchManager)
            withAnimation(.easeOut(duration: 0.2)) {
                actionInFlight = nil
            }
        }
    }
}
