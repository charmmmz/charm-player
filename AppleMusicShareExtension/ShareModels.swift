import Foundation

struct ShareAppleMusicLink: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case song
        case album
        case playlist
        case artist
    }

    let kind: Kind
    let catalogID: String
    let originalURLString: String
}

enum ShareAppleMusicLinkParser {
    static func parse(_ value: String) -> ShareAppleMusicLink? {
        guard let url = firstAppleMusicURL(in: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              isSupportedAppleMusicHost(url.host) else {
            return nil
        }

        if let songID = components.queryItems?
            .first(where: { $0.name.lowercased() == "i" })?
            .value
            .flatMap(numericCatalogID) {
            return ShareAppleMusicLink(
                kind: .song,
                catalogID: songID,
                originalURLString: url.absoluteString)
        }

        let pathParts = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }

        guard let kindIndex = pathParts.firstIndex(where: { supportedKind(for: $0) != nil }),
              let kind = supportedKind(for: pathParts[kindIndex]),
              let rawID = pathParts.dropFirst(kindIndex + 1).last,
              let catalogID = normalizedCatalogID(rawID, kind: kind) else {
            return nil
        }

        return ShareAppleMusicLink(
            kind: kind,
            catalogID: catalogID,
            originalURLString: url.absoluteString)
    }

    private static func firstAppleMusicURL(in value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = sanitizedURL(from: trimmed),
           isSupportedAppleMusicHost(direct.host) {
            return direct
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for match in detector.matches(in: trimmed, range: range) {
            guard let url = match.url,
                  let sanitized = sanitizedURL(from: url.absoluteString),
                  isSupportedAppleMusicHost(sanitized.host) else {
                continue
            }
            return sanitized
        }
        return nil
    }

    private static func sanitizedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,)]}>'\""))
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }

    private static func isSupportedAppleMusicHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "music.apple.com" || host.hasSuffix(".music.apple.com")
    }

    private static func supportedKind(for value: String) -> ShareAppleMusicLink.Kind? {
        switch value.lowercased() {
        case "song":
            return .song
        case "album":
            return .album
        case "playlist":
            return .playlist
        case "artist":
            return .artist
        default:
            return nil
        }
    }

    private static func normalizedCatalogID(
        _ value: String,
        kind: ShareAppleMusicLink.Kind
    ) -> String? {
        switch kind {
        case .song, .album, .artist:
            return numericCatalogID(value)
        case .playlist:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("pl.") ? trimmed : nil
        }
    }

    private static func numericCatalogID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber) ? trimmed : nil
    }
}

struct ShareAppleMusicPlayable: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case song
        case album
        case playlist
        case artist

        var cloudType: String {
            switch self {
            case .song: return "TRACK"
            case .album: return "ALBUM"
            case .playlist: return "PLAYLIST"
            case .artist: return "ARTIST"
            }
        }
    }

    let kind: Kind
    let catalogID: String
    let title: String
    let artist: String
    let album: String
    let artworkURLString: String?
    let duration: TimeInterval?

    var sonosObjectID: String {
        switch kind {
        case .song:
            return "song:\(catalogID)"
        case .album:
            return "album:\(catalogID)"
        case .playlist:
            return "playlist:\(catalogID)"
        case .artist:
            return "artist:\(catalogID)"
        }
    }

    var cloudType: String { kind.cloudType }
    var sonosMimeType: String? { kind == .song ? "audio/mp4" : nil }

    static func placeholder(from link: ShareAppleMusicLink) -> ShareAppleMusicPlayable {
        let kind: Kind
        let title: String
        switch link.kind {
        case .song:
            kind = .song
            title = "Apple Music Song"
        case .album:
            kind = .album
            title = "Apple Music Album"
        case .playlist:
            kind = .playlist
            title = "Apple Music Playlist"
        case .artist:
            kind = .artist
            title = "Apple Music Artist"
        }

        return ShareAppleMusicPlayable(
            kind: kind,
            catalogID: link.catalogID,
            title: title,
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil)
    }
}

struct ShareAppleMusicSonosCredential: Codable, Equatable, Sendable {
    let cloudServiceId: String
    let localServiceId: Int
    let accountId: String
    let username: String?
    let displayName: String
}

struct ShareSpeaker: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var ipAddress: String
    var isCoordinator: Bool
    var groupId: String?
    var coordinatorIP: String?
    var isInvisible: Bool = false

    var playbackIP: String { coordinatorIP ?? ipAddress }

    init(
        id: String,
        name: String,
        ipAddress: String,
        isCoordinator: Bool,
        groupId: String? = nil,
        coordinatorIP: String? = nil,
        isInvisible: Bool = false
    ) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.isCoordinator = isCoordinator
        self.groupId = groupId
        self.coordinatorIP = coordinatorIP
        self.isInvisible = isInvisible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        ipAddress = try container.decode(String.self, forKey: .ipAddress)
        isCoordinator = try container.decode(Bool.self, forKey: .isCoordinator)
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
        coordinatorIP = try container.decodeIfPresent(String.self, forKey: .coordinatorIP)
        isInvisible = try container.decodeIfPresent(Bool.self, forKey: .isInvisible) ?? false
    }
}

struct ShareSpeakerGroup: Equatable, Identifiable, Sendable {
    let id: String
    let coordinator: ShareSpeaker
    let members: [ShareSpeaker]

    var displayName: String {
        let visibleMembers = members
            .filter { !$0.isInvisible }
            .sorted { left, _ in left.id == coordinator.id }
            .map(\.name)
        return visibleMembers.isEmpty ? coordinator.name : visibleMembers.joined(separator: " + ")
    }

    var detailText: String {
        let count = members.filter { !$0.isInvisible }.count
        return count <= 1 ? "Ready" : "\(count) speakers"
    }
}

enum SharePlaybackError: LocalizedError {
    case missingAppleMusicLink
    case noSpeakers
    case missingCredential
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAppleMusicLink:
            return "This share does not contain a supported Apple Music link."
        case .noSpeakers:
            return "No saved Sonos speaker was found. Open Charm Player once on this Wi-Fi."
        case .missingCredential:
            return "Open Charm Player once and visit Browse so Apple Music can sync with Sonos."
        case .playbackFailed(let message):
            return message
        }
    }
}
