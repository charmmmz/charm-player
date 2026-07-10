import AVFoundation
import SwiftUI


extension AlbumDetailView {

    // MARK: - Three-Dot Menu

    var albumMenu: some View {
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

    var albumScrollableContent: some View {
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
    var immersiveScrollableContentBackdrop: some View {
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

    var headerSection: some View {
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

    var immersiveAnimatedArtworkHeaderSpacer: some View {
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
    var headerArtwork: some View {
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
    var albumTitleLabel: some View {
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

    var albumTitleText: some View {
        Text(albumTitle)
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
    }

    var headerArtworkImage: some View {
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

    var headerStaticArtworkImage: some View {
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

    func openAppleMusicFromTitle() {
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
    func refreshAppleMusicArtworkURL() async {
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
    func prewarmAnimatedArtwork(albumURL: URL) async {
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
    func applyCachedAnimatedArtwork(appleMusicURLString: String?) {
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

    func setAnimatedArtworkInfo(_ next: AnimatedArtworkInfo?) {
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

    func meaningfulAppleMusicSearchValue(_ value: String?) -> String? {
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
    var artistLabel: some View {
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
    var artistBrowseItem: BrowseItem? {
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

    func albumSubtitle(trackCount: Int) -> String {
        var parts: [String] = []
        if let provider = response?.providerInfo?.name {
            parts.append(provider)
        }
        parts.append("\(trackCount) tracks")
        parts.append(totalDuration)
        return parts.joined(separator: " · ")
    }

    var totalDuration: String {
        let seconds = tracks.compactMap { Int($0.duration ?? "") }.reduce(0, +)
        let mins = seconds / 60
        if mins >= 60 {
            return "\(mins / 60) hr \(mins % 60) min"
        }
        return "\(mins) min"
    }

}
