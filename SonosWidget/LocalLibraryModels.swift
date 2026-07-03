import Foundation

enum LocalLibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case songs
    case albums
    case artists
    case playlists

    var id: String { rawValue }

    static var homeOrder: [LocalLibraryCategory] {
        [.playlists, .artists, .albums, .songs]
    }

    var showsAlphabetIndex: Bool {
        self != .playlists
    }

    var title: String {
        switch self {
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: return "music.note"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .playlists: return "music.note.list"
        }
    }

    var emptyTitle: String {
        switch self {
        case .songs: return "No Songs"
        case .albums: return "No Albums"
        case .artists: return "No Artists"
        case .playlists: return "No Playlists"
        }
    }
}

enum LocalLibraryCategorySortOption: String, CaseIterable, Identifiable, Sendable {
    case title
    case artist
    case album
    case curator
    case recentlyAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title:
            return "Title"
        case .artist:
            return "Artist"
        case .album:
            return "Album"
        case .curator:
            return "Curator"
        case .recentlyAdded:
            return "Recently Added"
        }
    }

    static func defaultOption(for category: LocalLibraryCategory) -> LocalLibraryCategorySortOption {
        switch category {
        case .songs, .albums, .artists, .playlists:
            return .title
        }
    }

    static func options(for category: LocalLibraryCategory) -> [LocalLibraryCategorySortOption] {
        switch category {
        case .songs:
            return [.title, .artist, .album, .recentlyAdded]
        case .albums:
            return [.title, .artist, .recentlyAdded]
        case .artists:
            return [.title]
        case .playlists:
            return [.title, .curator, .recentlyAdded]
        }
    }
}

enum LocalServiceSearchScope: String, CaseIterable, Identifiable, Sendable {
    case library
    case appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library:
            return "Library"
        case .appleMusic:
            return "Apple Music"
        }
    }
}

struct LocalServiceSubmittedSearchFieldDisplay: Equatable, Sendable {
    let term: String
    let scopeHint: String
}

struct LocalServiceCatalogRowText: Equatable, Sendable {
    let subtitle: String?
    let detail: String?
}

enum LocalServiceSearchPresentation {
    static let catalogCategoryOrder: [LocalLibraryCategory] = [
        .artists,
        .albums,
        .songs,
        .playlists
    ]

    static func prompt(for scope: LocalServiceSearchScope) -> String {
        switch scope {
        case .library:
            return "Search Library"
        case .appleMusic:
            return "Search in Apple Music"
        }
    }

