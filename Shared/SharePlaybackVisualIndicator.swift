import Foundation

enum SharePlaybackVisualIndicator: Equatable, Sendable {
    case none
    case play
    case loading
    case success

    var showsSpinner: Bool {
        self == .loading
    }

    var systemImageName: String? {
        switch self {
        case .none, .loading:
            return nil
        case .play:
            return "play.fill"
        case .success:
            return "checkmark.circle.fill"
        }
    }
}
