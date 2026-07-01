import XCTest
@testable import SonosWidget

final class LocalLibraryModelsTests: XCTestCase {
    func testCategoriesExposeStableTitlesAndSymbols() {
        XCTAssertEqual(LocalLibraryCategory.songs.title, "Songs")
        XCTAssertEqual(LocalLibraryCategory.songs.systemImage, "music.note")
        XCTAssertEqual(LocalLibraryCategory.albums.title, "Albums")
        XCTAssertEqual(LocalLibraryCategory.albums.systemImage, "square.stack")
        XCTAssertEqual(LocalLibraryCategory.artists.title, "Artists")
        XCTAssertEqual(LocalLibraryCategory.artists.systemImage, "music.mic")
        XCTAssertEqual(LocalLibraryCategory.playlists.title, "Playlists")
        XCTAssertEqual(LocalLibraryCategory.playlists.systemImage, "music.note.list")
    }

    func testLibraryHomeOrderMatchesAppleMusicStyleEntryList() {
        XCTAssertEqual(LocalLibraryCategory.homeOrder, [
            .playlists,
            .artists,
            .albums,
            .songs
        ])
    }

    func testAlphabetIndexIsHiddenOnlyForPlaylists() {
        XCTAssertFalse(LocalLibraryCategory.playlists.showsAlphabetIndex)
        XCTAssertTrue(LocalLibraryCategory.artists.showsAlphabetIndex)
        XCTAssertTrue(LocalLibraryCategory.albums.showsAlphabetIndex)
        XCTAssertTrue(LocalLibraryCategory.songs.showsAlphabetIndex)
    }

    func testLibrarySectionIndexUsesLeadingLettersAndNumbers() {
        XCTAssertEqual(LocalLibrarySectionIndex.indexTitle(for: "  15 Step"), "#")
        XCTAssertEqual(LocalLibrarySectionIndex.indexTitle(for: "Élan"), "E")
        XCTAssertEqual(LocalLibrarySectionIndex.indexTitle(for: "zebra"), "Z")
        XCTAssertEqual(LocalLibrarySectionIndex.indexTitle(for: "   "), "#")

        XCTAssertEqual(
            LocalLibrarySectionIndex.indexTitles(for: ["zebra", "Élan", "15 Step", "apple"]),
            ["#", "A", "E", "Z"]
        )
    }

    func testSnapshotSummaryIsEmptyOnlyWhenAllSectionsAreEmpty() {
        XCTAssertTrue(
            LocalLibrarySnapshotSummary(
                songCount: 0,
                albumCount: 0,
                artistCount: 0,
                playlistCount: 0
            ).isEmpty
        )

        XCTAssertFalse(
            LocalLibrarySnapshotSummary(
                songCount: 1,
                albumCount: 0,
                artistCount: 0,
                playlistCount: 0
            ).isEmpty
        )
    }

    func testSnapshotSummaryReturnsCountsByCategory() {
        let summary = LocalLibrarySnapshotSummary(
            songCount: 7,
            albumCount: 3,
            artistCount: 2,
            playlistCount: 5
        )

        XCTAssertEqual(summary.count(for: .songs), 7)
        XCTAssertEqual(summary.count(for: .albums), 3)
        XCTAssertEqual(summary.count(for: .artists), 2)
        XCTAssertEqual(summary.count(for: .playlists), 5)
        XCTAssertEqual(summary.totalCount, 17)
    }

    func testLocalServiceSectionsExposeStableLabels() {
        XCTAssertEqual(LocalServiceSectionKind.recentlyAdded.title, "Recently Added")
        XCTAssertEqual(LocalServiceSectionKind.recentlyAdded.systemImage, "clock.badge.plus")
        XCTAssertNil(LocalServiceSectionKind.recentlyAdded.headerSystemImage)
        XCTAssertEqual(LocalServiceSectionKind.recentlyPlayed.title, "Recently Played")
        XCTAssertEqual(LocalServiceSectionKind.recentlyPlayed.systemImage, "clock.arrow.circlepath")
        XCTAssertNil(LocalServiceSectionKind.recentlyPlayed.headerSystemImage)
        XCTAssertEqual(LocalServiceSectionKind.recommendations.title, "For You")
        XCTAssertEqual(LocalServiceSectionKind.recommendations.systemImage, "sparkles")
        XCTAssertNil(LocalServiceSectionKind.recommendations.headerSystemImage)
        XCTAssertEqual(LocalServiceSectionKind.library.title, "Your Library")
        XCTAssertEqual(LocalServiceSectionKind.library.systemImage, "music.note.list")
        XCTAssertNil(LocalServiceSectionKind.library.headerSystemImage)
    }

