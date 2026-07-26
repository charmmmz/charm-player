import Foundation
import NowPlaying

@available(iOS 27.0, iOSApplicationExtension 27.0, *)
struct SonosRemoteMediaDeviceAttributes: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var host: String?
    var volume: Float?
}

@available(iOS 27.0, iOSApplicationExtension 27.0, *)
struct SonosRemoteMediaSessionAttributes: RemoteMediaSessionAttributes, Codable, Equatable, Sendable {
    var id: String
    /// Identifies one system media-session lifetime. APNs may reuse the same
    /// update token after playback ends, so token registration must also be
    /// scoped to this relay-generated generation.
    var sessionGeneration: String?
    var groupID: String
    var speakerName: String
    /// The visible rooms currently participating in this Sonos group.
    /// Optional so an extension update can still decode an older cached session.
    var devices: [SonosRemoteMediaDeviceAttributes]?
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var artworkURLString: String?
    var artworkFallbackURLString: String?
    /// Apple Music square motion artwork HLS master playlist. The extension
    /// materializes a local video file only when the system asks to display it.
    var animatedArtworkURLString: String?
    /// `PlaybackSource.rawValue`. Optional so an older cached session remains
    /// decodable after adding TV-specific presentation behavior.
    var playbackSourceRaw: String? = nil
    var isLiveStream: Bool
    var isPlaying: Bool
    var elapsedTime: TimeInterval
    var duration: TimeInterval
    /// Unix seconds. Keeping this as a number makes the NAS APNs payload
    /// independent of JSONEncoder's special Date reference epoch.
    var timestamp: TimeInterval
    var volume: Float
    var clientID: String
    var relayURLString: String?
    var relayCommandToken: String?
}

@available(iOS 27.0, iOSApplicationExtension 27.0, *)
extension SonosRemoteMediaSessionAttributes {
    var isTVSource: Bool {
        playbackSourceRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tv"
    }

    var usesLiveDuration: Bool {
        isTVSource || isLiveStream
    }

    var supportsPlaybackCommands: Bool {
        !isTVSource
    }

    var supportsTrackNavigation: Bool {
        supportsPlaybackCommands && !isLiveStream
    }
}
