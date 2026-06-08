import Foundation

enum AppRoute: Equatable {
    case appleMusicShare

    nonisolated static func route(for url: URL) -> AppRoute? {
        guard url.scheme?.lowercased() == "sonoswidget" else {
            return nil
        }

        let host = url.host?.lowercased()
        let path = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        if host == "share", path == "apple-music" {
            return .appleMusicShare
        }

        return nil
    }
}

extension Notification.Name {
    static let appleMusicShareRouteReceived = Notification.Name("appleMusicShareRouteReceived")
}
