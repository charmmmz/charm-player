import AVFoundation
import SwiftUI
import UIKit

// MARK: - Now Playing Full-Screen Overlay

struct NowPlayingOverlay: View {
    @Bindable var manager: SonosManager
    var searchManager: SearchManager
    let navigateToDetail: (PlayerDetailRoute) -> Void
    @State var volumeSliderValue: Double = 0
    @State var isDraggingVolume = false
    @State var premuteVolume: Int?
    @State var scrubPosition: TimeInterval = 0
    @State var isScrubbing = false
    @State var nowPlayingInfo: SonosCloudAPI.NowPlayingResponse?
    @State var lastFetchedTrackURI: String?
    @State var isOpeningAppleMusicLink = false
    @State var isAddingCurrentTrackToSonosFavorites = false
    @State var isAddingCurrentTrackToAppleMusicFavorites = false
    @State var currentAppleMusicTrackURL: URL?
    @StateObject var animatedArtworkState = AnimatedNowPlayingArtworkState()
    @State var animatedArtworkReadyURL: URL?
    @State var fullScreenAnimatedArtworkReadyURL: URL?
    /// Handle on the in-flight NowPlaying fetch so we can cancel it when
    /// the track changes again before the previous lookup resolves. Without
    /// this, a slow fetch for track A could land after track B's fetch and
    /// stomp the newer artist/album data, or — worse — the user could tap
    /// the album/artist link while stale `nowPlayingInfo` still holds the
    /// previous song, sending them to the wrong detail page.
    @State var nowPlayingFetchTask: Task<Void, Never>?
    @Environment(\.verticalSizeClass) var verticalSizeClass

    var albumArtTransitionID: String {
        manager.albumArtTransitionID()
    }

    var fullScreenAnimatedArtworkURL: URL? {
        guard let info = animatedArtworkState.currentInfo,
              AnimatedArtworkFeature.canRenderFullScreenTallArtwork(
                source: manager.trackInfo?.source,
                hasTallArtwork: info.tallArtworkURL != nil,
                isCompactHeight: verticalSizeClass == .compact
              ) else {
            return nil
        }
        return info.fullScreenPlayerURL
    }

    var fullScreenAnimatedArtworkAspectRatio: CGFloat? {
        guard let value = animatedArtworkState.currentInfo?.tallAspectRatio else {
            return nil
        }
        return CGFloat(value)
    }

    var usesFullScreenAnimatedArtwork: Bool {
        fullScreenAnimatedArtworkURL != nil
    }

    var shouldPlayAnimatedArtworkVideo: Bool {
        NowPlayingAnimatedArtworkPlaybackPolicy.shouldPlay(
            isFullPlayerVisible: manager.showFullPlayer
        )
    }

    var windowTopSafeAreaInset: CGFloat {
        UIApplication.shared.sonosPresentationWindow?.safeAreaInsets.top ?? 0
    }

    var windowBottomSafeAreaInset: CGFloat {
        UIApplication.shared.sonosPresentationWindow?.safeAreaInsets.bottom ?? 0
    }

    var dragHandleTopPadding: CGFloat {
        NowPlayingOverlayPresentation.dragHandleTopPadding(
            topSafeAreaInset: windowTopSafeAreaInset
        )
    }

