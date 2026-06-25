import Foundation

enum SharePlaybackVisualIndicator: Equatable, Sendable {
    case none
    case restingWaveform
    case playingWaveform
    case loading
    case success

    var showsSpinner: Bool {
        self == .loading
    }

    var showsWaveform: Bool {
        switch self {
        case .restingWaveform, .playingWaveform:
            return true
        case .none, .loading, .success:
            return false
        }
    }

    var animatesWaveform: Bool {
        self == .playingWaveform
    }

    var systemImageName: String? {
        switch self {
        case .none, .restingWaveform, .playingWaveform, .loading:
            return nil
        case .success:
            return "checkmark.circle.fill"
        }
    }
}
