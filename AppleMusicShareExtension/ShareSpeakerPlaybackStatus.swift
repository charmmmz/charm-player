import Foundation

enum ShareSpeakerPlaybackStatus: Equatable, Sendable {
    case playing
    case paused
    case idle

    init?(sonosTransportState rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "PLAYING":
            self = .playing
        case "PAUSED_PLAYBACK":
            self = .paused
        case "STOPPED", "NO_MEDIA_PRESENT":
            self = .idle
        default:
            return nil
        }
    }

    var displayText: String {
        switch self {
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        case .idle:
            return "Idle"
        }
    }

    static func fallbackDetailText(visibleMemberCount: Int) -> String {
        visibleMemberCount <= 1 ? "Tap to play" : "\(visibleMemberCount) speakers"
    }

    static func detailText(
        status: ShareSpeakerPlaybackStatus?,
        nowPlaying: ShareSpeakerNowPlaying?,
        visibleMemberCount: Int
    ) -> String {
        switch status {
        case .playing:
            return nowPlaying?.displayText ?? ShareSpeakerPlaybackStatus.playing.displayText
        case .paused:
            return nowPlaying?.displayText ?? ShareSpeakerPlaybackStatus.paused.displayText
        case .idle:
            return ShareSpeakerPlaybackStatus.idle.displayText
        case nil:
            return nowPlaying?.displayText ?? fallbackDetailText(visibleMemberCount: visibleMemberCount)
        }
    }
}
