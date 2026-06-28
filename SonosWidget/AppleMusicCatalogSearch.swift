import Foundation
import MusicKit

enum AppleMusicCatalogItemType: Equatable, Sendable {
    case song
    case album
    case artist
    case playlist

    var cloudType: String {
        switch self {
        case .song: return "TRACK"
        case .album: return "ALBUM"
        case .artist: return "ARTIST"
        case .playlist: return "PLAYLIST"
        }
    }

    var isContainer: Bool {
        switch self {
        case .album, .playlist: return true
        case .song, .artist: return false
        }
    }
}

enum AppleMusicExternalResourceKind: Equatable, Sendable {
    case song
    case album
    case artist
    case playlist

    init(_ favoriteResourceType: AppleMusicFavoriteResourceType) {
        switch favoriteResourceType {
        case .songs:
            self = .song
        case .albums:
            self = .album
        case .artists:
            self = .artist
        case .playlists:
            self = .playlist
        }
    }
}

struct AppleMusicArtworkInfo: Equatable, Sendable {
    let artworkURLString: String?
    let themeColors: ArtworkThemeColors?
}

struct AppleMusicCatalogSearchItem: Identifiable, Equatable, Sendable {
    let id: String
    let type: AppleMusicCatalogItemType
    let title: String
    let artist: String
    let album: String
    let artworkURLString: String?
    let artworkThemeColors: ArtworkThemeColors?
    let duration: TimeInterval?
    let urlString: String?

    init(
        id: String,
        type: AppleMusicCatalogItemType,
        title: String,
        artist: String,
        album: String,
        artworkURLString: String?,
        artworkThemeColors: ArtworkThemeColors? = nil,
        duration: TimeInterval?,
        urlString: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURLString = Self.normalizedArtworkURLString(artworkURLString)
        self.artworkThemeColors = artworkThemeColors
        self.duration = duration
        self.urlString = urlString
    }

    private static func normalizedArtworkURLString(_ value: String?) -> String? {
        LocalMusicArtworkURL.catalogDisplayURLString(from: value)
    }

    var sonosPlayableObjectID: String {
        switch type {
        case .song:
            return "song:\(id)"
        case .album:
            return "album:\(id)"
        case .artist:
            return "artist:\(id)"
        case .playlist:
            return "playlist:\(id)"
        }
    }

    var sonosPlayableMimeType: String? {
        switch type {
        case .song:
            return "audio/mp4"
        case .album, .artist, .playlist:
            return nil
        }
    }

    func browseItem(localServiceId: Int?, uri: String? = nil) -> BrowseItem {
        BrowseItem(
            id: sonosPlayableObjectID,
            title: title,
            artist: artist,
            album: album,
            albumArtURL: artworkURLString,
            uri: uri,
            duration: duration ?? 0,
            isContainer: type.isContainer,
            serviceId: localServiceId,
            cloudType: type.cloudType
        )
    }
}