    func testRecentlyAddedSelectionSortsNewestDatedItemsBeforeUndatedItems() {
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let candidates = [
            LocalMusicRecentlyAddedCandidate(
                date: nil,
                title: "Alpha",
                item: "undated-alpha"),
            LocalMusicRecentlyAddedCandidate(
                date: baseDate.addingTimeInterval(20),
                title: "Newest",
                item: "newest"),
            LocalMusicRecentlyAddedCandidate(
                date: baseDate,
                title: "Oldest",
                item: "oldest"),
            LocalMusicRecentlyAddedCandidate(
                date: nil,
                title: "Beta",
                item: "undated-beta")
        ]

        XCTAssertEqual(
            LocalMusicRecentlyAddedSelection.select(candidates),
            ["newest", "oldest", "undated-alpha", "undated-beta"])
    }

    func testRecentlyAddedSelectionLimitsItemsBeforeRendering() {
        let candidates = (0..<24).map { index in
            LocalMusicRecentlyAddedCandidate(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                title: "Item \(index)",
                item: index)
        }

        let selected = LocalMusicRecentlyAddedSelection.select(candidates)

        XCTAssertEqual(selected.count, LocalMusicRecentlyAddedSelection.displayLimit)
        XCTAssertEqual(selected.first, 23)
        XCTAssertEqual(selected.last, 8)
    }

    func testRecommendationRefreshPolicyPreservesExistingSectionsWhenReloadSkipsRecommendations() {
        XCTAssertFalse(
            LocalLibraryRecommendationRefreshPolicy.shouldReplace(
                existingCount: 3,
                didLoadRecommendations: false))
    }

    func testRecommendationRefreshPolicyReplacesWhenRecommendationsLoadSuccessfully() {
        XCTAssertTrue(
            LocalLibraryRecommendationRefreshPolicy.shouldReplace(
                existingCount: 3,
                didLoadRecommendations: true))
    }

    func testRecommendationRefreshPolicyAllowsInitialEmptyStateWhenRecommendationsFail() {
        XCTAssertTrue(
            LocalLibraryRecommendationRefreshPolicy.shouldReplace(
                existingCount: 0,
                didLoadRecommendations: false))
    }

    func testPullToRefreshDetachesFromCallerCancellation() {
        XCTAssertTrue(
            LocalLibraryRefreshExecutionPolicy.shouldDetachFromCallerCancellation(
                source: .pullToRefresh))
    }

    func testButtonRefreshUsesNormalTaskEntryPoint() {
        XCTAssertFalse(
            LocalLibraryRefreshExecutionPolicy.shouldDetachFromCallerCancellation(
                source: .button))
    }

    func testHomeCachePolicyOnlyHydratesInitialLoads() {
        XCTAssertTrue(
            LocalLibraryHomeCachePolicy.shouldHydrateCachedContent(
                source: .initial,
                hasCachedContent: true))

        XCTAssertFalse(
            LocalLibraryHomeCachePolicy.shouldHydrateCachedContent(
                source: .pullToRefresh,
                hasCachedContent: true))

        XCTAssertFalse(
            LocalLibraryHomeCachePolicy.shouldHydrateCachedContent(
                source: .initial,
                hasCachedContent: false))
    }

    func testHomeCachePolicyRefreshesNetworkAfterHydratingInitialCache() {
        XCTAssertTrue(
            LocalLibraryHomeCachePolicy.shouldRefreshNetworkAfterHydratingCache(
                source: .initial))

        XCTAssertFalse(
            LocalLibraryHomeCachePolicy.shouldRefreshNetworkAfterHydratingCache(
                source: .pullToRefresh))

        XCTAssertFalse(
            LocalLibraryHomeCachePolicy.shouldRefreshNetworkAfterHydratingCache(
                source: .button))
    }

    func testHomeRefreshPolicyLimitsSnapshotToVisibleHomeWindow() {
        XCTAssertEqual(
            LocalLibraryHomeRefreshPolicy.snapshotLimit(for: .initial),
            LocalMusicRecentlyAddedSelection.displayLimit)
        XCTAssertEqual(
            LocalLibraryHomeRefreshPolicy.snapshotLimit(for: .pullToRefresh),
            LocalMusicRecentlyAddedSelection.displayLimit)
        XCTAssertEqual(
            LocalLibraryHomeRefreshPolicy.snapshotLimit(for: .button),
            LocalMusicRecentlyAddedSelection.displayLimit)
    }

    func testCachedHomeContentApplicationSkipsExpensiveMainThreadWork() {
        XCTAssertFalse(LocalLibraryHomeContentApplicationOptions.cachedRestore.rebuildsRecentlyAddedContent)
        XCTAssertFalse(LocalLibraryHomeContentApplicationOptions.cachedRestore.schedulesCatalogArtworkLookup)
        XCTAssertTrue(LocalLibraryHomeContentApplicationOptions.liveRefresh.rebuildsRecentlyAddedContent)
        XCTAssertTrue(LocalLibraryHomeContentApplicationOptions.liveRefresh.schedulesCatalogArtworkLookup)
    }

    func testHomeContentCachePersistsEntry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-library-home-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = LocalLibraryHomeContentCacheEntry(
            content: LocalMusicHomeContent(),
            cachedAt: Date(timeIntervalSince1970: 1_000))

        LocalLibraryHomeContentCache.save(entry, to: url)

