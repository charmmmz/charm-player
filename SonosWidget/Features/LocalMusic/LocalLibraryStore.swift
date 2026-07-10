import Foundation
import MusicKit
import Observation

enum LocalLibraryRecommendationRefreshPolicy {
    static func shouldReplace(existingCount: Int, didLoadRecommendations: Bool) -> Bool {
        didLoadRecommendations || existingCount == 0
    }
}

enum LocalLibraryRefreshSource: String {
    case initial
    case pullToRefresh = "pull"
    case button
    case recovery
}

enum LocalLibraryRefreshExecutionPolicy {
    static func shouldDetachFromCallerCancellation(source: LocalLibraryRefreshSource) -> Bool {
        source == .pullToRefresh
    }
}

enum LocalLibraryHomeCachePolicy {
    static func shouldHydrateCachedContent(
        source: LocalLibraryRefreshSource,
        hasCachedContent: Bool
    ) -> Bool {
        source == .initial && hasCachedContent
    }

    static func shouldRefreshNetworkAfterHydratingCache(
        source: LocalLibraryRefreshSource
    ) -> Bool {
        source == .initial
    }
}

enum LocalLibraryHomeRefreshPolicy {
    static func snapshotLimit(for source: LocalLibraryRefreshSource) -> Int? {
        LocalMusicRecentlyAddedSelection.displayLimit
    }
}

struct LocalLibraryHomeContentCacheEntry: Codable {
    var content: LocalMusicHomeContent
    var recentlyAddedContent: LocalMusicRecentlyAddedContent
    var cachedAt: Date

    init(
        content: LocalMusicHomeContent,
        cachedAt: Date,
        recentlyAddedContent: LocalMusicRecentlyAddedContent = LocalMusicRecentlyAddedContent()
    ) {
        self.content = content
        self.recentlyAddedContent = recentlyAddedContent
        self.cachedAt = cachedAt
    }

    enum CodingKeys: String, CodingKey {
        case content
        case recentlyAddedContent
        case cachedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(LocalMusicHomeContent.self, forKey: .content)
        recentlyAddedContent = try container.decodeIfPresent(
            LocalMusicRecentlyAddedContent.self,
            forKey: .recentlyAddedContent
        ) ?? LocalMusicRecentlyAddedContent()
        cachedAt = try container.decode(Date.self, forKey: .cachedAt)
    }
}

enum LocalLibraryHomeContentCache {
    static let fileName = "local-library-home-content-cache-v2.json"

    static var defaultURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    static func load(from url: URL? = defaultURL) -> LocalLibraryHomeContentCacheEntry? {
        guard let url,
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(LocalLibraryHomeContentCacheEntry.self, from: data)
        } catch {
            SonosLog.debug(
                .localService,
                "Local library home cache decode failed url='\(url.path)' error=\(error)")
            return nil
        }
    }

    static func save(
        _ entry: LocalLibraryHomeContentCacheEntry,
        to url: URL? = defaultURL
    ) {
        guard let url else { return }

        do {
            let data = try JSONEncoder().encode(entry)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            SonosLog.debug(
                .localService,
                "Local library home cache save failed url='\(url.path)' error=\(error)")
        }
    }
}

struct LocalLibraryHomeContentApplicationOptions {
    let rebuildsRecentlyAddedContent: Bool
    let schedulesCatalogArtworkLookup: Bool

    static let liveRefresh = LocalLibraryHomeContentApplicationOptions(
        rebuildsRecentlyAddedContent: true,
        schedulesCatalogArtworkLookup: true
    )
    static let cachedRestore = LocalLibraryHomeContentApplicationOptions(
        rebuildsRecentlyAddedContent: false,
        schedulesCatalogArtworkLookup: false
    )
}

enum LocalLibraryPullRefreshPolicy {
    static let triggerDistance = 128.0
    static let resetDistance = 18.0

    static func shouldTrigger(
        pullDistance: Double,
        isRefreshing: Bool,
        hasLoaded: Bool,
        hasTriggeredInCurrentPull: Bool = false
    ) -> Bool {
        hasLoaded && !isRefreshing && !hasTriggeredInCurrentPull && pullDistance >= triggerDistance
    }

    static func shouldResetGesture(pullDistance: Double) -> Bool {
        pullDistance < resetDistance
    }

    static func indicatorOpacity(
        pullDistance: Double,
        isRefreshing: Bool
    ) -> Double {
        guard !isRefreshing else { return 1 }
        guard triggerDistance > 0 else { return 0 }
        return min(max(pullDistance / triggerDistance, 0), 1)
    }
}

@MainActor
@Observable
final class LocalLibraryStore {
    let client: LocalMusicLibraryClient
    let catalogSearchClient: AppleMusicCatalogSearchClient
    let catalogArtworkCache: LocalMusicCatalogArtworkCache
    static var cachedHomeContent = LocalLibraryHomeContentCache.load()

    var authorizationStatus = MusicAuthorization.currentStatus
    var snapshot = LocalMusicLibrarySnapshot()
    var recentlyAddedContent = LocalMusicRecentlyAddedContent()
    var recentlyPlayed: [RecentlyPlayedMusicItem] = []
    var recommendations: [MusicPersonalRecommendation] = []
    var searchSnapshot: LocalMusicLibrarySnapshot?
    var catalogSearchResults = LocalServiceCatalogSearchResults()
    var isLoading = false
    var isSearching = false
    var isStartingPlayback = false
    var activePlaybackItemID: String?
    var errorMessage: String?
    var hasLoaded = false
    var catalogArtworkURLStrings: [String: String] = [:]
    var loadingCategories: Set<LocalLibraryCategory> = []
    var librarySnapshotRevision = 0
    var searchSnapshotRevision = 0

    var displayedSnapshotToken: LocalLibraryDisplayedSnapshotToken {
        if searchSnapshot != nil {
            return LocalLibraryDisplayedSnapshotToken(
                source: .search,
                revision: searchSnapshotRevision)
        }
        return LocalLibraryDisplayedSnapshotToken(
            source: .library,
            revision: librarySnapshotRevision)
    }

    @ObservationIgnored var artworkLookupTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var catalogArtworkMissIDs: Set<String> = []
    @ObservationIgnored var catalogArtworkInFlightIDs: Set<String> = []
    @ObservationIgnored var loadedFullCategories: Set<LocalLibraryCategory> = []

    struct AppliedHomeContent {
        var content: LocalMusicHomeContent
        var recentlyAddedContent: LocalMusicRecentlyAddedContent
    }

    convenience init() {
        self.init(
            client: .shared,
            catalogSearchClient: AppleMusicCatalogSearchClient()
        )
    }

    init(
        client: LocalMusicLibraryClient,
        catalogSearchClient: AppleMusicCatalogSearchClient,
        catalogArtworkCache: LocalMusicCatalogArtworkCache = .shared
    ) {
        self.client = client
        self.catalogSearchClient = catalogSearchClient
        self.catalogArtworkCache = catalogArtworkCache
    }

    var displayedSnapshot: LocalMusicLibrarySnapshot {
        searchSnapshot ?? snapshot
    }

    var hasHomeContent: Bool {
        !snapshot.isEmpty || !recentlyPlayed.isEmpty || !recommendations.isEmpty
    }

    var summary: LocalLibrarySnapshotSummary {
        displayedSnapshot.summary
    }

    func itemsAreEmpty(for category: LocalLibraryCategory) -> Bool {
        summary.count(for: category) == 0
    }

    func isLoadingCategory(_ category: LocalLibraryCategory) -> Bool {
        loadingCategories.contains(category)
    }

}