    static func contextLabel(
        for term: String,
        scope: LocalServiceSearchScope
    ) -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prompt(for: scope) }
        return "\(trimmed) in \(scope.title)"
    }

    static func submittedFieldDisplay(
        for term: String,
        scope: LocalServiceSearchScope
    ) -> LocalServiceSubmittedSearchFieldDisplay? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return LocalServiceSubmittedSearchFieldDisplay(
            term: trimmed,
            scopeHint: " in \(scope.title)"
        )
    }

    static func showsCatalogCategories(
        scope: LocalServiceSearchScope,
        hasSubmittedSearch: Bool
    ) -> Bool {
        scope == .appleMusic && hasSubmittedSearch
    }

    static func showsGenericSearchResultsHeading(
        scope: LocalServiceSearchScope,
        hasSubmittedSearch: Bool
    ) -> Bool {
        false
    }

    static func catalogRowText(for item: AppleMusicCatalogSearchItem) -> LocalServiceCatalogRowText {
        switch item.type {
        case .song:
            return LocalServiceCatalogRowText(
                subtitle: nonEmpty(item.artist) ?? nonEmpty(item.album),
                detail: nonEmpty(item.album)
            )
        case .album:
            return LocalServiceCatalogRowText(
                subtitle: nonEmpty(item.artist),
                detail: nil
            )
        case .artist:
            return LocalServiceCatalogRowText(
                subtitle: nonEmpty(item.artist),
                detail: nil
            )
        case .playlist:
            return LocalServiceCatalogRowText(
                subtitle: nonEmpty(item.artist),
                detail: nil
            )
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct LocalServiceCatalogSearchResults: Equatable, Sendable {
    var items: [AppleMusicCatalogSearchItem] = []

    var isEmpty: Bool {
        items.isEmpty
    }

    var visibleCategories: [LocalLibraryCategory] {
        LocalLibraryCategory.homeOrder.filter { count(for: $0) > 0 }
    }

    func count(for category: LocalLibraryCategory) -> Int {
        items(for: category).count
    }

    func items(for category: LocalLibraryCategory) -> [AppleMusicCatalogSearchItem] {
        items.filter { item in
            switch (category, item.type) {
            case (.songs, .song), (.albums, .album), (.artists, .artist), (.playlists, .playlist):
                return true
            default:
                return false
            }
        }
    }
}

enum LocalServiceCatalogSearchInteraction {
    static func primaryAction(
        for type: AppleMusicCatalogItemType
    ) -> LocalServiceLibraryPrimaryAction {
        switch type {
        case .song:
            return .play
        case .album, .artist, .playlist:
            return .navigate
        }
    }
}

nonisolated enum LocalLibrarySectionIndex {
    static func indexTitle(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "#" }

        let folded = trimmed.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        guard let scalar = folded.uppercased().unicodeScalars.first,
              (65...90).contains(Int(scalar.value)) else {
            return "#"
        }

        return String(Character(scalar))
    }

    static func indexTitles(for titles: [String]) -> [String] {
        let titles = Set(titles.map(indexTitle(for:)))
        return sortedIndexTitles(titles)
    }

    static func sortedIndexTitles(_ titles: Set<String>) -> [String] {
        titles.sorted { lhs, rhs in
            if lhs == "#" { return true }
            if rhs == "#" { return false }
            return lhs < rhs
        }
    }
}

struct LocalLibraryIndexedSection<Item>: Identifiable {
    let title: String
    let items: [Item]

    var id: String { title }
}

struct LocalLibraryCategoryDetailPresentation<Item> {
    let items: [Item]
    let sections: [LocalLibraryIndexedSection<Item>]
    let indexTitles: [String]

    static var empty: LocalLibraryCategoryDetailPresentation<Item> {
        LocalLibraryCategoryDetailPresentation(items: [], sections: [], indexTitles: [])
    }

    static func make(
        items: [Item],
        isIncluded: (Item) -> Bool,
        areInIncreasingOrder: (Item, Item) -> Bool,
        title: (Item) -> String
    ) -> LocalLibraryCategoryDetailPresentation<Item> {
        make(
            displayedItems: items.filter(isIncluded).sorted(by: areInIncreasingOrder),
            title: title)
    }

    static func make(
        displayedItems: [Item],
        title: (Item) -> String
    ) -> LocalLibraryCategoryDetailPresentation<Item> {
        var groupedItems: [String: [Item]] = [:]
        var sectionTitles = Set<String>()

        for item in displayedItems {
            let sectionTitle = LocalLibrarySectionIndex.indexTitle(for: title(item))
            sectionTitles.insert(sectionTitle)
            groupedItems[sectionTitle, default: []].append(item)
        }

        let indexTitles = LocalLibrarySectionIndex.sortedIndexTitles(sectionTitles)
        return LocalLibraryCategoryDetailPresentation(
            items: displayedItems,
            sections: indexTitles.map { title in
                LocalLibraryIndexedSection(
                    title: title,
                    items: groupedItems[title] ?? [])
            },
            indexTitles: indexTitles)
    }
}

enum LocalLibraryDisplayedSnapshotSource: Equatable, Sendable {
    case library
    case search
}

struct LocalLibraryDisplayedSnapshotToken: Equatable, Sendable {
    let source: LocalLibraryDisplayedSnapshotSource
    let revision: Int
}

struct LocalLibraryCategoryDetailPresentationCacheKey: Equatable, Sendable {
    let category: LocalLibraryCategory
    let contentToken: LocalLibraryDisplayedSnapshotToken
    let searchText: String
    let sortOption: LocalLibraryCategorySortOption
}

final class LocalLibraryCategoryDetailPresentationCache<Item> {
    private var cachedKey: LocalLibraryCategoryDetailPresentationCacheKey?
    private var cachedPresentation = LocalLibraryCategoryDetailPresentation<Item>.empty

    func presentation(
        key: LocalLibraryCategoryDetailPresentationCacheKey,
        items: [Item],
        isIncluded: (Item) -> Bool,
        areInIncreasingOrder: (Item, Item) -> Bool,
        title: (Item) -> String
    ) -> LocalLibraryCategoryDetailPresentation<Item> {
        if cachedKey == key {
            return cachedPresentation
        }

        let nextPresentation = LocalLibraryCategoryDetailPresentation.make(
            items: items,
            isIncluded: isIncluded,
            areInIncreasingOrder: areInIncreasingOrder,
            title: title)
        cachedKey = key
        cachedPresentation = nextPresentation
        return nextPresentation
    }

    func invalidate() {
        cachedKey = nil
        cachedPresentation = .empty
    }
}

struct LocalLibrarySnapshotSummary: Equatable, Sendable {
    let songCount: Int
    let albumCount: Int
    let artistCount: Int
    let playlistCount: Int

    var totalCount: Int {
        songCount + albumCount + artistCount + playlistCount
    }

    var isEmpty: Bool {
        totalCount == 0
    }

    func count(for category: LocalLibraryCategory) -> Int {
        switch category {
        case .songs: return songCount
        case .albums: return albumCount
        case .artists: return artistCount
        case .playlists: return playlistCount
        }
    }
}

enum LocalServiceSectionKind: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded
    case recentlyPlayed
    case recommendations
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .recommendations: return "For You"
        case .library: return "Your Library"
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyAdded: return "clock.badge.plus"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .recommendations: return "sparkles"
        case .library: return "music.note.list"
        }
    }

    var headerSystemImage: String? {
        nil
    }
}