enum LocalMusicCatalogMatcher {
    static func bestItem(
        in items: [AppleMusicCatalogSearchItem],
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> AppleMusicCatalogSearchItem? {
        guard let targetType = AppleMusicCatalogItemType(kind: kind) else { return nil }
        let candidates = items.filter { $0.type == targetType }
        guard !candidates.isEmpty else { return nil }

        let targetTitle = normalized(title)
        let targetArtist = normalized(artist ?? "")
        let targetAlbum = normalized(album ?? "")

        let titleMatches = candidates.filter { normalized($0.title) == targetTitle }
        if let exact = titleMatches.first(where: {
            switch kind {
            case .song:
                return targetArtist.isEmpty || normalized($0.artist) == targetArtist
            case .album:
                return targetArtist.isEmpty || normalized($0.artist) == targetArtist
            case .artist:
                return true
            case .playlist:
                return targetArtist.isEmpty || normalized($0.artist) == targetArtist
            case .station:
                return false
            }
        }) {
            return exact
        }

        if kind == .song,
           let albumMatch = titleMatches.first(where: {
               !targetAlbum.isEmpty && normalized($0.album) == targetAlbum
           }) {
            return albumMatch
        }

        return titleMatches.first ?? candidates.first
    }

    static func searchTerm(
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> String {
        var parts = [title]
        switch kind {
        case .song, .album, .artist:
            parts.append(artist ?? "")
        case .playlist:
            break
        case .station:
            parts.append(artist ?? "")
        }
        if kind == .song {
            parts.append(album ?? "")
        }
        return dedupedNormalized(parts)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func dedupedNormalized(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let normalizedValue = normalized(value)
            guard !normalizedValue.isEmpty, seen.insert(normalizedValue).inserted else { continue }
            result.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
}

struct AppleMusicLibraryTrackPlaybackResolver: Sendable {
    typealias CatalogSearch = @Sendable (_ term: String, _ limit: Int) async throws -> [AppleMusicCatalogSearchItem]
    typealias ITunesCatalogSearch = @Sendable (
        _ title: String,
        _ artist: String?,
        _ album: String?,
        _ countryCode: String?
    ) async throws -> String?

    private enum ResolutionStatus {
        case unchanged
        case resolved(source: String)
        case missed
        case failed
    }

    private struct ResolutionOutcome {
        let item: BrowseItem
        let status: ResolutionStatus
        let originalID: String
    }

    private let catalogSearch: CatalogSearch
    private let iTunesCatalogSearch: ITunesCatalogSearch
    private let searchLimit: Int
    private let countryCode: String?
    private let appleMusicLocalServiceIDs: Set<Int>
    private let maxConcurrentResolutions: Int

    init(
        catalogSearch: @escaping CatalogSearch = { term, limit in
            try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: limit)
        },
        iTunesCatalogSearch: @escaping ITunesCatalogSearch = { title, artist, album, countryCode in
            try await AppleMusicITunesArtworkClient.shared.searchSongCatalogID(
                title: title,
                artist: artist,
                album: album,
                countryCode: countryCode)
        },
        searchLimit: Int = 8,
        countryCode: String? = nil,
        appleMusicLocalServiceIDs: Set<Int> = [204],
        maxConcurrentResolutions: Int = 8
    ) {
        self.catalogSearch = catalogSearch
        self.iTunesCatalogSearch = iTunesCatalogSearch
        self.searchLimit = max(1, min(searchLimit, 25))
        self.countryCode = countryCode
        self.appleMusicLocalServiceIDs = appleMusicLocalServiceIDs
        self.maxConcurrentResolutions = max(1, maxConcurrentResolutions)
    }

    func resolvedItem(_ item: BrowseItem) async -> BrowseItem {
        await resolvedOutcome(for: item).item
    }

    func resolvedItems(_ items: [BrowseItem]) async -> [BrowseItem] {
        let unresolvedCount = items.filter {
            Self.needsCatalogResolution($0, appleMusicLocalServiceIDs: appleMusicLocalServiceIDs)
        }.count
        guard unresolvedCount > 0 else { return items }

        let startedAt = Date()
        SonosLog.info(
            .playbackLink,
            "Apple Music librarytrack playback resolve start count=\(items.count) unresolved=\(unresolvedCount)")

        var outcomes = Array<ResolutionOutcome?>(repeating: nil, count: items.count)
        let indexedItems = Array(items.enumerated())
        var iterator = indexedItems.makeIterator()

        await withTaskGroup(of: (Int, ResolutionOutcome).self) { group in
            for _ in 0..<min(maxConcurrentResolutions, indexedItems.count) {
                guard let next = iterator.next() else { break }
                group.addTask {
                    (next.offset, await resolvedOutcome(for: next.element))
                }
            }

            while let (index, outcome) = await group.next() {
                outcomes[index] = outcome
                if let next = iterator.next() {
                    group.addTask {
                        (next.offset, await resolvedOutcome(for: next.element))
                    }
                }
            }
        }

        let resolvedOutcomes = outcomes.compactMap { $0 }
        let resolvedCount = resolvedOutcomes.filter {
            if case .resolved = $0.status { return true }
            return false
        }.count
        let resolvedSources = Dictionary(
            grouping: resolvedOutcomes.compactMap { outcome -> String? in
                if case .resolved(let source) = outcome.status {
                    return source
                }
                return nil
            },
            by: { $0 }
        )
        .map { "\($0.key):\($0.value.count)" }
        .sorted()
        .joined(separator: ",")
        let missedCount = resolvedOutcomes.filter {
            if case .missed = $0.status { return true }
            return false
        }.count
        let failedCount = resolvedOutcomes.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        let sampleMisses = resolvedOutcomes
            .filter {
                switch $0.status {
                case .missed, .failed: return true
                case .unchanged, .resolved: return false
                }
            }
            .prefix(3)
            .map { SonosLog.playbackLinkValue($0.originalID, maxLength: 80) }
            .joined(separator: ",")
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        SonosLog.info(
            .playbackLink,
            "Apple Music librarytrack playback resolve done count=\(items.count) " +
                "resolved=\(resolvedCount) sources=\(resolvedSources.isEmpty ? "none" : resolvedSources) " +
                "missed=\(missedCount) failed=\(failedCount) " +
                "ms=\(elapsedMs) sampleMisses=\(sampleMisses.isEmpty ? "none" : sampleMisses)")

        return resolvedOutcomes.map(\.item)
    }

    private func resolvedOutcome(for item: BrowseItem) async -> ResolutionOutcome {
        guard Self.needsCatalogResolution(item, appleMusicLocalServiceIDs: appleMusicLocalServiceIDs) else {
            return ResolutionOutcome(item: item, status: .unchanged, originalID: item.id)
        }

        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: .song,
            title: item.title,
            artist: item.artist,
            album: item.album)
        guard !term.isEmpty else {
            return ResolutionOutcome(item: item, status: .missed, originalID: item.id)
        }

        do {
            let matches = try await catalogSearch(term, searchLimit)
            if let match = LocalMusicCatalogMatcher.bestItem(
                in: matches,
                kind: .song,
                title: item.title,
                artist: item.artist,
                album: item.album
            ),
               let resolved = resolvedItem(
                item,
                catalogID: match.id,
                artworkURLString: match.artworkURLString,
                duration: match.duration,
                title: match.title,
                artist: match.artist,
                album: match.album) {
                return ResolutionOutcome(item: resolved, status: .resolved(source: "musicKit"), originalID: item.id)
            }
        } catch {
            SonosLog.debug(
                .playbackLink,
                "Apple Music librarytrack MusicKit resolve failed id=\(SonosLog.playbackLinkValue(item.id, maxLength: 120)) error=\(error)")
        }

        do {
            if let catalogID = try await iTunesCatalogSearch(item.title, item.artist, item.album, countryCode),
               let resolved = resolvedItem(
                item,
                catalogID: catalogID,
                artworkURLString: nil,
                duration: nil,
                title: item.title,
                artist: item.artist,
                album: item.album) {
                return ResolutionOutcome(item: resolved, status: .resolved(source: "iTunes"), originalID: item.id)
            }
            return ResolutionOutcome(item: item, status: .missed, originalID: item.id)
        } catch {
            SonosLog.debug(
                .playbackLink,
                "Apple Music librarytrack iTunes resolve failed id=\(SonosLog.playbackLinkValue(item.id, maxLength: 120)) error=\(error)")
            return ResolutionOutcome(item: item, status: .failed, originalID: item.id)
        }
    }

    private func resolvedItem(
        _ item: BrowseItem,
        catalogID: String,
        artworkURLString: String?,
        duration: TimeInterval?,
        title: String,
        artist: String,
        album: String
    ) -> BrowseItem? {
        let parsedURI = SonosAppleMusicTrackResolver.parseTrackURI(item.uri)
        guard let localSid = parsedURI.localServiceID ?? item.serviceId,
              let accountID = parsedURI.accountID,
              !accountID.isEmpty else {
            return nil
        }

        let flags = Self.queryParameter("flags", in: item.uri).flatMap(Int.init) ?? 8232
        let objectID = "song:\(catalogID)"
        var resolved = item
        resolved.id = objectID
        resolved.uri = SonosPlayableURIBuilder.serviceURI(
            scheme: "x-sonos-http",
            objectID: objectID,
            localSid: localSid,
            flags: flags,
            accountID: accountID,
            fileExtension: ".mp4")
        if resolved.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.title = title
        }
        if resolved.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.artist = artist
        }
        if resolved.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.album = album
        }
        if resolved.albumArtURL == nil {
            resolved.albumArtURL = artworkURLString
        }
        if resolved.detailArtworkURL == nil {
            resolved.detailArtworkURL = artworkURLString
        }
        if resolved.duration <= 0, let duration {
            resolved.duration = duration
        }
        resolved.isContainer = false
        resolved.serviceId = localSid
        resolved.cloudType = "TRACK"
        return resolved
    }

    private static func needsCatalogResolution(
        _ item: BrowseItem,
        appleMusicLocalServiceIDs: Set<Int>
    ) -> Bool {
        guard !item.isContainer else { return false }
        if let cloudType = item.cloudType?.uppercased(), cloudType != "TRACK" {
            return false
        }
        guard SonosAppleMusicTrackResolver.storeID(fromBrowseItem: item) == nil else {
            return false
        }
        guard isAppleMusicItem(item, appleMusicLocalServiceIDs: appleMusicLocalServiceIDs) else {
            return false
        }
        return unresolvedLibraryTrackValue(in: item) != nil
    }

    private static func isAppleMusicItem(
        _ item: BrowseItem,
        appleMusicLocalServiceIDs: Set<Int>
    ) -> Bool {
        if let serviceID = item.serviceId,
           appleMusicLocalServiceIDs.contains(serviceID) {
            return true
        }
        if let uri = item.uri,
           PlaybackSource.from(trackURI: uri) == .appleMusic {
            return true
        }
        return false
    }

    private static func unresolvedLibraryTrackValue(in item: BrowseItem) -> String? {
        [item.id, item.uri, item.metaXML, item.resMD]
            .compactMap { $0 }
            .first { value in
                let decoded = value.removingPercentEncoding ?? value
                let lowercased = decoded.lowercased()
                return lowercased.contains("librarytrack:") ||
                    lowercased.hasPrefix("i.") ||
                    lowercased.hasPrefix("l.")
            }
    }

    private static func queryParameter(_ name: String, in value: String?) -> String? {
        guard let value else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:[?&]|&amp;)\(escaped)=([^&\\s\"<>]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range]).removingPercentEncoding ?? String(value[range])
    }
}

