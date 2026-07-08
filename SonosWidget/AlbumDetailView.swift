import AVFoundation
import SwiftUI

struct AlbumDetailView: View {
    let albumItem: BrowseItem
    let searchManager: SearchManager
    let manager: SonosManager
    @Environment(\.isAnimatedArtworkPlaybackSuspended) private var isAnimatedArtworkPlaybackSuspended

    @State private var response: SonosCloudAPI.AlbumBrowseResponse?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var playingItemId: String?
    @State private var toastMessage: String?
    @State private var isFavorited = false
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?
    @State private var isOpeningAppleMusicLink = false
    @State private var fallbackAppleMusicArtworkURL: URL?
    @State private var animatedArtworkInfo: AnimatedArtworkInfo?
    @State private var animatedArtworkReadyURL: URL?
    @State private var animatedArtworkBackgroundReadyURL: URL?
    @State private var resolvedAlbumID: String?

    private var shouldPlayAnimatedArtworkVideo: Bool {
        AlbumAnimatedArtworkPresentation.shouldPlayVideo(
            isEnabled: AnimatedArtworkFeature.isEnabled,
            isBackgroundPlaybackSuspended: isAnimatedArtworkPlaybackSuspended
        )
    }

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
    private var playbackAlbumItem: BrowseItem {
        AlbumPlaybackItemPolicy.playbackItem(from: albumItem, resolvedAlbumID: resolvedAlbumID)
    }
    private var appleMusicArtworkResource: AppleMusicFavoriteResource? {
        AppleMusicDetailArtworkLink.resource(
            from: albumItem,
            searchManager: searchManager,
            allowedTypes: [.albums]
        )
    }
    private var canResolveAppleMusicAlbumURL: Bool {
        appleMusicArtworkResource != nil || fallbackAppleMusicArtworkURL != nil || canSearchAppleMusicAlbumURL
    }
    private var canSearchAppleMusicAlbumURL: Bool {
        AppleMusicExternalLinkResolver.isAppleMusicItem(albumItem, searchManager: searchManager)
            && AppleMusicFavoriteResourceType(cloudType: albumItem.cloudType) == .albums
            && meaningfulAppleMusicSearchValue(albumTitle) != nil
            && meaningfulAppleMusicSearchValue(artistName) != nil
    }
    private var appleMusicAlbumLinkLookupID: String {
        [
            albumItem.id,
            albumItem.uri ?? "",
            albumTitle,
            artistName,
            appleMusicArtworkResource?.id ?? ""
        ].joined(separator: "|")
    }
    private var animatedArtworkHeaderURL: URL? {
        AlbumAnimatedArtworkPresentation.headerURL(
            info: animatedArtworkInfo,
            isEnabled: AnimatedArtworkFeature.isEnabled,
            isImmersiveLayoutActive: usesImmersiveAnimatedArtwork
        )
    }
    private var animatedArtworkBackgroundURL: URL? {
        AlbumAnimatedArtworkPresentation.fullScreenBackgroundURL(
            info: animatedArtworkInfo,
            isEnabled: AnimatedArtworkFeature.isEnabled
        )
    }
    private var animatedArtworkBackgroundAspectRatio: CGFloat? {
        guard let value = animatedArtworkInfo?.tallAspectRatio else { return nil }
        return CGFloat(value)
    }
    private var usesImmersiveAnimatedArtwork: Bool {
        AlbumAnimatedArtworkPresentation.shouldUseImmersiveLayout(
            backgroundURL: animatedArtworkBackgroundURL,
            readyURL: animatedArtworkBackgroundReadyURL
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                albumScrollableContent
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
        .task(id: appleMusicAlbumLinkLookupID) {
            await refreshAppleMusicArtworkURL()
        }
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
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                staticAlbumBackground

                if let url = animatedArtworkBackgroundURL {
                    albumAnimatedArtworkBackground(
                        url: url,
                        size: size
                    )
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .opacity(animatedArtworkBackgroundReadyURL == url ? 1 : 0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }

                albumBackgroundScrim
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.28), value: animatedArtworkBackgroundReadyURL)
    }

