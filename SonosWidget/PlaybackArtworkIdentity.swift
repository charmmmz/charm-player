import Foundation

nonisolated enum PlaybackArtworkService: String, Codable, Sendable {
    case appleMusic
}

nonisolated enum PlaybackArtworkResolutionSource: String, Codable, Sendable {
    case existingPublic
    case persistentCache
    case registry
    case musicKitDirect
    case musicKitSearch
    case iTunesLookup
    case iTunesSearch
    case sonosCloud
}

nonisolated struct PlaybackArtworkResolution: Equatable, Sendable {
    let urlString: String
    let source: PlaybackArtworkResolutionSource

    func sizedURLString(shortSidePixels: Int) -> String {
        PlaybackArtworkImageSize.urlString(from: urlString, shortSidePixels: shortSidePixels)
    }
}

nonisolated enum PlaybackArtworkImageSize {
    static let queueThumbnailShortSidePixels = 240
    static let nowPlayingShortSidePixels = 1_200

    static func queueThumbnailURLString(from value: String) -> String {
        urlString(from: value, shortSidePixels: queueThumbnailShortSidePixels)
    }

    static func nowPlayingURLString(from value: String) -> String {
        urlString(from: value, shortSidePixels: nowPlayingShortSidePixels)
    }

    static func urlString(from value: String, shortSidePixels: Int) -> String {
        ArtworkURLNormalizer.loadableURLString(
            from: value,
            shortSidePixels: shortSidePixels
        ) ?? value
    }
}

nonisolated enum PlaybackArtworkLookupKey: Hashable, Sendable {
    case object(String)
    case track(title: String, artist: String, album: String)
    case album(artist: String, album: String)

    func storageKey(service: PlaybackArtworkService) -> String {
        switch self {
        case .object(let value):
            return "\(service.rawValue)|object|\(value)"
        case .track(let title, let artist, let album):
            return "\(service.rawValue)|track|\(title)|\(artist)|\(album)"
        case .album(let artist, let album):
            return "\(service.rawValue)|album|\(artist)|\(album)"
        }
    }
}