enum LocalMusicDetailAction: Equatable, Hashable, Sendable {
    case play
    case shuffle
    case favorite
    case playStation
    case openAppleMusic

    var title: String {
        switch self {
        case .play: return "Play"
        case .shuffle: return "Shuffle"
        case .favorite: return "Favorite"
        case .playStation: return "Play Station"
        case .openAppleMusic: return "Apple Music"
        }
    }

    var systemImage: String {
        switch self {
        case .play: return "play.fill"
        case .shuffle: return "shuffle"
        case .favorite: return "heart"
        case .playStation: return "antenna.radiowaves.left.and.right"
        case .openAppleMusic: return "music.note"
        }
    }

    var isCompact: Bool {
        self == .openAppleMusic || self == .favorite
    }
}

enum LocalMusicDetailActions {
    static func album(hasAppleMusicURL _: Bool) -> [LocalMusicDetailAction] {
        [.play, .shuffle, .favorite]
    }

    static func artist(hasAppleMusicURL _: Bool) -> [LocalMusicDetailAction] {
        [.playStation]
    }

    static func playlist(hasAppleMusicURL _: Bool) -> [LocalMusicDetailAction] {
        [.play, .shuffle]
    }
}

enum LocalMusicAppleMusicURL {
    enum Kind {
        case album
        case artist
        case playlist

        init?(_ kind: LocalServiceAppleMusicPlayable.Kind) {
            switch kind {
            case .album:
                self = .album
            case .artist:
                self = .artist
            case .playlist:
                self = .playlist
            case .song, .station:
                return nil
            }
        }

        var pathComponent: String {
            switch self {
            case .album: return "album"
            case .artist: return "artist"
            case .playlist: return "playlist"
            }
        }
    }

    static func url(
        existingURL: URL?,
        catalogURL: URL? = nil,
        playable: LocalServiceAppleMusicPlayable?,
        kind: Kind,
        storefront: String = "us"
    ) -> URL? {
        if let existingURL,
           isSupportedAppleMusicURL(existingURL, kind: kind) {
            return existingURL
        }
        if let catalogURL {
            return catalogURL
        }

        guard let playable,
              let catalogID = publicCatalogSuffix(from: playable.catalogID, kind: kind) else {
            return nil
        }

        let slug = slug(for: playable.title)
        return URL(string: "https://music.apple.com/\(storefront)/\(kind.pathComponent)/\(slug)/\(catalogID)")
    }

    static func externalURL(
        existingURL: URL?,
        catalogURL: URL?,
        kind: Kind,
        requiresCatalogURL: Bool = false
    ) -> URL? {
        if let catalogURL,
           isSupportedAppleMusicURL(catalogURL, kind: kind) {
            return catalogURL
        }

        guard !requiresCatalogURL,
              let existingURL,
              isSupportedAppleMusicURL(existingURL, kind: kind) else {
            return nil
        }
        return existingURL
    }

    static func publicCatalogID(from value: String, kind: Kind) -> String? {
        publicCatalogSuffix(from: value, kind: kind)
    }

    private static func publicCatalogSuffix(from value: String, kind: Kind) -> String? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        let suffix = parts.last ?? value
        let namespace = parts.count > 1 ? parts.dropLast().last?.lowercased() : nil
        guard namespace?.hasPrefix("library") != true,
              !suffix.isEmpty else {
            return nil
        }

