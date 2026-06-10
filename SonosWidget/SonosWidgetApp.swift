import SwiftUI
import UIKit
import BackgroundTasks
import WidgetKit
import ActivityKit

@main
struct SonosWidgetApp: App {
    @UIApplicationDelegateAdaptor(SonosWidgetAppDelegate.self) private var appDelegate

    static let bgRefreshID = "com.charm.SonosWidget.refresh"

    init() {
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithTransparentBackground()
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgRefreshID, using: nil) { task in
            // The system always hands us a `BGAppRefreshTask` for the
            // identifier we registered with — the cast is theoretically
            // infallible but `as?` lets us bail cleanly if Apple ever
            // changes that contract, instead of crashing at launch.
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleBackgroundRefresh(task: refresh)
        }

        // iOS does NOT reliably fire willTerminateNotification on force-quit,
        // so clean up any orphaned Live Activities from a previous session here.
        for activity in Activity<SonosActivityAttributes>.activities {
            SonosLog.info(.station,
                          "live_activity source=app action=end-on-launch activity=\(Self.shortLiveActivityIdentifier(activity.id))")
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    guard url.scheme == "sonoswidget" else { return }
                    if AppRoute.route(for: url) == .appleMusicShare {
                        NotificationCenter.default.post(name: .appleMusicShareRouteReceived, object: nil)
                        return
                    }
                    Task { await SonosAuth.shared.handleCallback(url: url) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    Self.scheduleBackgroundRefresh()
                }
        }
    }

    // MARK: - Background Refresh

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: bgRefreshID)
        // Ask to be woken up in ~15 minutes; system may delay but will try.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Schedule the next refresh before doing any work.
        scheduleBackgroundRefresh()

        let refreshTask = Task {
            guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else {
                task.setTaskCompleted(success: false)
                return
            }

            do {
                // Fetch current playback state from the Sonos device.
                async let transportState = SonosAPI.getTransportInfo(ip: ip)
                async let trackInfo = SonosAPI.getPositionInfo(ip: ip)

                let state = try await transportState
                let track = try await trackInfo

                let titleChanged = track.title != SharedStorage.cachedTrackTitle
                let playStateChanged = (state == .playing) != SharedStorage.isPlaying

                // Update shared storage.
                SharedStorage.isPlaying = state == .playing
                SharedStorage.cachedTrackTitle = track.title
                SharedStorage.cachedArtist = track.artist
                SharedStorage.cachedAlbum = track.album
                SharedStorage.cachedAlbumArtURL = track.albumArtURL

                if titleChanged || playStateChanged {
                    WidgetCenter.shared.reloadAllTimelines()
                }

                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            refreshTask.cancel()
        }
    }

    private static func shortLiveActivityIdentifier(_ value: String) -> String {
        guard value.count > 14 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }
}

final class SonosWidgetAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppOrientationController.supportedInterfaceOrientations
    }
}

enum AppOrientationController {
    private(set) static var supportedInterfaceOrientations: UIInterfaceOrientationMask = .portrait

    @MainActor
    static func setPlayerLandscapeAllowed(_ allowed: Bool) {
        let nextMask: UIInterfaceOrientationMask = allowed
            ? [.portrait, .landscapeLeft, .landscapeRight]
            : .portrait
        supportedInterfaceOrientations = nextMask

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState != .unattached else { continue }

            windowScene.windows.forEach {
                $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }

            if !allowed {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                    #if DEBUG
                    print("[Orientation] portrait request failed: \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }
}
