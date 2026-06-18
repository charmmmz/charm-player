import Foundation
import MusicKit

enum LocalServiceSonosPlaybackError: LocalizedError, Equatable {
    case noPlayableCatalogID
    case appleMusicAccountMissing
    case localServiceMappingMissing
    case playbackFailed(String?)

    var errorDescription: String? {
        switch self {
        case .noPlayableCatalogID:
            return "This Apple Music item could not be matched to a Sonos-playable Apple Music resource."
        case .appleMusicAccountMissing:
            return "Apple Music is not linked to this Sonos household."
        case .localServiceMappingMissing:
            return "Sonos has not exposed the local Apple Music service mapping yet. Try again on the same network as your speaker."
        case .playbackFailed(let message):
            return message ?? "Sonos could not start this Apple Music item."
        }
    }
}

struct LocalServiceAppleMusicPlayable: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case song
        case album
        case artist
        case playlist
        case station

        var cloudType: String {
            switch self {
            case .song: return "TRACK"
            case .album: return "ALBUM"
            case .artist: return "ARTIST"
            case .playlist: return "PLAYLIST"
            case .station: return "PROGRAM"
            }
        }

        var isContainer: Bool {
            switch self {
            case .album, .playlist: return true
            case .song, .artist, .station: return false
            }
        }
    }

    enum StationPlaybackKind: Equatable, Sendable {
        case tracks
        case stream
    }

    let kind: Kind
    let catalogID: String
    let title: String
    let artist: String
    let album: String
    let artworkURLString: String?
    let duration: TimeInterval?
    let stationPlaybackKind: StationPlaybackKind?
    let stationStreamObjectID: String?

    init(
        kind: Kind,
        catalogID: String,
        title: String,
        artist: String,
        album: String,
        artworkURLString: String?,
        duration: TimeInterval?,
        stationPlaybackKind: StationPlaybackKind? = nil,
        stationStreamObjectID: String? = nil
    ) {
        self.kind = kind
        self.catalogID = catalogID
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURLString = artworkURLString
        self.duration = duration
        self.stationPlaybackKind = stationPlaybackKind
        self.stationStreamObjectID = stationStreamObjectID
    }

    var id: String { "\(kind.cloudType)-\(catalogID)" }
    var cloudType: String { kind.cloudType }
    var isContainer: Bool { kind.isContainer }

    func withFallbackArtworkURLString(_ fallbackURLString: String?) -> LocalServiceAppleMusicPlayable {
        guard artworkURLString == nil,
              let fallbackURLString = Self.normalizedArtworkURLString(fallbackURLString) else {
            return self
        }
        return LocalServiceAppleMusicPlayable(
            kind: kind,
            catalogID: catalogID,
            title: title,
            artist: artist,
            album: album,
            artworkURLString: fallbackURLString,
            duration: duration,
            stationPlaybackKind: stationPlaybackKind,
            stationStreamObjectID: stationStreamObjectID
        )
    }

    func withPreferredArtworkURLString(_ preferredURLString: String?) -> LocalServiceAppleMusicPlayable {
        guard let preferredURLString = Self.normalizedPreferredArtworkURLString(preferredURLString),
              preferredURLString != artworkURLString else {
            return self
        }
        return LocalServiceAppleMusicPlayable(
            kind: kind,
            catalogID: catalogID,
            title: title,
            artist: artist,
            album: album,
            artworkURLString: preferredURLString,
            duration: duration,
            stationPlaybackKind: stationPlaybackKind,
            stationStreamObjectID: stationStreamObjectID
        )
    }

    var sonosObjectID: String {
        switch kind {
        case .song, .album, .artist, .playlist, .station:
            return catalogID
        }
    }

    var sonosMimeType: String? {
        kind == .song ? "audio/mp4" : nil
    }

    static func make(
        kind: Kind,
        rawID: String,
        playParameterCandidates: [String],
        title: String,
        artist: String,
        album: String,
        artworkURLString: String?,
        duration: TimeInterval?
    ) -> LocalServiceAppleMusicPlayable? {
        let candidates = playParameterCandidates + [rawID]
        guard let catalogID = firstCatalogID(in: candidates, kind: kind) else {
            return nil
        }

        let normalizedArtworkURLString = normalizedArtworkURLString(artworkURLString)

        if kind == .station {
            let playbackKind = detectedStationPlaybackKind(in: candidates)
            let streamObjectID = playbackKind == .stream
                ? stationStreamObjectID(in: candidates)
                : nil
            return LocalServiceAppleMusicPlayable(
                kind: kind,
                catalogID: catalogID,
                title: title,
                artist: artist,
                album: album,
                artworkURLString: normalizedArtworkURLString,
                duration: duration,
                stationPlaybackKind: playbackKind,
                stationStreamObjectID: streamObjectID
            )
        }

        return LocalServiceAppleMusicPlayable(
            kind: kind,
            catalogID: catalogID,
            title: title,
            artist: artist,
            album: album,
            artworkURLString: normalizedArtworkURLString,
            duration: duration
        )
    }

    static func make(song: Song) -> LocalServiceAppleMusicPlayable? {
        make(
            kind: .song,
            rawID: song.id.rawValue,
            playParameterCandidates: playParameterCandidates(from: song.playParameters),
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            artworkURLString: artworkURLString(song.artwork),
            duration: song.duration
        )
    }

    static func make(track: Track) -> LocalServiceAppleMusicPlayable? {
        guard case .song = track else { return nil }
        return make(
            kind: .song,
            rawID: track.id.rawValue,
            playParameterCandidates: playParameterCandidates(from: track.playParameters),
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle ?? "",
            artworkURLString: artworkURLString(track.artwork),
            duration: track.duration
        )
    }

    static func make(album: Album) -> LocalServiceAppleMusicPlayable? {
        make(
            kind: .album,
            rawID: album.id.rawValue,
            playParameterCandidates: playParameterCandidates(from: album.playParameters),
            title: album.title,
            artist: album.artistName,
            album: album.title,
            artworkURLString: artworkURLString(album.artwork),
            duration: nil
        )
    }

    static func make(artist: Artist) -> LocalServiceAppleMusicPlayable? {
        make(
            kind: .artist,
            rawID: artist.id.rawValue,
            playParameterCandidates: [],
            title: artist.name,
            artist: "",
            album: "",
            artworkURLString: artworkURLString(artist.artwork),
            duration: nil
        )
    }

    static func make(playlist: Playlist) -> LocalServiceAppleMusicPlayable? {
        make(
            kind: .playlist,
            rawID: playlist.id.rawValue,
            playParameterCandidates: playParameterCandidates(from: playlist.playParameters),
            title: playlist.name,
            artist: playlist.curatorName ?? "",
            album: "",
            artworkURLString: artworkURLString(playlist.artwork),
            duration: nil
        )
    }

    static func make(station: Station) -> LocalServiceAppleMusicPlayable? {
        make(
            kind: .station,
            rawID: station.id.rawValue,
            playParameterCandidates: playParameterCandidates(from: station.playParameters),
            title: station.name,
            artist: "",
            album: "",
            artworkURLString: artworkURLString(station.artwork),
            duration: nil
        )
    }

    static func make(catalogItem: AppleMusicCatalogSearchItem) -> LocalServiceAppleMusicPlayable? {
        let kind: Kind
        switch catalogItem.type {
        case .song:
            kind = .song
        case .album:
            kind = .album
        case .artist:
            kind = .artist
        case .playlist:
            kind = .playlist
        }

        return make(
            kind: kind,
            rawID: catalogItem.id,
            playParameterCandidates: [catalogItem.sonosPlayableObjectID, catalogItem.id],
            title: catalogItem.title,
            artist: catalogItem.artist,
            album: catalogItem.album,
            artworkURLString: catalogItem.artworkURLString,
            duration: catalogItem.duration
        )
    }

    static func make(recentlyPlayed item: RecentlyPlayedMusicItem) -> LocalServiceAppleMusicPlayable? {
        switch item {
        case .album(let album):
            return make(album: album)
        case .playlist(let playlist):
            return make(playlist: playlist)
        case .station(let station):
            return make(station: station)
        @unknown default:
            return nil
        }
    }

    static func make(recommendation item: MusicPersonalRecommendation.Item) -> LocalServiceAppleMusicPlayable? {
        switch item {
        case .album(let album):
            return make(album: album)
        case .playlist(let playlist):
            return make(playlist: playlist)
        case .station(let station):
            return make(station: station)
        @unknown default:
            return nil
        }
    }

    private static func firstCatalogID(in candidates: [String], kind: Kind) -> String? {
        for candidate in candidates {
            if let normalized = normalizedCatalogID(candidate, kind: kind) {
                return normalized
            }
        }
        return nil
    }

    private static func normalizedCatalogID(_ value: String, kind: Kind) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        candidate = candidate.removingPercentEncoding ?? candidate

        switch kind {
        case .song:
            return SonosAppleMusicTrackResolver.storeID(fromObjectID: candidate).map {
                "song:\($0)"
            }
        case .album:
            return namespacedObjectID(
                from: candidate,
                namespaces: namespaces(for: kind),
                defaultNamespace: "album") {
                    $0.allSatisfy(\.isNumber) || $0.hasPrefix("l.")
                }
        case .artist:
            return namespacedObjectID(
                from: candidate,
                namespaces: namespaces(for: kind),
                defaultNamespace: "artist") {
                    $0.allSatisfy(\.isNumber) || $0.hasPrefix("r.")
                }
        case .playlist:
            return namespacedObjectID(
                from: candidate,
                namespaces: namespaces(for: kind),
                defaultNamespace: "playlist") {
                    $0.hasPrefix("pl.") || $0.hasPrefix("p.") || $0.allSatisfy(\.isNumber)
                }
        case .station:
            return normalizedStationCatalogID(candidate)
        }
    }

    private static func normalizedStationCatalogID(_ value: String) -> String? {
        guard let stationID = stationIDSuffix(from: value) else { return nil }
        return "radio:\(stationID)"
    }

    private static func stationIDSuffix(from value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        candidate = candidate.removingPercentEncoding ?? candidate
        if let fragmentStart = candidate.firstIndex(of: "#") {
            candidate = String(candidate[..<fragmentStart])
        }
        if let queryStart = candidate.firstIndex(of: "?") {
            candidate = String(candidate[..<queryStart])
        }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        candidate = candidate.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? candidate
        candidate = candidate.split(separator: ":", omittingEmptySubsequences: true).last.map(String.init) ?? candidate
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        if candidate.hasPrefix("ra."), candidate.count > 3 {
            return candidate
        }
        if !candidate.isEmpty, candidate.allSatisfy(\.isNumber) {
            return "ra.\(candidate)"
        }
        return nil
    }

    private static func detectedStationPlaybackKind(in candidates: [String]) -> StationPlaybackKind? {
        for candidate in candidates {
            switch stationPlaybackMarker(candidate) {
            case .stream:
                return .stream
            case .tracks:
                return .tracks
            case nil:
                continue
            }
        }
        return nil
    }

    private static func stationStreamObjectID(in candidates: [String]) -> String? {
        candidates.first { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard stationPlaybackMarker(trimmed) == nil else { return false }
            guard !isStationDescriptor(trimmed) else { return false }
            guard normalizedStationCatalogID(trimmed) == nil else { return false }
            guard !trimmed.localizedCaseInsensitiveContains("music.apple.com") else { return false }
            return trimmed.range(
                of: #"^[A-Za-z0-9_-]{8,}$"#,
                options: .regularExpression
            ) != nil
        }
    }

    private static func stationPlaybackMarker(_ value: String) -> StationPlaybackKind? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        if normalized == "stream" {
            return .stream
        }
        if normalized == "tracks" {
            return .tracks
        }
        return nil
    }

    private static func isStationDescriptor(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return ["radio", "radiostation", "station"].contains(normalized)
    }

    private static func namespacedObjectID(
        from value: String,
        namespaces: Set<String>,
        defaultNamespace: String,
        isValid: (String) -> Bool
    ) -> String? {
        if isValid(value) {
            return "\(defaultNamespace):\(value)"
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2,
              let namespace = parts.dropLast().last?.lowercased(),
              namespaces.contains(namespace) else {
            return nil
        }
        let suffix = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !suffix.isEmpty && isValid(suffix) else { return nil }
        return "\(canonicalNamespace(namespace, defaultNamespace: defaultNamespace)):\(suffix)"
    }

    private static func canonicalNamespace(_ namespace: String, defaultNamespace: String) -> String {
        if namespace.hasPrefix("library") {
            return namespace
        }
        return defaultNamespace
    }

    private static func namespaces(for kind: Kind) -> Set<String> {
        switch kind {
        case .song: return ["song", "songs", "track", "tracks"]
        case .album: return ["album", "albums", "libraryalbum", "libraryalbums"]
        case .artist: return ["artist", "artists", "libraryartist", "libraryartists"]
        case .playlist: return ["playlist", "playlists", "libraryplaylist", "libraryplaylists"]
        case .station: return ["station", "stations", "radio"]
        }
    }

    private static func playParameterCandidates(from playParameters: PlayParameters?) -> [String] {
        guard let playParameters,
              let data = try? JSONEncoder().encode(playParameters),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        var preferred: [String] = []
        var fallback: [String] = []
        collectStringCandidates(from: object, preferred: &preferred, fallback: &fallback)
        return deduped(preferred + fallback)
    }

    private static func collectStringCandidates(
        from object: Any,
        key: String? = nil,
        preferred: inout [String],
        fallback: inout [String]
    ) {
        if let dictionary = object as? [String: Any] {
            for (childKey, value) in dictionary {
                collectStringCandidates(
                    from: value,
                    key: childKey,
                    preferred: &preferred,
                    fallback: &fallback)
            }
            return
        }

        if let array = object as? [Any] {
            for value in array {
                collectStringCandidates(from: value, preferred: &preferred, fallback: &fallback)
            }
            return
        }

        guard let value = object as? String else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isPreferredCatalogKey(key) {
            preferred.append(trimmed)
        } else {
            fallback.append(trimmed)
        }
    }

    private static func isPreferredCatalogKey(_ key: String?) -> Bool {
        guard let key else { return false }
        let normalized = key
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return normalized.contains("catalog") || normalized == "id" || normalized == "adamid"
    }

    private static func deduped(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static func artworkURLString(_ artwork: Artwork?) -> String? {
        guard let rawURLString = artwork?.url(width: 400, height: 400)?.absoluteString else {
            return nil
        }
        return normalizedArtworkURLString(rawURLString)
    }

    private static func normalizedArtworkURLString(_ value: String?) -> String? {
        LocalMusicArtworkURL.loadableURLString(
            from: value?.trimmingCharacters(in: .whitespacesAndNewlines),
            shortSidePixels: LocalMusicArtworkURL.catalogDisplayShortSidePixels
        )
    }

    private static func normalizedPreferredArtworkURLString(_ value: String?) -> String? {
        LocalMusicArtworkURL.catalogDisplayURLString(
            from: value?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum LocalServicePlaybackArtworkPolicy {
    static func shouldPreferCatalogArtwork(
        kind: LocalServiceAppleMusicPlayable.Kind,
        existingArtworkURLString: String?
    ) -> Bool {
        let hasExistingArtwork = !(existingArtworkURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)

        if kind == .playlist && hasExistingArtwork {
            return false
        }

        return true
    }
}

extension LocalServiceAppleMusicPlayable.StationPlaybackKind {
    var diagnosticName: String {
        switch self {
        case .tracks: return "tracks"
        case .stream: return "stream"
        }
    }
}
