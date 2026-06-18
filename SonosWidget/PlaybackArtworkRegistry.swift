import Foundation

@MainActor
final class PlaybackArtworkRegistry {
    static let shared = PlaybackArtworkRegistry()

    private enum LookupKey: Hashable {
        case object(String)
        case track(title: String, artist: String, album: String)
        case album(artist: String, album: String)
    }

    private struct Entry {
        var urlString: String?
        var cacheKey: String
        var isAmbiguous: Bool
    }

    private var entries: [LookupKey: Entry] = [:]

    func register(items: [BrowseItem]) {
        for item in items {
            register(item)
        }
    }

    func register(_ item: BrowseItem) {
        guard let urlString = canonicalArtworkURLString(for: item) else { return }

        for key in lookupKeys(for: item) {
            remember(urlString, for: key)
        }
    }

    func resolvedQueueItems(_ items: [QueueItem]) -> (items: [QueueItem], replacementCount: Int) {
        var replacementCount = 0
        let resolved = items.map { item in
            let next = resolvedQueueItem(item)
            if next.albumArtURL != item.albumArtURL {
                replacementCount += 1
            }
            return next
        }
        return (resolved, replacementCount)
    }

    func resolvedQueueItem(_ item: QueueItem) -> QueueItem {
        guard shouldReplaceArtworkURL(item.albumArtURL),
              let replacement = artworkURLString(for: item) else {
            return item
        }

        var resolved = item
        resolved.albumArtURL = replacement
        return resolved
    }

    private func artworkURLString(for item: QueueItem) -> String? {
        for key in lookupKeys(for: item) {
            guard let entry = entries[key],
                  !entry.isAmbiguous,
                  let urlString = entry.urlString else {
                continue
            }
            return urlString
        }
        return nil
    }

    private func remember(_ urlString: String, for key: LookupKey) {
        let cacheKey = ArtworkURLNormalizer.artworkCacheKey(from: urlString) ?? urlString
        guard let existing = entries[key] else {
            entries[key] = Entry(urlString: urlString, cacheKey: cacheKey, isAmbiguous: false)
            return
        }

        guard existing.cacheKey != cacheKey else { return }
        entries[key] = Entry(urlString: nil, cacheKey: existing.cacheKey, isAmbiguous: true)
    }

    private func canonicalArtworkURLString(for item: BrowseItem) -> String? {
        let candidates = [item.thumbnailArtworkURL, item.preferredDetailArtworkURL]
        for candidate in candidates {
            guard let normalized = ArtworkURLNormalizer.loadableURLString(
                from: candidate,
                preserveExistingAppleArtworkSize: true
            ),
                  !QueueArtPrefetchPolicy.isLocalSonosArtworkURL(normalized) else {
                continue
            }
            return normalized
        }
        return nil
    }

    private func shouldReplaceArtworkURL(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        return QueueArtPrefetchPolicy.isLocalSonosArtworkURL(trimmed)
    }

    private func lookupKeys(for item: BrowseItem) -> [LookupKey] {
        var keys: [LookupKey] = []
        var seen = Set<LookupKey>()

        func append(_ key: LookupKey?) {
            guard let key, seen.insert(key).inserted else { return }
            keys.append(key)
        }

        for objectID in objectIDs(from: item.id) {
            append(.object(objectID))
        }
        for objectID in objectIDs(from: item.uri) {
            append(.object(objectID))
        }
        for objectID in objectIDs(fromDIDL: item.metaXML) {
            append(.object(objectID))
        }
        append(trackKey(title: item.title, artist: item.artist, album: item.album))
        append(albumKey(artist: item.artist, album: item.album))
        return keys
    }

    private func lookupKeys(for item: QueueItem) -> [LookupKey] {
        var keys: [LookupKey] = []
        var seen = Set<LookupKey>()

        func append(_ key: LookupKey?) {
            guard let key, seen.insert(key).inserted else { return }
            keys.append(key)
        }

        for objectID in objectIDs(from: item.uri) {
            append(.object(objectID))
        }
        for objectID in objectIDs(fromDIDL: item.metaXML) {
            append(.object(objectID))
        }
        for objectID in objectIDs(fromArtworkURL: item.albumArtURL) {
            append(.object(objectID))
        }
        append(trackKey(title: item.title, artist: item.artist, album: item.album))
        append(albumKey(artist: item.artist, album: item.album))
        return keys
    }

    private func trackKey(title: String, artist: String, album: String) -> LookupKey? {
        guard let title = normalizedText(title),
              let artist = normalizedText(artist),
              let album = normalizedText(album) else {
            return nil
        }
        return .track(title: title, artist: artist, album: album)
    }

    private func albumKey(artist: String, album: String) -> LookupKey? {
        guard let artist = normalizedText(artist),
              let album = normalizedText(album) else {
            return nil
        }
        return .album(artist: artist, album: album)
    }

    private func normalizedText(_ value: String) -> String? {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private func objectIDs(fromDIDL xml: String?) -> [String] {
        guard let xml, !xml.isEmpty else { return [] }
        var ids: [String] = []

        if let itemID = firstXMLAttribute(named: "id", in: xml) {
            ids.append(contentsOf: objectIDs(from: itemID))
        }
        if let resource = SonosAPI.extractTag("res", from: xml) {
            ids.append(contentsOf: objectIDs(from: resource))
        }
        return unique(ids)
    }

    private func objectIDs(fromArtworkURL value: String?) -> [String] {
        guard let value, let url = URL(string: value) else { return [] }
        var ids = objectIDs(from: value)
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let objectValue = components.queryItems?.first(where: { $0.name == "u" })?.value {
            ids.append(contentsOf: objectIDs(from: objectValue))
        }
        return unique(ids)
    }

    private func objectIDs(from value: String?) -> [String] {
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

    private func cleanedObjectID(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return "" }

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

        return candidate
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private func firstXMLAttribute(named name: String, in xml: String) -> String? {
        let pattern = #"<(?:item|container)\s+[^>]*\#(name)="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !value.isEmpty, seen.insert(value).inserted else { return false }
            return true
        }
    }
}
