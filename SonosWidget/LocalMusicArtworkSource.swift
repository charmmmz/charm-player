import Foundation
import MusicKit

enum LocalMusicArtworkSourceKind: Equatable, Sendable {
    case musicKit
    case remote
    case placeholder
}

enum LocalMusicArtworkSourcePolicy {
    static func preferredKind(
        hasMusicKitArtwork: Bool,
        remoteURL: URL?
    ) -> LocalMusicArtworkSourceKind {
        if hasMusicKitArtwork { return .musicKit }
        if remoteURL != nil { return .remote }
        return .placeholder
    }
}

enum LocalMusicArtworkSource {
    case musicKit(Artwork)
    case remote(URL)
    case placeholder

    var kind: LocalMusicArtworkSourceKind {
        switch self {
        case .musicKit:
            return .musicKit
        case .remote:
            return .remote
        case .placeholder:
            return .placeholder
        }
    }

    static func preferred(
        artwork: Artwork?,
        remoteURL: URL?
    ) -> LocalMusicArtworkSource {
        switch LocalMusicArtworkSourcePolicy.preferredKind(
            hasMusicKitArtwork: artwork != nil,
            remoteURL: remoteURL
        ) {
        case .musicKit:
            return artwork.map(LocalMusicArtworkSource.musicKit) ?? .placeholder
        case .remote:
            return remoteURL.map(LocalMusicArtworkSource.remote) ?? .placeholder
        case .placeholder:
            return .placeholder
        }
    }
}

enum LocalMusicDetailArtworkPresentation {
    static func contentMode(
        maximumWidth: Int?,
        maximumHeight: Int?
    ) -> LocalMusicArtworkURL.ContentMode {
        .fill
    }
}