nonisolated struct PlaybackArtworkIdentity: Sendable {
    let objectIDs: [String]
    let title: String
    let artist: String
    let album: String

    static func metadata(
        objectIDs: [String] = [],
        title: String,
        artist: String,
        album: String
    ) -> PlaybackArtworkIdentity {
        PlaybackArtworkIdentity(
            objectIDs: unique(objectIDs.flatMap(objectIDsFromRawValue)),
            title: title,
            artist: artist,
            album: album
        )
    }

    static func browseItem(_ item: BrowseItem) -> PlaybackArtworkIdentity {
        var ids: [String] = []
        ids.append(contentsOf: objectIDsFromRawValue(item.id))
        ids.append(contentsOf: objectIDsFromRawValue(item.uri))
        ids.append(contentsOf: objectIDsFromDIDL(item.metaXML))
        return PlaybackArtworkIdentity(
            objectIDs: unique(ids),
            title: item.title,
            artist: item.artist,
            album: item.album
        )
    }

    static func queueItem(_ item: QueueItem) -> PlaybackArtworkIdentity {
        var ids: [String] = []
        ids.append(contentsOf: objectIDsFromRawValue(item.uri))
        ids.append(contentsOf: objectIDsFromDIDL(item.metaXML))
        ids.append(contentsOf: objectIDsFromArtworkURL(item.albumArtURL))
        return PlaybackArtworkIdentity(
            objectIDs: unique(ids),
            title: item.title,
            artist: item.artist,
            album: item.album
        )
    }

    static func trackInfo(_ info: TrackInfo) -> PlaybackArtworkIdentity {
        var ids: [String] = []
        ids.append(contentsOf: objectIDsFromRawValue(info.trackURI))
        ids.append(contentsOf: objectIDsFromArtworkURL(info.albumArtURL))
        return PlaybackArtworkIdentity(
            objectIDs: unique(ids),
            title: info.title,
            artist: info.artist,
            album: info.album
        )
    }

    var lookupKeys: [PlaybackArtworkLookupKey] {
        var keys: [PlaybackArtworkLookupKey] = []
        var seen = Set<PlaybackArtworkLookupKey>()

        func append(_ key: PlaybackArtworkLookupKey?) {
            guard let key, seen.insert(key).inserted else { return }
            keys.append(key)
        }

        for objectID in objectIDs {
            append(.object(objectID))
        }
        append(Self.trackKey(title: title, artist: artist, album: album))
        append(Self.albumKey(artist: artist, album: album))
        return keys
    }

    private static func objectIDsFromDIDL(_ xml: String?) -> [String] {
        guard let xml, !xml.isEmpty else { return [] }
        var ids: [String] = []

        if let itemID = firstXMLAttribute(named: "id", in: xml) {
            ids.append(contentsOf: objectIDsFromRawValue(itemID))
        }
        if let resource = SonosAPI.extractTag("res", from: xml) {
            ids.append(contentsOf: objectIDsFromRawValue(resource))
        }
        return unique(ids)
    }

    private static func objectIDsFromArtworkURL(_ value: String?) -> [String] {
        guard let value,
              QueueArtPrefetchPolicy.isLocalSonosArtworkURL(value),
              let url = URL(string: value) else {
            return []
        }
        var ids: [String] = []
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let objectValue = components.queryItems?.first(where: { $0.name == "u" })?.value {
            ids.append(contentsOf: objectIDsFromRawValue(objectValue))
        }
        return unique(ids)
    }

    private static func objectIDsFromRawValue(_ value: String?) -> [String] {
        guard let value else { return [] }
        var rawValues = [value]
        if let decoded = value.removingPercentEncoding, decoded != value {
            rawValues.append(decoded)
            if let decodedAgain = decoded.removingPercentEncoding, decodedAgain != decoded {
                rawValues.append(decodedAgain)
            }
        }

        var ids: [String] = []
        for raw in rawValues {
            let cleaned = cleanedObjectID(raw)
            guard !cleaned.isEmpty else { continue }
            ids.append(cleaned)
            if cleaned.hasPrefix("track:") {
                ids.append(String(cleaned.dropFirst("track:".count)))
            }
            if cleaned.hasPrefix("librarytrack:") {
                ids.append(String(cleaned.dropFirst("librarytrack:".count)))
            }
        }
        return unique(ids)
    }

    private static func cleanedObjectID(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return "" }
        if QueueArtPrefetchPolicy.isLocalSonosArtworkURL(candidate) {
            return ""
        }

        if let queryIndex = candidate.firstIndex(of: "?") {
            candidate = String(candidate[..<queryIndex])
        }
        for prefix in [
            "x-sonos-http:",
            "x-sonosapi-radio:",
            "x-sonosapi-stream:",
            "x-sonosapi-hls:",
            "x-rincon-cpcontainer:"
        ] where candidate.localizedCaseInsensitiveContains(prefix) {
            if let range = candidate.range(of: prefix, options: .caseInsensitive) {
                candidate = String(candidate[range.upperBound...])
            }
        }

        for suffix in [".mp4", ".m4a", ".aac", ".flac", ".mp3"] where candidate.lowercased().hasSuffix(suffix) {
            candidate.removeLast(suffix.count)
            break
        }

        if candidate.hasPrefix("1006206c") {
            candidate.removeFirst("1006206c".count)
        } else if candidate.hasPrefix("1004206c") {
            candidate.removeFirst("1004206c".count)
        }

        let normalized = candidate
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        if normalized.hasPrefix("q:") {
            return ""
        }
        return normalized
    }

    private static func firstXMLAttribute(named name: String, in xml: String) -> String? {
        let pattern = #"<(?:item|container)\s+[^>]*\#(name)="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private static func trackKey(title: String, artist: String, album: String) -> PlaybackArtworkLookupKey? {
        guard let title = normalizedText(title),
              let artist = normalizedText(artist),
              let album = normalizedText(album) else {
            return nil
        }
        return .track(title: title, artist: artist, album: album)
    }

    private static func albumKey(artist: String, album: String) -> PlaybackArtworkLookupKey? {
        guard let artist = normalizedText(artist),
              let album = normalizedText(album) else {
            return nil
        }
        return .album(artist: artist, album: album)
    }

    private static func normalizedText(_ value: String) -> String? {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !value.isEmpty, seen.insert(value).inserted else { return false }
            return true
        }
    }
}
