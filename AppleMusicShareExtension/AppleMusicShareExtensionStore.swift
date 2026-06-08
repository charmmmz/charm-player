import Foundation

private struct PendingAppleMusicSharePayload: Codable {
    let id: UUID
    let urlString: String
    let receivedAt: Date
}

enum AppleMusicShareExtensionStore {
    private static let appGroupID = "group.com.charm.SonosWidget"
    private static let pendingShareKey = "pendingAppleMusicShare"

    enum StoreError: LocalizedError {
        case missingAppleMusicURL
        case appGroupUnavailable
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .missingAppleMusicURL:
                return "This share does not contain a supported Apple Music link."
            case .appGroupUnavailable:
                return "Charm Player could not access shared app storage."
            case .encodingFailed:
                return "Charm Player could not save this Apple Music link."
            }
        }
    }

    static func saveFirstAppleMusicURL(from value: String) throws -> String {
        guard let urlString = firstAppleMusicURLString(in: value) else {
            throw StoreError.missingAppleMusicURL
        }
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw StoreError.appGroupUnavailable
        }

        let payload = PendingAppleMusicSharePayload(
            id: UUID(),
            urlString: urlString,
            receivedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            throw StoreError.encodingFailed
        }

        defaults.set(data, forKey: pendingShareKey)
        return urlString
    }

    static func firstAppleMusicURLString(in value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directURL = sanitizedURL(from: trimmed), isAppleMusicURL(directURL) {
            return directURL.absoluteString
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for match in detector.matches(in: trimmed, range: range) {
            guard let url = match.url,
                  let sanitizedURL = sanitizedURL(from: url.absoluteString),
                  isAppleMusicURL(sanitizedURL) else {
                continue
            }
            return sanitizedURL.absoluteString
        }

        return nil
    }

    private static func sanitizedURL(from value: String) -> URL? {
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,)]}>'\""))
        return URL(string: sanitized)
    }

    private static func isAppleMusicURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "music.apple.com" || host.hasSuffix(".music.apple.com")
    }
}