        let loaded = try XCTUnwrap(LocalLibraryHomeContentCache.load(from: url))
        XCTAssertEqual(
            loaded.cachedAt.timeIntervalSince1970,
            entry.cachedAt.timeIntervalSince1970,
            accuracy: 0.001)
        XCTAssertTrue(loaded.content.isEmpty)
        XCTAssertEqual(loaded.content.recommendationsLoadStatus, .loaded)
    }

    func testPullRefreshPolicyTriggersOnlyPastThresholdWhenLoadedAndIdle() {
        XCTAssertEqual(LocalLibraryPullRefreshPolicy.triggerDistance, 128)

        XCTAssertFalse(
            LocalLibraryPullRefreshPolicy.shouldTrigger(
                pullDistance: 96,
                isRefreshing: false,
                hasLoaded: true))

        XCTAssertTrue(
            LocalLibraryPullRefreshPolicy.shouldTrigger(
                pullDistance: LocalLibraryPullRefreshPolicy.triggerDistance + 1,
                isRefreshing: false,
                hasLoaded: true))

        XCTAssertFalse(
            LocalLibraryPullRefreshPolicy.shouldTrigger(
                pullDistance: LocalLibraryPullRefreshPolicy.triggerDistance - 1,
                isRefreshing: false,
                hasLoaded: true))

        XCTAssertFalse(
            LocalLibraryPullRefreshPolicy.shouldTrigger(
                pullDistance: LocalLibraryPullRefreshPolicy.triggerDistance + 1,
                isRefreshing: true,
                hasLoaded: true))

        XCTAssertFalse(
            LocalLibraryPullRefreshPolicy.shouldTrigger(
                pullDistance: LocalLibraryPullRefreshPolicy.triggerDistance + 1,
                isRefreshing: false,
                hasLoaded: false))
    }

    func testPullRefreshPolicyDoesNotRetriggerDuringSamePullGesture() {
        XCTAssertFalse(
            LocalLibraryPullRefreshPolicy.shouldTrigger(
                pullDistance: LocalLibraryPullRefreshPolicy.triggerDistance + 1,
                isRefreshing: false,
                hasLoaded: true,
                hasTriggeredInCurrentPull: true))
    }

    func testPullRefreshPolicyResetsOnlyAfterReturningNearTop() {
        XCTAssertLessThan(
            LocalLibraryPullRefreshPolicy.resetDistance,
            LocalLibraryPullRefreshPolicy.triggerDistance)

        XCTAssertFalse(
            LocalLibraryPullRefreshPolicy.shouldResetGesture(
                pullDistance: LocalLibraryPullRefreshPolicy.resetDistance + 1))

        XCTAssertTrue(
            LocalLibraryPullRefreshPolicy.shouldResetGesture(
                pullDistance: LocalLibraryPullRefreshPolicy.resetDistance - 1))
    }

    func testPullRefreshIndicatorOpacityTracksPullDistance() {
        XCTAssertEqual(
            LocalLibraryPullRefreshPolicy.indicatorOpacity(
                pullDistance: 0,
                isRefreshing: false),
            0,
            accuracy: 0.001)

        XCTAssertEqual(
            LocalLibraryPullRefreshPolicy.indicatorOpacity(
                pullDistance: LocalLibraryPullRefreshPolicy.triggerDistance / 2,
                isRefreshing: false),
            0.5,
            accuracy: 0.001)

        XCTAssertEqual(
            LocalLibraryPullRefreshPolicy.indicatorOpacity(
                pullDistance: 0,
                isRefreshing: true),
            1,
            accuracy: 0.001)
    }

    func testMusicResourcePresentationUsesOneTapIdentityForCardRegions() {
        let resource = MusicResourcePresentation(
            id: "recommendation-playlist-pl.heavy",
            kind: .playlist,
            title: "Heavy Rotation",
            subtitle: "Apple Music for Charm",
            detail: nil,
            fallbackSystemImage: "music.note.list",
            accessory: .chevron,
            isQueueable: true
        )

        XCTAssertEqual(resource.artworkTapID, resource.id)
        XCTAssertEqual(resource.titleTapID, resource.id)
    }

    func testMusicResourcePresentationMapsBrowseItemKindFromCloudType() {
        let item = BrowseItem(
            id: "playlist:pl.new",
            title: "New Music",
            artist: "Apple Music",
            album: "",
            albumArtURL: nil,
            uri: "x-rincon-cpcontainer:1006206c playlist%3Apl.new?sid=204&sn=2",
            isContainer: true,
            serviceId: 204,
            cloudType: "PLAYLIST"
        )

        let resource = MusicResourcePresentation.fromBrowseItem(
            item,
            fallbackSystemImage: "music.note.list",
            accessory: .chevron
        )

        XCTAssertEqual(resource.id, "playlist:pl.new")
        XCTAssertEqual(resource.kind, .playlist)
        XCTAssertEqual(resource.title, "New Music")
        XCTAssertEqual(resource.subtitle, "Apple Music")
        XCTAssertTrue(resource.isQueueable)
    }
}
