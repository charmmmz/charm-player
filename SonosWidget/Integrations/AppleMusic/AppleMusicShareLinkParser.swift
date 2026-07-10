import Foundation

struct AppleMusicShareLink: Equatable, Sendable {
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

enum AppleMusicShareLinkParser {
    nonisolated static func parse(_ value: String) -> AppleMusicShareLink? {
        guard let url = firstAppleMusicURL(in: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              isSupportedAppleMusicHost(url.host) else {
            return nil
        }

        if let songID = components.queryItems?
            .first(where: { $0.name.lowercased() == "i" })?
            .value
            .flatMap(numericCatalogID) {
            return AppleMusicShareLink(
                kind: .song,
                catalogID: songID,
                originalURLString: url.absoluteString)
        }

        let pathParts = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }

        guard let kindIndex = pathParts.firstIndex(where: { supportedKind(for: $0) != nil }),
              let kind = supportedKind(for: pathParts[kindIndex]),
              let rawID = pathParts.dropFirst(kindIndex + 1).last else {
            return nil
        }

        guard let catalogID = normalizedCatalogID(rawID, kind: kind) else {
            return nil
        }

        return AppleMusicShareLink(
            kind: kind,
            catalogID: catalogID,
            originalURLString: url.absoluteString)
    }

    private nonisolated static func firstAppleMusicURL(in value: String) -> URL? {
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

    private nonisolated static func sanitizedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,)]}>'\""))
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }

    private nonisolated static func isSupportedAppleMusicHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "music.apple.com" || host.hasSuffix(".music.apple.com")
    }

    private nonisolated static func supportedKind(for value: String) -> AppleMusicShareLink.Kind? {
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

    private nonisolated static func normalizedCatalogID(
        _ value: String,
        kind: AppleMusicShareLink.Kind
    ) -> String? {
        switch kind {
        case .song, .album, .artist:
            return numericCatalogID(value)
        case .playlist:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("pl.") ? trimmed : nil
        }
    }

    private nonisolated static func numericCatalogID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber) ? trimmed : nil
    }
}
