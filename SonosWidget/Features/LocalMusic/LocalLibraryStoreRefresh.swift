import Foundation
import MusicKit
import Observation

extension LocalLibraryStore {

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh(source: .initial)
    }

    func reload() async {
        await refresh(source: .button)
    }

    func refresh(source: LocalLibraryRefreshSource) async {
        if LocalLibraryRefreshExecutionPolicy.shouldDetachFromCallerCancellation(source: source) {
            let task = Task { [weak self] in
                await self?.performReload(source: source)
            }
            await task.value
            return
        }

        await performReload(source: source)
    }

    func performReload(source: LocalLibraryRefreshSource) async {
        let canRestoreCachedHomeContent = MusicAuthorization.currentStatus == .authorized
        var didHydrateCachedContent = false
        if let cached = Self.cachedHomeContent,
           LocalLibraryHomeCachePolicy.shouldHydrateCachedContent(
                source: source,
                hasCachedContent: canRestoreCachedHomeContent && !cached.content.isEmpty
           ) {
            applyHomeContent(
                cached.content,
                source: source,
                options: .cachedRestore,
                cachedRecentlyAddedContent: cached.recentlyAddedContent)
            didHydrateCachedContent = true
            if !LocalLibraryHomeCachePolicy.shouldRefreshNetworkAfterHydratingCache(source: source) {
                return
            }
        }

        if didHydrateCachedContent {
            await Task.yield()
        }

        cancelCatalogArtworkLookupTasks()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            SonosLog.info(
                .localService,
                "Local library refresh start source=\(source.rawValue) existingRecommendations=\(recommendations.count)")

            authorizationStatus = try await client.authorize()
            let content = try await client.loadHomeContent(
                snapshotLimit: LocalLibraryHomeRefreshPolicy.snapshotLimit(for: source))
            let appliedHomeContent = applyHomeContent(
                content,
                source: source,
                options: .liveRefresh)
            let cacheEntry = LocalLibraryHomeContentCacheEntry(
                content: appliedHomeContent.content,
                cachedAt: Date(),
                recentlyAddedContent: appliedHomeContent.recentlyAddedContent)
            Self.cachedHomeContent = cacheEntry
            LocalLibraryHomeContentCache.save(cacheEntry)
            loadedFullCategories = []
            SonosLog.info(
                .localService,
                "Local library refresh resolved source=\(source.rawValue) " +
                    "songs=\(snapshot.songs.count) albums=\(snapshot.albums.count) " +
                    "artists=\(snapshot.artists.count) playlists=\(snapshot.playlists.count) " +
                    "recentlyPlayed=\(recentlyPlayed.count) " +
                    "recommendationsStatus=\(content.recommendationsLoadStatus.diagnosticDescription) " +
                    "recommendations=\(recommendations.count)")
        } catch {
            authorizationStatus = MusicAuthorization.currentStatus
            errorMessage = displayMessage(for: error)
            SonosLog.error(
                .localService,
                "Local library refresh failed source=\(source.rawValue) error=\(type(of: error)): \(error)")
        }
    }

    func loadCategoryIfNeeded(_ category: LocalLibraryCategory) async {
        guard !loadedFullCategories.contains(category),
              !loadingCategories.contains(category) else {
            return
        }

        loadingCategories.insert(category)
        defer { loadingCategories.remove(category) }

        do {
            authorizationStatus = try await client.authorize()
            let categorySnapshot = try await client.loadCategorySnapshot(category)
            applyCategorySnapshot(categorySnapshot, for: category)
            loadedFullCategories.insert(category)
        } catch {
            authorizationStatus = MusicAuthorization.currentStatus
            errorMessage = displayMessage(for: error)
            SonosLog.error(
                .localService,
                "Local library category load failed category=\(category.rawValue) error=\(type(of: error)): \(error)")
        }
    }

    @discardableResult
    func applyHomeContent(
        _ content: LocalMusicHomeContent,
        source: LocalLibraryRefreshSource,
        options: LocalLibraryHomeContentApplicationOptions,
        cachedRecentlyAddedContent: LocalMusicRecentlyAddedContent? = nil
    ) -> AppliedHomeContent {
        let shouldReplaceRecommendations = LocalLibraryRecommendationRefreshPolicy.shouldReplace(
            existingCount: recommendations.count,
            didLoadRecommendations: content.recommendationsLoaded)
        let nextRecommendations = shouldReplaceRecommendations
            ? content.recommendations
            : recommendations
        var appliedContent = content
        appliedContent.recommendations = nextRecommendations
        let nextRecentlyAddedContent = options.rebuildsRecentlyAddedContent
            ? LocalMusicRecentlyAddedContent(snapshot: content.snapshot)
            : cachedRecentlyAddedContent ?? LocalMusicRecentlyAddedContent()

        if !shouldReplaceRecommendations {
            SonosLog.info(
                .localService,
                "Keeping \(recommendations.count) existing recommendation sections after refresh skipped recommendations " +
                    "source=\(source.rawValue) status=\(content.recommendationsLoadStatus.diagnosticDescription)")
        }

        snapshot = content.snapshot
        librarySnapshotRevision += 1
        recentlyAddedContent = nextRecentlyAddedContent
        recentlyPlayed = content.recentlyPlayed
        recommendations = nextRecommendations
        searchSnapshot = nil
        catalogSearchResults = LocalServiceCatalogSearchResults()
        catalogArtworkURLStrings = [:]
        catalogArtworkMissIDs = []
        catalogArtworkInFlightIDs = []
        hasLoaded = true
        if options.schedulesCatalogArtworkLookup {
            scheduleCatalogArtworkLookup(
                for: appliedContent,
                recentlyAddedContent: nextRecentlyAddedContent)
        }
        return AppliedHomeContent(
            content: appliedContent,
            recentlyAddedContent: nextRecentlyAddedContent)
    }

    func applyCategorySnapshot(
        _ categorySnapshot: LocalMusicLibrarySnapshot,
        for category: LocalLibraryCategory
    ) {
        switch category {
        case .songs:
            snapshot.songs = categorySnapshot.songs
        case .albums:
            snapshot.albums = categorySnapshot.albums
        case .artists:
            snapshot.artists = categorySnapshot.artists
        case .playlists:
            snapshot.playlists = categorySnapshot.playlists
        }
        librarySnapshotRevision += 1
    }

}