        switch kind {
        case .album, .artist:
            return suffix.allSatisfy(\.isNumber) ? suffix : nil
        case .playlist:
            return suffix.hasPrefix("pl.") ? suffix : nil
        }
    }

    private static func isSupportedAppleMusicURL(_ url: URL, kind: Kind) -> Bool {
        guard let link = AppleMusicShareLinkParser.parse(url.absoluteString) else {
            return false
        }

        switch (kind, link.kind) {
        case (.album, .album), (.artist, .artist), (.playlist, .playlist):
            return true
        default:
            return false
        }
    }

    private static func slug(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var result = ""
        var didAppendSeparator = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                didAppendSeparator = false
            } else if !didAppendSeparator, !result.isEmpty {
                result.append("-")
                didAppendSeparator = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased().isEmpty
            ? "music"
            : result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }
}

struct LocalMusicArtistAlbumSummaryInput: Equatable, Sendable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let artworkURL: URL?
}

struct LocalMusicArtistAlbumSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let artistName: String
    let artworkURL: URL?
    let songCount: Int
}

nonisolated enum LocalMusicArtistAlbumSummaryBuilder {
    static func summaries(
        from songs: [LocalMusicArtistAlbumSummaryInput]
    ) -> [LocalMusicArtistAlbumSummary] {
        let grouped = Dictionary(grouping: songs) { song in
            albumTitle(song.albumTitle)
        }

        return grouped
            .map { title, songs in
                let artistName = firstMeaningfulArtist(in: songs)
                return LocalMusicArtistAlbumSummary(
                    id: albumID(title: title, artistName: artistName),
                    title: title,
                    artistName: artistName,
                    artworkURL: songs.first { $0.artworkURL != nil }?.artworkURL,
                    songCount: songs.count)
            }
            .sorted(by: summarySort)
    }

    static func artworkLookupItems(
        from summaries: [LocalMusicArtistAlbumSummary]
    ) -> [LocalMusicCatalogArtworkLookupItem] {
        summaries.map { summary in
            LocalMusicCatalogArtworkLookupItem(
                id: summary.id,
                kind: .album,
                title: summary.title,
                artist: summary.artistName,
                album: summary.title,
                directArtworkURLString: summary.artworkURL?.absoluteString)
        }
    }

    private static func albumTitle(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown Album" : trimmed
    }

    private static func albumID(title: String, artistName: String) -> String {
        "artist-album:\(artistName):\(title)"
    }

    private static func firstMeaningfulArtist(
        in songs: [LocalMusicArtistAlbumSummaryInput]
    ) -> String {
        songs.first {
            !$0.artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.artistName ?? ""
    }

    private static func summarySort(
        _ lhs: LocalMusicArtistAlbumSummary,
        _ rhs: LocalMusicArtistAlbumSummary
    ) -> Bool {
        if lhs.title == "Unknown Album" { return false }
        if rhs.title == "Unknown Album" { return true }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

nonisolated enum LocalMusicPlaylistTrackArtworkLookup {
    static func lookupItem(
        title: String,
        artistName: String,
        albumTitle: String?,
        directArtworkURLString: String?
    ) -> LocalMusicCatalogArtworkLookupItem {
        LocalMusicCatalogArtworkLookupItem(
            id: storageID(title: title, artistName: artistName, albumTitle: albumTitle),
            kind: .song,
            title: clean(title),
            artist: clean(artistName),
            album: clean(albumTitle),
            directArtworkURLString: directArtworkURLString)
    }

    static func storageID(title: String, artistName: String, albumTitle: String?) -> String {
        [
            "playlist-track",
            storageComponent(artistName),
            storageComponent(albumTitle),
            storageComponent(title)
        ].joined(separator: ":")
    }

    static func selectedArtworkURL(
        trackArtworkURL: URL?,
        catalogArtworkURL: URL?,
        playlistArtworkURL _: URL?
    ) -> URL? {
        if let trackArtworkURL,
           let loadableTrackArtworkURL = LocalMusicArtworkURL.loadableURL(
               from: trackArtworkURL,
               shortSidePixels: 120
           ) {
            return loadableTrackArtworkURL
        }
        return catalogArtworkURL
    }

    private static func clean(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func storageComponent(_ value: String?) -> String {
        clean(value).lowercased()
    }
}
