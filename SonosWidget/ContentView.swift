import SwiftUI
import UIKit

struct ContentView: View {
    @State var manager = SonosManager()
    @State var searchManager = SearchManager()
    @State private var selectedTab: AppTab = .home
    @State private var pendingAppleMusicShare: PendingAppleMusicShare?
    @State private var playerDetailPath: [PlayerDetailRoute] = []
    @State private var fullPlayerDismissDragOffset: CGFloat = 0
    @State private var fullPlayerDismissDragResetTask: Task<Void, Never>?

    var body: some View {
        mainTabs
        // Bound to the shared `manager.showingAddSpeaker` flag so either the
        // first-run setup screen or the Settings tab can flip it from any tab.
        .sheet(isPresented: $manager.showingAddSpeaker) {
            AddSpeakerSheet(manager: manager)
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
            if manager.showFullPlayer {
                resetFullPlayerDismissDragImmediately()
            }
        }
        .onDisappear {
            fullPlayerDismissDragResetTask?.cancel()
            fullPlayerDismissDragResetTask = nil
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
                    .miniPlayerTabContentInset(manager: manager)
            }
            Tab("Browse", systemImage: "magnifyingglass", value: AppTab.browse) {
                SearchView(manager: manager, searchManager: searchManager)
                    .miniPlayerTabContentInset(manager: manager)
            }
            Tab("Local Service", systemImage: "music.note.house", value: AppTab.localService) {
                LocalLibraryView(manager: manager, searchManager: searchManager)
                    .miniPlayerTabContentInset(manager: manager)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(manager: manager, searchManager: searchManager)
                    .miniPlayerTabContentInset(manager: manager)
            }
        }
        .environment(\.isAnimatedArtworkPlaybackSuspended, manager.showFullPlayer)
        .tint(manager.albumArtDominantColor ?? .blue)
        .tabBarMinimizeOnScrollIfAvailable()
        .miniPlayerSystemAccessoryIfAvailable(manager: manager)
        .overlay {
            nowPlayingOverlayHost
        }
    }

    private var nowPlayingOverlayHost: some View {
        GeometryReader { geo in
            let cardSize = NowPlayingOverlayHostPresentation.cardSize(
                containerSize: geo.size,
                bottomSafeAreaInset: geo.safeAreaInsets.bottom
            )
            let screenH = cardSize.height
            let overlayY = NowPlayingOverlayHostPresentation.overlayOffset(
                screenHeight: screenH,
                miniPlayerDragOffset: manager.miniPlayerDragOffset,
                isFullPlayerVisible: manager.showFullPlayer,
                dismissDragOffset: fullPlayerDismissDragOffset
            )
            if manager.isConfigured {
                NowPlayingOverlay(
                    manager: manager,
                    searchManager: searchManager,
                    navigateToDetail: routeFromNowPlaying
                )
                    .frame(width: cardSize.width, height: cardSize.height)
                    .offset(y: overlayY)
                    .contentShape(Rectangle())
                    .simultaneousGesture(fullPlayerDismissDragGesture())
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: manager.showFullPlayer)
                    .allowsHitTesting(manager.showFullPlayer || manager.miniPlayerDragOffset < -5)
            }
        }
        .ignoresSafeArea(
            .container,
            edges: NowPlayingOverlayHostPresentation.ignoredSafeAreaEdges(
                isFullPlayerVisible: manager.showFullPlayer
            )
        )
    }

    private func routePendingAppleMusicShareToHomeIfNeeded() {
        pendingAppleMusicShare = SharedStorage.pendingAppleMusicShare
        if pendingAppleMusicShare != nil {
            selectedTab = .home
        }
    }

    private func updateFullPlayerDismissDragOffset(_ offset: CGFloat) {
        fullPlayerDismissDragResetTask?.cancel()
        fullPlayerDismissDragResetTask = nil

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            fullPlayerDismissDragOffset = max(0, offset)
        }
    }

    private func fullPlayerDismissDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard manager.showFullPlayer else { return }
                updateFullPlayerDismissDragOffset(max(0, value.translation.height))
            }
            .onEnded { value in
                guard manager.showFullPlayer else { return }
                finishFullPlayerDismissDrag(
                    translationHeight: value.translation.height,
                    predictedEndTranslationHeight: value.predictedEndTranslation.height
                )
            }
    }

    private func finishFullPlayerDismissDrag(
        translationHeight: CGFloat,
        predictedEndTranslationHeight: CGFloat
    ) {
        if NowPlayingOverlayPresentation.shouldDismissFromDrag(
            translationHeight: translationHeight,
            predictedEndTranslationHeight: predictedEndTranslationHeight
        ) {
            fullPlayerDismissDragOffset = max(0, translationHeight)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                manager.showFullPlayer = false
            }
            scheduleFullPlayerDismissDragReset()
        } else {
            withAnimation(.spring(response: 0.3)) {
                fullPlayerDismissDragOffset = 0
            }
        }
    }

    private func scheduleFullPlayerDismissDragReset() {
        fullPlayerDismissDragResetTask?.cancel()
        fullPlayerDismissDragResetTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: NowPlayingOverlayPresentation.dragDismissalResetDelayNanoseconds
            )
            guard !Task.isCancelled, !manager.showFullPlayer else { return }
            resetFullPlayerDismissDragImmediately()
        }
    }

    private func resetFullPlayerDismissDragImmediately() {
        fullPlayerDismissDragResetTask?.cancel()
        fullPlayerDismissDragResetTask = nil
        fullPlayerDismissDragOffset = 0
    }

    private func routeFromNowPlaying(_ route: PlayerDetailRoute) {
        let transition = PlayerDetailNavigationPolicy.transitionAfterNowPlayingDetailTap
        if transition.selectsHomeTab {
            selectedTab = .home
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            manager.miniPlayerDragOffset = transition.miniPlayerDragOffset
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

nonisolated enum NowPlayingOverlayHostPresentation {
    enum SafeAreaExpansionTarget {
        case hostGeometry
    }
    enum MountTarget: Equatable {
        case tabViewOverlay
    }
    enum DismissGestureAttachment: Equatable {
        case rootCard
    }
    enum ClipOwner: Equatable {
        case none
        case rootCard
    }
    enum DismissTransition: Equatable {
        case slideOnly
    }
    enum RootCardCompositingMode: Equatable {
        case unclipped
        case compositingGroup
        case directClip
    }

    static let safeAreaExpansionTarget: SafeAreaExpansionTarget = .hostGeometry
    static let mountTarget: MountTarget = .tabViewOverlay
    static let dismissGestureAttachment: DismissGestureAttachment = .rootCard
    static let clipOwner: ClipOwner = .none
    static let dismissTransition: DismissTransition = .slideOnly
    static let rootCardCompositingMode: RootCardCompositingMode = .unclipped
    static let bottomEdgeOverscan: CGFloat = 36

    static func cardSize(
        containerSize: CGSize,
        bottomSafeAreaInset: CGFloat
    ) -> CGSize {
        let safeBottomInset = max(0, bottomSafeAreaInset)
        let expandedHeight = max(0, containerSize.height)
            + safeBottomInset
            + safeBottomInset
        let bottomOverscan = expandedHeight > 0 ? bottomEdgeOverscan : 0

        return CGSize(
            width: max(0, containerSize.width),
            height: expandedHeight + bottomOverscan
        )
    }

    static func overlayOffset(
        screenHeight: CGFloat,
        miniPlayerDragOffset: CGFloat,
        isFullPlayerVisible: Bool,
        dismissDragOffset: CGFloat
    ) -> CGFloat {
        let baseOffset: CGFloat
        if isFullPlayerVisible {
            baseOffset = 0
        } else {
            let draggedIn = -miniPlayerDragOffset * (1.0 / 0.55)
            baseOffset = max(0, max(0, screenHeight) - draggedIn)
        }
        return baseOffset + max(0, dismissDragOffset)
    }

    static func ignoredSafeAreaEdges(isFullPlayerVisible: Bool) -> Edge.Set {
        isFullPlayerVisible ? [.horizontal, .bottom] : .horizontal
    }
}

#Preview { ContentView() }

private enum AppTab: Hashable {
    case home
    case browse
    case localService
    case settings
}
