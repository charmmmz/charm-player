import SwiftUI

struct AlbumDetailView: View {
    let albumItem: BrowseItem
    let searchManager: SearchManager
    let manager: SonosManager

    @State private var response: SonosCloudAPI.AlbumBrowseResponse?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var playingItemId: String?
    @State private var toastMessage: String?
    @State private var isFavorited = false
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?
    @State private var isOpeningAppleMusicLink = false

    private var albumTitle: String { response?.title ?? albumItem.title }
    private var artistName: String { response?.subtitle ?? albumItem.artist }
    /// Resolves the album cover from any non-empty image source. NetEase Cloud
    /// Music's browseAlbum often omits the album-level image but populates
    /// each track's `images.tile1x1`, so we fall through to the first track's
    /// art before giving up and showing the placeholder disc icon.
    private var coverURL: String? {
        DetailArtworkURLSelection.firstAvailable(
            entryArtworkURL: albumItem.preferredDetailArtworkURL,
            responseArtworkURL: response?.images?.tile1x1,
            fallbackArtworkURL: response?.tracks?.items?.first?.images?.tile1x1
        )
    }
    private var tracks: [SonosCloudAPI.AlbumTrackItem] {
        response?.tracks?.items ?? []
    }
    private var appleMusicArtworkResource: AppleMusicFavoriteResource? {
        AppleMusicDetailArtworkLink.resource(
            from: albumItem,
            searchManager: searchManager,
            allowedTypes: [.albums]
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                actionBar
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                trackList
            }
        }
        .background {
            albumBackground
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                albumMenu
            }
        }
        .task { await loadAlbum() }
        .task(id: coverURL) { await loadCoverImage() }
        .task {
            // Sonos Favorites are only fetched by SearchView's task; if the
            // user opens this page before visiting Browse, `isFavorited`
            // would always return false. Trigger a one-shot load and resync.
            await searchManager.ensureBrowseContentLoaded(manager: manager)
            isFavorited = searchManager.isFavorited(albumItem)
        }
        .onAppear { isFavorited = searchManager.isFavorited(albumItem) }
        .toast($toastMessage)
    }

    // MARK: - Blurred Background

    @ViewBuilder
    private var albumBackground: some View {
        if let img = coverImage {
            ZStack {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                Color.black.opacity(0.5)
            }
            .ignoresSafeArea()
        } else {
            Color(.systemBackground).ignoresSafeArea()
        }
    }

    private func loadCoverImage() async {
        logArtworkSelection(trigger: "loadCoverImage")
        guard let urlStr = coverURL, let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled, coverURL == urlStr else { return }
            let img = UIImage(data: data)
            coverImage = img
            if let uiColor = img?.dominantUIColor() {
                themeColor = AlbumThemeColorPolicy.mutedColor(from: uiColor)
            } else if let color = img?.dominantColor() {
                themeColor = color.opacity(0.55)
            }
        } catch {
            if (error as NSError).code == NSURLErrorCancelled { return }
            SonosLog.error(.albumDetail, "Cover image load failed: \(error)")
        }
    }

    private func logArtworkSelection(trigger: String) {
        SonosLog.debug(
            .albumDetail,
            "Artwork selection trigger=\(trigger) title='\(albumItem.title)' " +
            "rawId=\(SonosLog.playbackLinkValue(albumItem.id, maxLength: 640)) " +
            "entry=\(SonosLog.playbackLinkValue(albumItem.albumArtURL, maxLength: 640)) " +
            "entryDetail=\(SonosLog.playbackLinkValue(albumItem.detailArtworkURL, maxLength: 640)) " +
            "response=\(SonosLog.playbackLinkValue(response?.images?.tile1x1, maxLength: 640)) " +
            "fallback=\(SonosLog.playbackLinkValue(response?.tracks?.items?.first?.images?.tile1x1, maxLength: 640)) " +
            "selected=\(SonosLog.playbackLinkValue(coverURL, maxLength: 640))")
    }

    // MARK: - Three-Dot Menu

    private var albumMenu: some View {
        Menu {
            Button {
                Task {
                    await searchManager.playNext(item: albumItem, manager: manager)
                    showToast("Playing next")
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                Task {
                    await searchManager.addToQueue(item: albumItem, manager: manager)
                    showToast("Added to queue")
                }
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 10) {
            headerArtwork

            VStack(spacing: 4) {
                Text(albumTitle)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                artistLabel

                if let total = response?.tracks?.total {
                    Text(albumSubtitle(trackCount: total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private var headerArtwork: some View {
        if let resource = appleMusicArtworkResource {
            Button {
                openAppleMusicFromArtwork(resource: resource)
            } label: {
                headerArtworkImage
            }
            .buttonStyle(.plain)
            .disabled(isOpeningAppleMusicLink)
            .accessibilityLabel("Open album in Apple Music")
        } else {
            headerArtworkImage
        }
    }

    private var headerArtworkImage: some View {
        Group {
            if let img = coverImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "opticaldisc")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(maxWidth: 280)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }

    private func openAppleMusicFromArtwork(resource: AppleMusicFavoriteResource) {
        guard !isOpeningAppleMusicLink else { return }
        isOpeningAppleMusicLink = true
        Task { @MainActor in
            defer { isOpeningAppleMusicLink = false }
            await AppleMusicDetailArtworkLink.open(
                resource: resource,
                title: albumTitle,
                context: "sonos-album-artwork"
            )
        }
    }

    @ViewBuilder
    private var artistLabel: some View {
        let label = Text(artistName)
            .font(.subheadline)
            .foregroundStyle(themeColor ?? .secondary)

        if let nav = artistBrowseItem {
            NavigationLink {
                ArtistDetailView(artistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    /// Resolve the album's primary artist into a navigable `BrowseItem`.
    /// Uses the first track whose primary artist matches the album subtitle so
    /// "Various Artists" / featured artist tracks don't hijack the link.
    private var artistBrowseItem: BrowseItem? {
        let preferred = tracks.first { $0.artists?.first?.name == artistName } ?? tracks.first
        guard let track = preferred,
              let artist = track.artists?.first,
              let rawId = artist.id,
              let serviceId = track.resource?.id?.serviceId,
              let accountId = track.resource?.id?.accountId else { return nil }

        // `id` looks like "appleMusic:artist:12345#…" — strip the suffix and take the last component.
        let base = rawId.firstIndex(of: "#").map { String(rawId[..<$0]) } ?? rawId
        guard let objectId = base.components(separatedBy: ":").last,
              !objectId.isEmpty else { return nil }

        return searchManager.makeArtistItem(
            objectId: objectId,
            name: artist.name ?? artistName,
            cloudServiceId: serviceId,
            accountId: accountId)
    }

    private func albumSubtitle(trackCount: Int) -> String {
        var parts: [String] = []
        if let provider = response?.providerInfo?.name {
            parts.append(provider)
        }
        parts.append("\(trackCount) tracks")
        parts.append(totalDuration)
        return parts.joined(separator: " · ")
    }

    private var totalDuration: String {
        let seconds = tracks.compactMap { Int($0.duration ?? "") }.reduce(0, +)
        let mins = seconds / 60
        if mins >= 60 {
            return "\(mins / 60) hr \(mins % 60) min"
        }
        return "\(mins) min"
    }

    // MARK: - Action Bar (Play / Shuffle)

    private var actionBar: some View {
        AlbumPrimaryActionBar(
            favoriteKind: .sonos,
            tint: themeColor,
            isPlayActive: playingItemId == "play-all",
            isShuffleActive: playingItemId == "shuffle",
            isFavoriteActive: isFavorited,
            isFavoriteBusy: false,
            isFavoriteDisabled: false,
            isPlaybackDisabled: playingItemId != nil,
            play: playAlbum,
            shuffle: playAlbumShuffled,
            toggleFavorite: toggleFavorite
        )
    }

    // MARK: - Track List

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 40)
        } else if let err = errorText {
            ContentUnavailableView("Failed to Load",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(err))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { idx, track in
                    trackRow(track, isLast: idx == tracks.count - 1)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private func trackRow(_ track: SonosCloudAPI.AlbumTrackItem, isLast: Bool) -> some View {
        let isPlaying = playingItemId == track.id
        let isDisabled = playingItemId != nil && !isPlaying
        let item = browseItemFromTrack(track)

        return AlbumTrackRow(
            number: "\(track.ordinal ?? 0)",
            title: track.title ?? "",
            subtitle: AlbumTrackSubtitlePolicy.subtitle(
                trackArtist: track.artists?.first?.name,
                albumArtist: artistName
            ),
            duration: formattedDuration(track.duration),
            isExplicit: track.isExplicit == true,
            isPlaying: isPlaying,
            isDisabled: isDisabled,
            isLast: isLast,
            action: { playTrack(track) }
        ) {
            trackContextMenu(track, item: item)
        }
    }

    @ViewBuilder
    private func trackContextMenu(
        _ track: SonosCloudAPI.AlbumTrackItem,
        item: BrowseItem
    ) -> some View {
        let trackFavorited = searchManager.isFavorited(item)

        MusicResourceContextMenu(
            actions: AlbumTrackMenuActionPolicy.actions(
                favoriteKind: .sonos,
                isFavoriteActive: trackFavorited,
                isQueueable: item.playbackDescriptor.isQueueable
            )
        ) { action in
            performTrackMenuAction(action, track: track, item: item)
        }
    }

    private func performTrackMenuAction(
        _ action: MusicResourceMenuAction,
        track: SonosCloudAPI.AlbumTrackItem,
        item: BrowseItem
    ) {
        switch action {
        case .playNow:
            playTrack(track)
        case .playNext:
            Task { await searchManager.playNext(item: item, manager: manager) }
            showToast("Playing next")
        case .addToQueue:
            Task { await searchManager.addToQueue(item: item, manager: manager) }
            showToast("Added to queue")
        case .favorite:
            Task {
                let trackFavorited = searchManager.isFavorited(item)
                if trackFavorited {
                    let ok = await searchManager.removeFromFavorites(item: item, manager: manager)
                    showToast(ok ? "Removed from Favorites" : "Failed to remove")
                } else {
                    let ok = await searchManager.addToFavorites(item: item, manager: manager)
                    showToast(ok ? "Added to Favorites" : "Failed to add")
                }
            }
        case .startStation:
            break
        }
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        withAnimation(ToastModifier.fadeAnimation) { toastMessage = message }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    private func formattedDuration(_ rawDuration: String?) -> String? {
        guard let rawDuration,
              let seconds = Int(rawDuration) else {
            return nil
        }
        return formatDuration(seconds)
    }

    private func browseItemFromTrack(_ track: SonosCloudAPI.AlbumTrackItem) -> BrowseItem {
        searchManager.makeAlbumTrackItem(
            from: track,
            fallbackAlbumTitle: albumTitle,
            fallbackArtist: artistName,
            fallbackArtURL: coverURL
        )
    }

    // MARK: - Data Loading

    private func loadAlbum() async {
        guard response == nil else { isLoading = false; return }
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            errorText = "Not logged in to Sonos Cloud"
            isLoading = false
            return
        }

        let serviceIdStr: String? = {
            if let sid = albumItem.serviceId {
                return searchManager.cloudServiceId(forLocalSid: sid)
            }
            return searchManager.activeServiceIds.first
        }()

        guard let serviceId = serviceIdStr else {
            errorText = "No music service linked"
            isLoading = false
            return
        }

        let accountId = accountIdFromURI(albumItem.uri) ?? searchManager.linkedAccounts
            .first { $0.serviceId == serviceId }?.accountId ?? "2"
        guard let browseAlbumId = await resolvedAlbumBrowseID(
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId
        ) else {
            SonosLog.error(
                .albumDetail,
                "No browseable album id for rawId='\(albumItem.id)' " +
                "title='\(albumItem.title)' artist='\(albumItem.artist)'")
            errorText = "Album ID unavailable"
            isLoading = false
            return
        }
        SonosLog.debug(
            .albumDetail,
            "browseAlbum rawId='\(albumItem.id)' normalizedId='\(browseAlbumId)' " +
            "title='\(albumItem.title)' artist='\(albumItem.artist)' " +
            "serviceId='\(serviceId)' accountId='\(accountId)' uri='\(albumItem.uri ?? "nil")'")

        do {
            response = try await SonosCloudAPI.browseAlbum(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                albumId: browseAlbumId)
            logArtworkSelection(trigger: "browseAlbumResponse")
            isLoading = false
        } catch is CancellationError {
            SonosLog.debug(.albumDetail, "Load cancelled (tab switch)")
        } catch {
            SonosLog.error(.albumDetail, "Load failed: \(error)")
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    private func resolvedAlbumBrowseID(
        token: String,
        householdId: String,
        serviceId: String,
        accountId: String
    ) async -> String? {
        if let directID = SonosAlbumBrowseID.concreteAlbumID(from: albumItem.id) {
            return directID
        }

        SonosLog.info(
            .albumDetail,
            "Resolving missing album id via search rawId='\(albumItem.id)' " +
            "title='\(albumItem.title)' artist='\(albumItem.artist)'")

        do {
            let searchResult = try await SonosCloudAPI.searchService(
                token: token,
                householdId: householdId,
                serviceId: serviceId,
                accountId: accountId,
                term: albumItem.title,
                count: 50
            )
            let resolvedID = SonosAlbumSearchResolver.preferredAlbumID(
                in: searchResult,
                title: albumItem.title,
                artist: albumItem.artist
            )
            SonosLog.info(
                .albumDetail,
                "Resolved missing album id title='\(albumItem.title)' id='\(resolvedID ?? "nil")'")
            return resolvedID
        } catch is CancellationError {
            return nil
        } catch {
            SonosLog.error(.albumDetail, "Album id search resolution failed: \(error)")
            return nil
        }
    }

    private func accountIdFromURI(_ uri: String?) -> String? {
        guard let queryPart = uri?.split(separator: "?").last else { return nil }
        for param in queryPart.split(separator: "&") {
            let kv = param.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "sn" {
                return String(kv[1])
            }
        }
        return nil
    }

    // MARK: - Playback

    private func playAlbum() {
        guard playingItemId == nil else { return }
        playingItemId = "play-all"

        Task {
            if let ip = manager.selectedSpeaker?.playbackIP {
                let current = try? await SonosAPI.getPlayMode(ip: ip)
                if current?.shuffle == true {
                    try? await SonosAPI.setPlayMode(ip: ip, shuffle: false,
                                                    repeat: current?.repeat ?? .off)
                }
            }
            await searchManager.playNow(item: albumItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func playAlbumShuffled() {
        guard playingItemId == nil else { return }
        playingItemId = "shuffle"

        Task {
            if let ip = manager.selectedSpeaker?.playbackIP {
                let current = try? await SonosAPI.getPlayMode(ip: ip)
                try? await SonosAPI.setPlayMode(ip: ip, shuffle: true,
                                                repeat: current?.repeat ?? .off)
            }
            await searchManager.playNow(item: albumItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func playTrack(_ track: SonosCloudAPI.AlbumTrackItem) {
        guard playingItemId == nil else { return }
        playingItemId = track.id

        let item = browseItemFromTrack(track)
        Task {
            await searchManager.playNow(item: item, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func toggleFavorite() {
        Task {
            if isFavorited {
                let ok = await searchManager.removeFromFavorites(item: albumItem, manager: manager)
                if ok { isFavorited = false }
                showToast(ok ? "Removed from Favorites" : "Failed to remove")
            } else {
                let ok = await searchManager.addToFavorites(item: albumItem, manager: manager)
                if ok { isFavorited = true }
                showToast(ok ? "Added to Favorites" : "Failed to add")
            }
        }
    }
}