    func bottomActionsBottomPadding(geo: GeometryProxy) -> CGFloat {
        NowPlayingOverlayPresentation.bottomActionsBottomPadding(
            bottomSafeAreaInset: max(geo.safeAreaInsets.bottom, windowBottomSafeAreaInset)
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height
                let backgroundSize = AnimatedArtworkFeature.fullScreenBackgroundContainerSize(
                    contentSize: geo.size,
                    topSafeAreaInset: geo.safeAreaInsets.top,
                    bottomSafeAreaInset: geo.safeAreaInsets.bottom
                )
                let backgroundTopOffset = AnimatedArtworkFeature.fullScreenBackgroundTopOffset(
                    topSafeAreaInset: geo.safeAreaInsets.top
                )
                ZStack(alignment: .top) {
                    artBackground(size: backgroundSize)
                        .offset(y: backgroundTopOffset)
                        .allowsHitTesting(false)

                    Group {
                        if isLandscape {
                            landscapeLayout(geo: geo)
                        } else {
                            portraitLayout(geo: geo)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .ignoresSafeArea(
            .container,
            edges: NowPlayingOverlayPresentation.internalIgnoredSafeAreaEdges
        )
        .padding(.horizontal, NowPlayingOverlayPresentation.horizontalPadding)
        .padding(.top, NowPlayingOverlayPresentation.topPadding)
        .onChange(of: manager.trackInfo?.trackURI) { _, newURI in
            guard let uri = newURI, uri != lastFetchedTrackURI else { return }
            lastFetchedTrackURI = uri
            // Immediately blank the stale artist/album payload so the
            // header's NavigationLinks fall back to plain Text until the
            // new track's response lands. If we skip this, tapping the
            // album or artist right after an external control point
            // (official Sonos app, voice assistant, etc.) changes the
            // song would still push the *previous* song's detail view.
            nowPlayingInfo = nil
            nowPlayingFetchTask?.cancel()
            nowPlayingFetchTask = Task {
                // Keep SearchManager's speaker IP in sync before probing —
                // if the selected speaker just became available, this lets
                // `ensureMusicServicesPopulated` reach the speaker.
                searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
                // Ensure the local-sid → cloud-service-id table is built
                // before we ask NowPlaying for artist / album ids.
                // Otherwise `fetchNowPlaying` bails early and the
                // artist / album text renders as plain Text (non-tappable)
                // until the user visits the Browse tab.
                await searchManager.probeLinkedServices()
                guard !Task.isCancelled else { return }
                await fetchNowPlaying(trackURI: uri)
            }
        }
        .onChange(of: manager.selectedSpeaker?.playbackIP) { _, newIP in
            // Selected speaker's IP just resolved (discovery finished,
            // user switched speakers, etc.) — reconfigure SearchManager
            // and (re-)build the sid mapping using the newly reachable
            // host, unblocking the artist / album links.
            guard let ip = newIP, !ip.isEmpty else { return }
            searchManager.configure(speakerIP: ip)
            Task {
                if !searchManager.hasFinishedProbing {
                    await searchManager.probeLinkedServices()
                } else {
                    await searchManager.refreshServiceIdMappingIfNeeded()
                }
                // Mapping may have just become available. If the
                // initial `fetchNowPlaying` ran with an empty mapping
                // and bailed, the `onChange(trackURI)` above won't
                // retry because `lastFetchedTrackURI` is already set
                // to the current URI. Force a retry here so the
                // artist / album links pick up without the user
                // having to tap a new song first.
                if nowPlayingInfo == nil, let uri = manager.trackInfo?.trackURI {
                    await fetchNowPlaying(trackURI: uri)
                }
            }
        }
        .task {
            // Feed SearchManager the current speaker IP *before* we probe
            // linked services so `ensureMusicServicesPopulated` has a
            // reachable host to hit — otherwise the local-sid ↔ cloud-sid
            // mapping never builds on first launch (user never visits
            // Browse), and the artist / album NavigationLinks below end
            // up non-tappable until the user flips to the Browse tab.
            searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
            await searchManager.probeLinkedServices()
            if let uri = manager.trackInfo?.trackURI, uri != lastFetchedTrackURI {
                lastFetchedTrackURI = uri
                await fetchNowPlaying(trackURI: uri)
            }
        }
        .task(id: currentAppleMusicLinkLookupID) {
            await refreshCurrentAppleMusicTrackURL()
        }
        .task(id: animatedArtworkLookupID) {
            refreshAnimatedArtwork()
        }
        .onChange(of: animatedArtworkState.currentURL) { oldURL, newURL in
            if oldURL != newURL {
                animatedArtworkReadyURL = nil
            }
        }
        .onChange(of: fullScreenAnimatedArtworkURL) { oldURL, newURL in
            if oldURL != newURL {
                fullScreenAnimatedArtworkReadyURL = nil
            }
        }
        .onDisappear {
            animatedArtworkState.reset()
            animatedArtworkReadyURL = nil
            fullScreenAnimatedArtworkReadyURL = nil
        }
        .sheet(isPresented: $manager.showingSpeakerPicker) {
            SpeakerPickerView(manager: manager)
        }
        .sheet(isPresented: $manager.showingQueue) {
            QueueView(manager: manager)
        }
    }

}