enum LocalMusicCatalogIDExtractor {
    static func playlistCatalogID(rawID: String, urlString: String?) -> String? {
        if let urlString,
           let link = AppleMusicShareLinkParser.parse(urlString),
           link.kind == .playlist {
            return link.catalogID
        }

        if let link = AppleMusicShareLinkParser.parse(rawID),
           link.kind == .playlist {
            return link.catalogID
        }

        return rawPlaylistCatalogID(rawID)
    }

    private static func rawPlaylistCatalogID(_ value: String) -> String? {
        let decoded = value.removingPercentEncoding ?? value
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed
            .split(separator: ":", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? trimmed

        return suffix.hasPrefix("pl.") ? suffix : nil
    }
}

enum LocalMusicCatalogArtworkFallback {
    static func artworkInfo(
        in items: [AppleMusicCatalogSearchItem],
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> AppleMusicArtworkInfo? {
        guard let match = LocalMusicCatalogMatcher.bestItem(
            in: items,
            kind: kind,
            title: title,
            artist: artist,
            album: album
        ) else {
            return nil
        }

        let artworkURLString = validURLString(match.artworkURLString)
        guard artworkURLString != nil || match.artworkThemeColors != nil else {
            return nil
        }

        return AppleMusicArtworkInfo(
            artworkURLString: artworkURLString,
            themeColors: match.artworkThemeColors
        )
    }

    static func artworkURLString(
        in items: [AppleMusicCatalogSearchItem],
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?
    ) -> String? {
        artworkInfo(
            in: items,
            kind: kind,
            title: title,
            artist: artist,
            album: album
        )?.artworkURLString
    }

    private static func validURLString(_ value: String?) -> String? {
        guard let value,
              LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(value) else {
            return nil
        }
        return value
    }
}

enum LocalMusicCatalogWebURLFallback {
    static func urlString(
        in items: [AppleMusicCatalogSearchItem],
        kind: LocalServiceAppleMusicPlayable.Kind,
        title: String,
        artist: String?,
        album: String?,
        allowGeneratedFallback: Bool = true
    ) -> String? {
        guard let match = LocalMusicCatalogMatcher.bestItem(
            in: items,
            kind: kind,
            title: title,
            artist: artist,
            album: album
        ) else {
            return nil
        }

        if let urlString = validAppleMusicURLString(match.urlString, kind: kind) {
            return urlString
        }

        guard allowGeneratedFallback else { return nil }

        guard let webKind = LocalMusicAppleMusicURL.Kind(kind),
              let playable = LocalServiceAppleMusicPlayable.make(catalogItem: match) else {
            return nil
        }

        return LocalMusicAppleMusicURL.url(
            existingURL: nil,
            playable: playable,
            kind: webKind
        )?.absoluteString
    }

