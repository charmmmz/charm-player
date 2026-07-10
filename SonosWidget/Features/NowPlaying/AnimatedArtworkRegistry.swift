import Foundation

struct AnimatedArtworkInfo: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case url
        case metadataSearch
        case cache
    }

    var squareURLString: String?
    var tallURLString: String?
    var tallWidth: Int?
    var tallHeight: Int?
    var tallAspectRatio: Double?
    var appleMusicURLString: String?
    var artist: String?
    var album: String?
    var source: Source
    var resolvedAt: Date

    var playerURL: URL? {
        let candidates: [String?] = [squareURLString, tallURLString]
        return candidates.compactMap { value -> URL? in
            guard let value else { return nil }
            return URL(string: value)
        }.first
    }

    var fullScreenPlayerURL: URL? {
        let candidates: [String?] = [tallURLString, squareURLString]
        return candidates.compactMap { value -> URL? in
            guard let value else { return nil }
            return URL(string: value)
        }.first
    }

    var tallArtworkURL: URL? {
        guard let tallURLString else { return nil }
        return URL(string: tallURLString)
    }

    init(
        squareURLString: String?,
        tallURLString: String?,
        tallWidth: Int? = nil,
        tallHeight: Int? = nil,
        tallAspectRatio: Double? = nil,
        appleMusicURLString: String?,
        artist: String?,
        album: String?,
        source: Source,
        resolvedAt: Date
    ) {
        self.squareURLString = squareURLString
        self.tallURLString = tallURLString
        self.tallWidth = tallWidth
        self.tallHeight = tallHeight
        self.tallAspectRatio = tallAspectRatio
        self.appleMusicURLString = appleMusicURLString
        self.artist = artist
        self.album = album
        self.source = source
        self.resolvedAt = resolvedAt
    }

    init?(
        response: RelayClient.AnimatedArtworkResponse,
        fallbackAppleMusicURLString: String?,
        fallbackArtist: String?,
        fallbackAlbum: String?,
        resolvedAt: Date
    ) {
        guard response.status == .hit,
              response.bestPlayerArtworkURL != nil else {
            return nil
        }
        self.init(
            squareURLString: response.squareURLString,
            tallURLString: response.tallURLString,
            tallWidth: response.tallWidth,
            tallHeight: response.tallHeight,
            tallAspectRatio: response.tallAspectRatio,
            appleMusicURLString: response.appleMusicURLString ?? fallbackAppleMusicURLString,
            artist: response.artist ?? fallbackArtist,
            album: response.album ?? fallbackAlbum,
            source: Source(relaySource: response.source),
            resolvedAt: resolvedAt
        )
    }
}

extension AnimatedArtworkInfo.Source {
    init(relaySource: String?) {
        switch relaySource {
        case "metadata-search":
            self = .metadataSearch
        case "cache":
            self = .cache
        default:
            self = .url
        }
    }
}

@MainActor
final class AnimatedArtworkRegistry {
    static let shared = AnimatedArtworkRegistry()

    private enum LookupKey: Hashable {
        case albumURL(String)
        case catalogID(String)
        case album(artist: String, album: String)
    }

    private struct Entry {
        var info: AnimatedArtworkInfo?
        var valueKey: String
        var isAmbiguous: Bool
    }

    private var entries: [LookupKey: Entry] = [:]

    func register(_ info: AnimatedArtworkInfo) {
        guard info.playerURL != nil else { return }
        for key in lookupKeys(
            appleMusicURLString: info.appleMusicURLString,
            artist: info.artist,
            album: info.album
        ) {
            remember(info, for: key)
        }
    }

    func artwork(
        appleMusicURLString: String?,
        artist: String?,
        album: String?
    ) -> AnimatedArtworkInfo? {
        for key in lookupKeys(
            appleMusicURLString: appleMusicURLString,
            artist: artist,
            album: album
        ) {
            guard let entry = entries[key],
                  !entry.isAmbiguous,
                  let info = entry.info else {
                continue
            }
            return info
        }
        return nil
    }

    private func remember(_ info: AnimatedArtworkInfo, for key: LookupKey) {
        let valueKey = info.playerURL?.absoluteString ?? ""
        guard let existing = entries[key] else {
            entries[key] = Entry(info: info, valueKey: valueKey, isAmbiguous: false)
            return
        }

        guard existing.valueKey != valueKey else {
            entries[key] = Entry(info: info, valueKey: valueKey, isAmbiguous: false)
            return
        }
        entries[key] = Entry(info: nil, valueKey: existing.valueKey, isAmbiguous: true)
    }

    private func lookupKeys(
        appleMusicURLString: String?,
        artist: String?,
        album: String?
    ) -> [LookupKey] {
        var keys: [LookupKey] = []
        if let normalizedURL = normalizedURLString(appleMusicURLString) {
            keys.append(.albumURL(normalizedURL))
            if let catalogID = catalogID(from: normalizedURL) {
                keys.append(.catalogID(catalogID))
            }
        }
        if let artist = normalizedName(artist), let album = normalizedName(album) {
            keys.append(.album(artist: artist, album: album))
        }
        return keys
    }

    private func normalizedURLString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return url.absoluteString.lowercased()
    }

    private func catalogID(from value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        return url.pathComponents.last(where: { component in
            !component.isEmpty && component.allSatisfy(\.isNumber)
        })
    }

    private func normalizedName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