    @ViewBuilder
    private var staticAlbumBackground: some View {
        if let img = coverImage {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 80)
                .scaleEffect(1.5)
                .ignoresSafeArea()
        } else {
            Color(.systemBackground).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func albumAnimatedArtworkBackground(
        url: URL,
        size: CGSize
    ) -> some View {
        let containerAspectRatio = size.height > 0 ? size.width / size.height : 0
        let videoAspectRatio = animatedArtworkBackgroundAspectRatio
        let usesBlurFill = AnimatedArtworkFeature.shouldUseBlurFillForFullScreenArtwork(
            videoAspectRatio: videoAspectRatio,
            containerAspectRatio: containerAspectRatio
        )

        if usesBlurFill {
            albumAnimatedArtworkBlurFill(
                url: url,
                size: size,
                videoAspectRatio: videoAspectRatio
            )
        } else {
            AnimatedArtworkPlayerView(
                url: url,
                isPlaying: shouldPlayAnimatedArtworkVideo,
                videoGravity: .resizeAspectFill,
                onReadyForDisplay: {
                    markAnimatedArtworkBackgroundReady(url)
                }
            )
        }
    }

    private func albumAnimatedArtworkBlurFill(
        url: URL,
        size: CGSize,
        videoAspectRatio: CGFloat?
    ) -> some View {
        let foregroundSize = AnimatedArtworkFeature.fullScreenBlurFillForegroundSize(
            containerSize: size,
            videoAspectRatio: videoAspectRatio
        )
        let foregroundTopOffset = AnimatedArtworkFeature.fullScreenBlurFillForegroundTopOffset(
            containerSize: size
        )

        return ZStack(alignment: .top) {
            FullScreenAnimatedArtworkExtensionBackdrop(
                size: size,
                videoAspectRatio: videoAspectRatio
            )

            AnimatedArtworkPlayerView(
                url: url,
                isPlaying: shouldPlayAnimatedArtworkVideo,
                videoGravity: .resizeAspect,
                onReadyForDisplay: {
                    markAnimatedArtworkBackgroundReady(url)
                }
            )
            .frame(width: foregroundSize.width, height: foregroundSize.height, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.54),
                        .init(color: .black.opacity(0.6), location: 0.72),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .offset(y: foregroundTopOffset)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }

    private func markAnimatedArtworkBackgroundReady(_ url: URL) {
        if animatedArtworkBackgroundURL == url {
            animatedArtworkBackgroundReadyURL = url
        }
    }

    @ViewBuilder
    private var albumBackgroundScrim: some View {
        if usesImmersiveAnimatedArtwork {
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.08), location: 0.0),
                        .init(color: .black.opacity(0.08), location: 0.36),
                        .init(color: .black.opacity(0.48), location: 0.58),
                        .init(color: .black.opacity(0.88), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.32)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.34),
                                .init(color: .black.opacity(0.35), location: 0.58),
                                .init(color: .black, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        } else {
            Color.black
                .opacity(coverImage != nil ? 0.52 : 0)
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
                    await searchManager.playNext(item: playbackAlbumItem, manager: manager)
                    showToast("Playing next")
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                Task {
                    await searchManager.addToQueue(item: playbackAlbumItem, manager: manager)
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

    private var albumScrollableContent: some View {
        VStack(spacing: 0) {
            actionBar
                .padding(.top, 16)
                .padding(.bottom, 8)
            trackList
        }
        .background(alignment: .top) {
            if usesImmersiveAnimatedArtwork {
                immersiveScrollableContentBackdrop
                    .padding(
                        .top,
                        AlbumAnimatedArtworkPresentation.contentBackdropTopPadding(
                            isImmersive: usesImmersiveAnimatedArtwork
                        )
                    )
            }
        }
    }

    @ViewBuilder
    private var immersiveScrollableContentBackdrop: some View {
        let topOpacity = AlbumAnimatedArtworkPresentation.contentBackdropTopOpacity(
            isImmersive: usesImmersiveAnimatedArtwork
        )
        let strongFadeLocation = AlbumAnimatedArtworkPresentation.contentBackdropStrongFadeLocation(
            isImmersive: usesImmersiveAnimatedArtwork
        )
        let minimumHeight = AlbumAnimatedArtworkPresentation.contentBackdropMinimumHeight(
            isImmersive: usesImmersiveAnimatedArtwork,
            viewportHeight: UIScreen.main.bounds.height
        )

        ZStack(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(topOpacity), location: 0),
                    .init(color: .black.opacity(0.14), location: 0.22),
                    .init(color: .black.opacity(0.62), location: strongFadeLocation),
                    .init(color: .black.opacity(0.94), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.42)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.24),
                            .init(color: .black.opacity(0.42), location: 0.52),
                            .init(color: .black, location: 0.88)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
        .ignoresSafeArea(edges: .horizontal)
        .allowsHitTesting(false)
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            if usesImmersiveAnimatedArtwork {
                immersiveAnimatedArtworkHeaderSpacer
            } else {
                headerArtwork
            }

            VStack(spacing: 4) {
                albumTitleLabel

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
        .padding(.top, usesImmersiveAnimatedArtwork ? 0 : 20)
    }

    private var immersiveAnimatedArtworkHeaderSpacer: some View {
        Color.clear
            .frame(
                height: AlbumAnimatedArtworkPresentation.immersiveHeaderSpacerHeight(
                    containerWidth: UIScreen.main.bounds.width,
                    viewportHeight: UIScreen.main.bounds.height,
                    videoAspectRatio: animatedArtworkBackgroundAspectRatio
                )
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var headerArtwork: some View {
        if AlbumHeaderAppleMusicLinkPolicy.shouldLinkArtwork(
            canResolveAppleMusicURL: canResolveAppleMusicAlbumURL
        ) {
            Button {
                openAppleMusicFromTitle()
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

    @ViewBuilder
    private var albumTitleLabel: some View {
        if AlbumHeaderAppleMusicLinkPolicy.shouldLinkTitle(
            canResolveAppleMusicURL: canResolveAppleMusicAlbumURL
        ) {
            Button {
                openAppleMusicFromTitle()
            } label: {
                albumTitleText
            }
            .buttonStyle(.plain)
            .disabled(isOpeningAppleMusicLink)
            .accessibilityLabel("Open \(albumTitle) in Apple Music")
        } else {
            albumTitleText
        }
    }

    private var albumTitleText: some View {
        Text(albumTitle)
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
    }

    private var headerArtworkImage: some View {
        ZStack {
            headerStaticArtworkImage

            if let url = animatedArtworkHeaderURL {
                AnimatedArtworkPlayerView(
                    url: url,
                    isPlaying: shouldPlayAnimatedArtworkVideo,
                    videoGravity: .resizeAspectFill
                ) {
                    if animatedArtworkHeaderURL == url {
                        animatedArtworkReadyURL = url
                    }
                }
                .aspectRatio(1, contentMode: .fill)
                .opacity(animatedArtworkReadyURL == url ? 1 : 0)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 280)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .animation(.easeInOut(duration: 0.28), value: animatedArtworkReadyURL)
    }

    private var headerStaticArtworkImage: some View {
        Group {
            if let img = coverImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        Image(systemName: "opticaldisc")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
    }

    private func openAppleMusicFromTitle() {
        guard !isOpeningAppleMusicLink else { return }
        let cachedURL = fallbackAppleMusicArtworkURL
        let resource = appleMusicArtworkResource
        let lookupID = appleMusicAlbumLinkLookupID
        let title = albumTitle
        let artist = artistName
        isOpeningAppleMusicLink = true
        Task { @MainActor in
            defer { isOpeningAppleMusicLink = false }
            do {
                let resolvedURL: URL?
                if let cachedURL {
                    resolvedURL = cachedURL
                } else {
                    resolvedURL = try await AppleMusicExternalLinkFallbackResolver().albumURL(
                        directResource: resource,
                        title: title,
                        artist: artist
                    )
                    if appleMusicAlbumLinkLookupID == lookupID {
                        fallbackAppleMusicArtworkURL = resolvedURL
                    }
                }

                guard let url = resolvedURL else {
                    SonosLog.debug(
                        .localService,
                        "Apple Music album title lookup produced no URL title='\(title)' artist='\(artist)' id='\(resource?.id ?? "nil")'"
                    )
                    return
                }
                AppleMusicExternalLinkOpener.open(
                    url,
                    context: "sonos-album-title title='\(title)' id='\(resource?.id ?? "nil")'"
                )
            } catch {
                SonosLog.error(
                    .localService,
                    "Apple Music album title lookup failed title='\(title)' artist='\(artist)' id='\(resource?.id ?? "nil")' error=\(error)"
                )
            }
        }
    }

    @MainActor
    private func refreshAppleMusicArtworkURL() async {
        fallbackAppleMusicArtworkURL = nil
        applyCachedAnimatedArtwork(appleMusicURLString: nil)
        guard canSearchAppleMusicAlbumURL || appleMusicArtworkResource != nil else {
            setAnimatedArtworkInfo(nil)
            return
        }
        let lookupID = appleMusicAlbumLinkLookupID
        let title = albumTitle
        let artist = artistName
        do {
            let url = try await AppleMusicExternalLinkFallbackResolver().albumURL(
                directResource: appleMusicArtworkResource,
                title: title,
                artist: artist
            )
            guard appleMusicAlbumLinkLookupID == lookupID else { return }
            fallbackAppleMusicArtworkURL = url
            if let url {
                await prewarmAnimatedArtwork(albumURL: url)
            } else {
                applyCachedAnimatedArtwork(appleMusicURLString: nil)
            }
        } catch {
            guard appleMusicAlbumLinkLookupID == lookupID else { return }
            SonosLog.debug(
                .localService,
                "Apple Music album URL preload failed title='\(title)' artist='\(artist)' error=\(error)"
            )
        }
    }

    @MainActor
    private func prewarmAnimatedArtwork(albumURL: URL) async {
        guard AnimatedArtworkFeature.isEnabled,
              let relayBaseURL = RelayManager.shared.url else {
            applyCachedAnimatedArtwork(appleMusicURLString: albumURL.absoluteString)
            return
        }

        applyCachedAnimatedArtwork(appleMusicURLString: albumURL.absoluteString)
        if animatedArtworkInfo != nil { return }

        do {
            let response = try await RelayClient.animatedArtworkByURL(
                baseURL: relayBaseURL,
                albumURL: albumURL
            )
            guard let info = AnimatedArtworkInfo(
                response: response,
                fallbackAppleMusicURLString: albumURL.absoluteString,
                fallbackArtist: artistName,
                fallbackAlbum: albumTitle,
                resolvedAt: Date()
            ) else {
                return
            }
            AnimatedArtworkRegistry.shared.register(info)
            setAnimatedArtworkInfo(info)
        } catch {
            SonosLog.debug(
                .albumDetail,
                "Animated album artwork prewarm failed title='\(albumTitle)' artist='\(artistName)' error=\(error)"
            )
        }
    }

    @MainActor
    private func applyCachedAnimatedArtwork(appleMusicURLString: String?) {
        guard AnimatedArtworkFeature.isEnabled else {
            setAnimatedArtworkInfo(nil)
            return
        }

        let cached = AnimatedArtworkRegistry.shared.artwork(
            appleMusicURLString: appleMusicURLString,
            artist: artistName,
            album: albumTitle
        )
        setAnimatedArtworkInfo(cached)
    }

    private func setAnimatedArtworkInfo(_ next: AnimatedArtworkInfo?) {
        let shouldResetReadyState = AlbumAnimatedArtworkPresentation.shouldResetReadyState(
            current: animatedArtworkInfo,
            next: next
        )
        guard animatedArtworkInfo != next else { return }
        animatedArtworkInfo = next
        if shouldResetReadyState {
            animatedArtworkReadyURL = nil
            animatedArtworkBackgroundReadyURL = nil
        }
    }

    private func meaningfulAppleMusicSearchValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "—",
              trimmed.localizedCaseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        return trimmed
    }

    @ViewBuilder
    private var artistLabel: some View {
        let label = Text(artistName)
            .font(MusicDetailHeaderTypography.sonosAlbumArtistStyle.font)
            .fontWeight(.regular)
            .foregroundStyle(.white.opacity(MusicDetailHeaderTypography.artistOpacity))
            .lineLimit(2)

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
        let appleMusicResource = searchManager.appleMusicFavoriteResource(for: item)

        MusicResourceContextMenu(
            actions: AlbumTrackMenuActionPolicy.songActions(
                isSonosFavoriteActive: trackFavorited,
                isAppleMusicFavoriteActive: false,
                isQueueable: item.playbackDescriptor.isQueueable,
                isAppleMusicFavoriteAvailable: appleMusicResource != nil
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
        case .favorite(.sonos, _, _):
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
        case .favorite(.appleMusic, _, _):
            Task {
                let ok = await searchManager.toggleAppleMusicFavorites(for: item)
                showToast(ok ? "Updated Apple Music Favorites" : "Failed to update Apple Music")
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
        resolvedAlbumID = browseAlbumId
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
            await searchManager.playNow(item: playbackAlbumItem, manager: manager)
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
            await searchManager.playNow(item: playbackAlbumItem, manager: manager)
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
