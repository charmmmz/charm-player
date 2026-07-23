import Observation
import SwiftUI
import UIKit

struct ContentView: View {
    @State var manager = SonosManager()
    @State var searchManager = SearchManager()
    @State private var selectedTab: AppTab = .home
    @State private var pendingAppleMusicShare: PendingAppleMusicShare?
    @State private var playerDetailPath: [PlayerDetailRoute] = []
    @State private var miniPlayerDragPresentation = MiniPlayerDragPresentationState()

    var body: some View {
        mainTabs
        // Bound to the shared `manager.showingAddSpeaker` flag so either the
        // first-run setup screen or the Settings tab can flip it from any tab.
        .sheet(isPresented: $manager.showingAddSpeaker) {
            AddSpeakerSheet(manager: manager)
        }
        // Match Queue's native sheet presentation so UIKit owns the pan,
        // corner mask, and interactive dismissal instead of moving the full
        // player render tree on every drag sample.
        .sheet(isPresented: $manager.showFullPlayer) {
            NowPlayingSheetHost(
                manager: manager,
                searchManager: searchManager,
                navigateToDetail: routeFromNowPlaying
            )
        }
        .preferredColorScheme(.dark)
        .onAppear {
            syncPlayerOrientationPolicy()
            manager.startAutoRefresh()
            // Kick the relay watchdog so the Live Activity path can flip to
            // APNs mode the moment the NAS is reachable, without making the
            // user open Settings first.
            RelayManager.shared.startPeriodicProbe()
            MusicAmbienceManager.shared.refreshStatus()
            routePendingAppleMusicShareToHomeIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appleMusicShareRouteReceived)) { _ in
            routePendingAppleMusicShareToHomeIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hueAmbienceRelayRunningChanged)) { notification in
            guard let running = notification.object as? Bool else { return }
            HueAmbienceStore.shared.isEnabled = running
            MusicAmbienceManager.shared.refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            routePendingAppleMusicShareToHomeIfNeeded()
            syncPlayerOrientationPolicy()
            Task {
                await RelayManager.shared.probeNow()
                MusicAmbienceManager.shared.refreshStatus()
            }
        }
        .onChange(of: manager.isConfigured) { _, _ in
            syncPlayerOrientationPolicy()
        }
        .onChange(of: manager.showFullPlayer) { _, _ in
            syncPlayerOrientationPolicy()
        }
        .onDisappear {
            AppOrientationController.setPlayerLandscapeAllowed(false)
            manager.stopAutoRefresh()
            RelayManager.shared.stopPeriodicProbe()
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "play.circle.fill", value: AppTab.home) {
                PlayerView(
                    manager: manager,
                    searchManager: searchManager,
                    pendingAppleMusicShare: $pendingAppleMusicShare,
                    detailPath: $playerDetailPath)
                    .miniPlayerTabContentInset(
                        manager: manager,
                        dragOffset: miniPlayerDragOffsetBinding)
            }
            Tab("Browse", systemImage: "magnifyingglass", value: AppTab.browse) {
                SearchView(manager: manager, searchManager: searchManager)
                    .miniPlayerTabContentInset(
                        manager: manager,
                        dragOffset: miniPlayerDragOffsetBinding)
            }
            Tab("Local Service", systemImage: "music.note.house", value: AppTab.localService) {
                LocalLibraryView(manager: manager, searchManager: searchManager)
                    .miniPlayerTabContentInset(
                        manager: manager,
                        dragOffset: miniPlayerDragOffsetBinding)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(manager: manager, searchManager: searchManager)
                    .miniPlayerTabContentInset(
                        manager: manager,
                        dragOffset: miniPlayerDragOffsetBinding)
            }
        }
        .environment(\.isAnimatedArtworkPlaybackSuspended, manager.showFullPlayer)
        .tint(manager.albumArtDominantColor ?? .blue)
        .tabBarMinimizeOnScrollIfAvailable()
        .miniPlayerSystemAccessoryIfAvailable(
            manager: manager,
            dragOffset: miniPlayerDragOffsetBinding)
    }

    private var miniPlayerDragOffsetBinding: Binding<CGFloat> {
        Binding(
            get: { miniPlayerDragPresentation.offset },
            set: { miniPlayerDragPresentation.offset = $0 }
        )
    }

    private func routePendingAppleMusicShareToHomeIfNeeded() {
        pendingAppleMusicShare = SharedStorage.pendingAppleMusicShare
        if pendingAppleMusicShare != nil {
            selectedTab = .home
        }
    }

    private func routeFromNowPlaying(_ route: PlayerDetailRoute) {
        let transition = PlayerDetailNavigationPolicy.transitionAfterNowPlayingDetailTap
        if transition.selectsHomeTab {
            selectedTab = .home
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            miniPlayerDragPresentation.offset = transition.miniPlayerDragOffset
            manager.showFullPlayer = transition.showFullPlayer
        }

        DispatchQueue.main.async {
            playerDetailPath.append(route)
        }
    }

    private func syncPlayerOrientationPolicy() {
        AppOrientationController.setPlayerLandscapeAllowed(manager.isConfigured && manager.showFullPlayer)
    }
}

/// Kept outside the app-wide tab state so the mini player's rubber-band
/// feedback stays local while the native sheet handles the full-player drag.
@Observable
private final class MiniPlayerDragPresentationState {
    var offset: CGFloat = 0
}

/// Keeps the player content tall enough to cover the native sheet's bottom
/// safe area. The player background itself expands into that area, so sizing
/// only to the sheet's content bounds leaves a visible edge at the bottom.
private struct NowPlayingSheetHost: View {
    @Bindable var manager: SonosManager
    let searchManager: SearchManager
    let navigateToDetail: (PlayerDetailRoute) -> Void

    private var presentationBackground: some View {
        SonosArtworkBackground(
            image: manager.albumArtImage,
            fallbackColor: manager.albumArtDominantColor,
            overlayOpacity: NowPlayingBackgroundPresentation.sharedArtworkOverlayOpacity
        )
        .ignoresSafeArea()
    }

    var body: some View {
        GeometryReader { proxy in
            let contentSize = NowPlayingSheetLayout.contentFrameSize(
                containerSize: proxy.size,
                bottomSafeAreaInset: proxy.safeAreaInsets.bottom
            )
            NowPlayingOverlay(
                manager: manager,
                searchManager: searchManager,
                navigateToDetail: navigateToDetail
            )
                .frame(width: contentSize.width, height: contentSize.height, alignment: .top)
                .clipped()
        }
        .ignoresSafeArea(.container, edges: .bottom)
        // Match Queue: system owns both the drag indicator and its animated
        // top-corner treatment.
        .presentationDragIndicator(.visible)
        // Paint the presentation chrome itself. A regular view background
        // stops at the sheet content bounds and leaves the system's fallback
        // color visible around the bottom safe area/corner mask.
        .presentationBackground {
            presentationBackground
        }
    }
}

nonisolated enum NowPlayingSheetLayout {
    static let backgroundCoversPresentationChrome = true
    static let bottomEdgeOverscan: CGFloat = 36

    static func contentFrameSize(
        containerSize: CGSize,
        bottomSafeAreaInset: CGFloat
    ) -> CGSize {
        let safeBottomInset = max(0, bottomSafeAreaInset)
        return CGSize(
            width: max(0, containerSize.width),
            height: max(
                0,
                containerSize.height
                    + safeBottomInset
                    + safeBottomInset
                    + bottomEdgeOverscan
            )
        )
    }
}

#Preview { ContentView() }

private enum AppTab: Hashable {
    case home
    case browse
    case localService
    case settings
}
