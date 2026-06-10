import SwiftUI
import UIKit

struct ContentView: View {
    @State var manager = SonosManager()
    @State var searchManager = SearchManager()
    @State private var selectedTab: AppTab = .home
    @State private var pendingAppleMusicShare: PendingAppleMusicShare?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "play.circle.fill", value: AppTab.home) {
                PlayerView(
                    manager: manager,
                    searchManager: searchManager,
                    pendingAppleMusicShare: $pendingAppleMusicShare)
                    .miniPlayerLegacyInsetIfNeeded(manager: manager)
            }
            Tab("Browse", systemImage: "magnifyingglass", value: AppTab.browse) {
                SearchView(manager: manager, searchManager: searchManager)
                    .miniPlayerLegacyInsetIfNeeded(manager: manager)
            }
            Tab("Local Service", systemImage: "music.note.house", value: AppTab.localService) {
                LocalLibraryView(manager: manager, searchManager: searchManager)
                    .miniPlayerLegacyInsetIfNeeded(manager: manager)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(manager: manager, searchManager: searchManager)
                    .miniPlayerLegacyInsetIfNeeded(manager: manager)
            }
        }
        .tint(manager.albumArtDominantColor ?? .blue)
        .tabBarMinimizeOnScrollIfAvailable()
        .miniPlayerSystemAccessoryIfAvailable(manager: manager)
        // Bound to the shared `manager.showingAddSpeaker` flag so either the
        // first-run setup screen or the Settings tab can flip it from any tab.
        .sheet(isPresented: $manager.showingAddSpeaker) {
            AddSpeakerSheet(manager: manager)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: manager.showFullPlayer)
        .overlay {
            GeometryReader { geo in
                let screenH = geo.size.height + geo.safeAreaInsets.bottom
                let overlayY: CGFloat = {
                    if manager.showFullPlayer {
                        return 0
                    } else {
                        let draggedIn = -manager.miniPlayerDragOffset * (1.0 / 0.55)
                        return max(0, screenH - draggedIn)
                    }
                }()

                if manager.isConfigured {
                    NowPlayingOverlay(manager: manager, searchManager: searchManager)
                        .offset(y: overlayY)
                        .allowsHitTesting(manager.showFullPlayer || manager.miniPlayerDragOffset < -5)
                }
            }
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            routePendingAppleMusicShareToHomeIfNeeded()
            syncPlayerOrientationPolicy()
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

    private func routePendingAppleMusicShareToHomeIfNeeded() {
        pendingAppleMusicShare = SharedStorage.pendingAppleMusicShare
        if pendingAppleMusicShare != nil {
            selectedTab = .home
        }
    }

    private func syncPlayerOrientationPolicy() {
        AppOrientationController.setPlayerLandscapeAllowed(manager.isConfigured && manager.showFullPlayer)
    }
}

#Preview { ContentView() }

private enum AppTab: Hashable {
    case home
    case browse
    case localService
    case settings
}
