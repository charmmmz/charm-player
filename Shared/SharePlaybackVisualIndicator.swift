import Foundation
import CoreGraphics

enum ShareStatusIndicatorLayout {
    static let indicatorSlotSize = CGSize(width: 24, height: 24)
    static let rowMinimumHeight: CGFloat = 28
}

enum SharePlaybackWaveformLayout {
    static let size = CGSize(width: 24, height: 24)
    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 2
    static let restingHeights: [CGFloat] = [5, 8, 6, 9, 5]
    static let activeHeights: [CGFloat] = [10, 18, 13, 20, 9]
}

enum ShareSpeakerListLayout {
    static let cardHeight: CGFloat = 82
    static let cardSpacing: CGFloat = 10
    static let defaultPreferredContentHeight: CGFloat = 560
    static let nonListPreferredContentHeight: CGFloat = 156

    static func listHeight(for cardCount: Int) -> CGFloat {
        guard cardCount > 0 else { return 0 }
        return cardHeight * CGFloat(cardCount)
            + cardSpacing * CGFloat(cardCount - 1)
    }

    static func preferredContentHeight(for cardCount: Int) -> CGFloat {
        guard cardCount > 0 else { return defaultPreferredContentHeight }
        return max(
            defaultPreferredContentHeight,
            nonListPreferredContentHeight + listHeight(for: cardCount)
        )
    }
}

enum SharePlaybackVisualIndicator: Equatable, Sendable {
    case none
    case speakerSelection
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
        case .none, .speakerSelection, .loading, .success:
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
        case .speakerSelection:
            return "hifispeaker.2.fill"
        case .success:
            return "checkmark.circle.fill"
        }
    }
}