    private static func validAppleMusicURLString(
        _ value: String?,
        kind: LocalServiceAppleMusicPlayable.Kind
    ) -> String? {
        guard let value,
              let link = AppleMusicShareLinkParser.parse(value),
              link.kind == AppleMusicShareLink.Kind(kind) else {
            return nil
        }
        return value
    }
}

extension AppleMusicCatalogItemType {
    init?(kind: LocalServiceAppleMusicPlayable.Kind) {
        switch kind {
        case .song:
            self = .song
        case .album:
            self = .album
        case .artist:
            self = .artist
        case .playlist:
            self = .playlist
        case .station:
            return nil
        }
    }
}

private extension AppleMusicShareLink.Kind {
    init?(_ kind: LocalServiceAppleMusicPlayable.Kind) {
        switch kind {
        case .song:
            self = .song
        case .album:
            self = .album
        case .artist:
            self = .artist
        case .playlist:
            self = .playlist
        case .station:
            return nil
        }
    }
}

enum AppleMusicCatalogSearchError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Apple Music access was not granted."
        }
    }
}

struct AppleMusicCatalogSearchClient {
    static let shared = AppleMusicCatalogSearchClient()
    static let maximumSearchLimit = 25

    func search(term: String, limit: Int = 8) async throws -> [AppleMusicCatalogSearchItem] {
        try await ensureAuthorized()

        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Song.self, Album.self, Artist.self, Playlist.self]
        )
        request.limit = Self.effectiveSearchLimit(requested: limit)
        let response = try await request.response()

        var items: [AppleMusicCatalogSearchItem] = []
        items.append(contentsOf: response.songs.map(Self.item(from:)))
        items.append(contentsOf: response.albums.map(Self.item(from:)))
        items.append(contentsOf: response.artists.map(Self.item(from:)))
        items.append(contentsOf: response.playlists.map(Self.item(from:)))
        return items
    }

    static func effectiveSearchLimit(requested limit: Int) -> Int {
        min(max(limit, 1), maximumSearchLimit)
    }

    func album(catalogID: String) async throws -> Album {
        try await ensureAuthorized()

        var request = MusicCatalogResourceRequest<Album>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        request.limit = 1
        let response = try await request.response()
        guard let album = response.items.first else {
            throw LocalMusicLibraryError.catalogMatchMissing
        }
        return try await album.with(.tracks)
    }

    func artist(catalogID: String) async throws -> Artist {
        try await ensureAuthorized()

        var request = MusicCatalogResourceRequest<Artist>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        request.limit = 1
        let response = try await request.response()
        guard let artist = response.items.first else {
            throw LocalMusicLibraryError.catalogMatchMissing
        }
        return try await artist.with(.fullAlbums, .singles, .latestRelease, .topSongs)
    }

    func playlist(catalogID: String) async throws -> Playlist {
        try await ensureAuthorized()

        var request = MusicCatalogResourceRequest<Playlist>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        request.limit = 1
        let response = try await request.response()
        guard let playlist = response.items.first else {
            throw LocalMusicLibraryError.catalogMatchMissing
        }
        return try await playlist.with(.tracks)
    }

    func playlistArtworkURLString(catalogID: String) async throws -> String? {
        try await artworkURLString(kind: .playlist, catalogID: catalogID)
    }

    func artworkURLString(
        kind: LocalServiceAppleMusicPlayable.Kind,
        catalogID: String
    ) async throws -> String? {
        try await artworkInfo(kind: kind, catalogID: catalogID)?.artworkURLString
    }

    func artworkInfo(
        kind: LocalServiceAppleMusicPlayable.Kind,
        catalogID: String
    ) async throws -> AppleMusicArtworkInfo? {
        try await ensureAuthorized()

        switch kind {
        case .song:
            var request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first.flatMap { Self.artworkInfo($0.artwork) }
        case .album:
            var request = MusicCatalogResourceRequest<Album>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first.flatMap { Self.artworkInfo($0.artwork) }
        case .artist:
            var request = MusicCatalogResourceRequest<Artist>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first.flatMap { Self.artworkInfo($0.artwork) }
        case .playlist:
            var request = MusicCatalogResourceRequest<Playlist>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first.flatMap { Self.artworkInfo($0.artwork) }
        case .station:
            return nil
        }
    }

    func appleMusicURLString(
        kind: LocalMusicAppleMusicURL.Kind,
        catalogID: String
    ) async throws -> String? {
        try await ensureAuthorized()

        switch kind {
        case .album:
            var request = MusicCatalogResourceRequest<Album>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first?.url?.absoluteString
        case .artist:
            var request = MusicCatalogResourceRequest<Artist>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first?.url?.absoluteString
        case .playlist:
            var request = MusicCatalogResourceRequest<Playlist>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first?.url?.absoluteString
        }
    }

    func appleMusicURLString(
        kind: AppleMusicExternalResourceKind,
        catalogID: String
    ) async throws -> String? {
        try await ensureAuthorized()

        switch kind {
        case .song:
            var request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            request.limit = 1
            let response = try await request.response()
            return response.items.first?.url?.absoluteString
        case .album:
            return try await appleMusicURLString(kind: LocalMusicAppleMusicURL.Kind.album, catalogID: catalogID)
        case .artist:
            return try await appleMusicURLString(kind: LocalMusicAppleMusicURL.Kind.artist, catalogID: catalogID)
        case .playlist:
            return try await appleMusicURLString(kind: LocalMusicAppleMusicURL.Kind.playlist, catalogID: catalogID)
        }
    }

    private func ensureAuthorized() async throws {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return
        case .notDetermined:
            guard await MusicAuthorization.request() == .authorized else {
                throw AppleMusicCatalogSearchError.authorizationDenied
            }
        case .denied, .restricted:
            throw AppleMusicCatalogSearchError.authorizationDenied
        @unknown default:
            throw AppleMusicCatalogSearchError.authorizationDenied
        }
    }

    private static func item(from song: Song) -> AppleMusicCatalogSearchItem {
        AppleMusicCatalogSearchItem(
            id: song.id.rawValue,
            type: .song,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            artworkURLString: artworkURLString(song.artwork),
            artworkThemeColors: artworkThemeColors(song.artwork),
            duration: song.duration,
            urlString: song.url?.absoluteString
        )
    }

    private static func item(from album: Album) -> AppleMusicCatalogSearchItem {
        AppleMusicCatalogSearchItem(
            id: album.id.rawValue,
            type: .album,
            title: album.title,
            artist: album.artistName,
            album: album.title,
            artworkURLString: artworkURLString(album.artwork),
            artworkThemeColors: artworkThemeColors(album.artwork),
            duration: nil,
            urlString: album.url?.absoluteString
        )
    }

    private static func item(from artist: Artist) -> AppleMusicCatalogSearchItem {
        AppleMusicCatalogSearchItem(
            id: artist.id.rawValue,
            type: .artist,
            title: artist.name,
            artist: "",
            album: "",
            artworkURLString: artworkURLString(artist.artwork),
            artworkThemeColors: artworkThemeColors(artist.artwork),
            duration: nil,
            urlString: artist.url?.absoluteString
        )
    }

    private static func item(from playlist: Playlist) -> AppleMusicCatalogSearchItem {
        AppleMusicCatalogSearchItem(
            id: playlist.id.rawValue,
            type: .playlist,
            title: playlist.name,
            artist: playlist.curatorName ?? "",
            album: "",
            artworkURLString: artworkURLString(playlist.artwork),
            artworkThemeColors: artworkThemeColors(playlist.artwork),
            duration: nil,
            urlString: playlist.url?.absoluteString
        )
    }

    private static func artworkURLString(_ artwork: Artwork?) -> String? {
        LocalMusicArtworkURL.loadableURLString(
            from: artwork?.url(
                width: LocalMusicArtworkURL.catalogDisplayShortSidePixels,
                height: LocalMusicArtworkURL.catalogDisplayShortSidePixels
            )?.absoluteString,
            shortSidePixels: LocalMusicArtworkURL.catalogDisplayShortSidePixels
        )
    }

    private static func artworkInfo(_ artwork: Artwork?) -> AppleMusicArtworkInfo? {
        let urlString = artworkURLString(artwork)
        let themeColors = artworkThemeColors(artwork)
        guard urlString != nil || themeColors != nil else {
            return nil
        }

        return AppleMusicArtworkInfo(
            artworkURLString: urlString,
            themeColors: themeColors
        )
    }

    private static func artworkThemeColors(_ artwork: Artwork?) -> ArtworkThemeColors? {
        guard let artwork else { return nil }

        let colors = ArtworkThemeColors(
            background: artwork.backgroundColor.flatMap(HueRGBColor.init(cgColor:)),
            textColors: [
                artwork.primaryTextColor,
                artwork.secondaryTextColor,
                artwork.tertiaryTextColor,
                artwork.quaternaryTextColor
            ].compactMap { $0.flatMap(HueRGBColor.init(cgColor:)) }
        )
        return colors.background != nil || !colors.textColors.isEmpty ? colors : nil
    }
}
