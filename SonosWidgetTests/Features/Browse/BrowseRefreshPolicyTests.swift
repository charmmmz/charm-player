import XCTest
@testable import SonosWidget

final class BrowseRefreshPolicyTests: XCTestCase {
    func testBlockingLoaderOnlyShowsForInitialLoadWithoutCachedContent() {
        XCTAssertTrue(BrowseRefreshPolicy.showsBlockingLoader(isLoading: true, hasLoadedContent: false))
        XCTAssertFalse(BrowseRefreshPolicy.showsBlockingLoader(isLoading: true, hasLoadedContent: true))
        XCTAssertFalse(BrowseRefreshPolicy.showsBlockingLoader(isLoading: false, hasLoadedContent: false))
    }

    func testAutomaticLoadSkipsFreshCacheForSameSource() {
        let now = Date()

        XCTAssertTrue(BrowseRefreshPolicy.shouldSkipLoad(
            forceRefresh: false,
            isLoading: false,
            currentKey: "lan|192.168.1.10",
            lastLoadedKey: "lan|192.168.1.10",
            lastLoadedAt: now.addingTimeInterval(-60),
            now: now,
            cacheTTL: 300
        ))
    }

    func testManualLoadBypassesFreshCache() {
        let now = Date()

        XCTAssertFalse(BrowseRefreshPolicy.shouldSkipLoad(
            forceRefresh: true,
            isLoading: false,
            currentKey: "lan|192.168.1.10",
            lastLoadedKey: "lan|192.168.1.10",
            lastLoadedAt: now.addingTimeInterval(-60),
            now: now,
            cacheTTL: 300
        ))
    }

    func testAutomaticLoadDoesNotSkipExpiredOrDifferentSource() {
        let now = Date()

        XCTAssertFalse(BrowseRefreshPolicy.shouldSkipLoad(
            forceRefresh: false,
            isLoading: false,
            currentKey: "lan|192.168.1.20",
            lastLoadedKey: "lan|192.168.1.10",
            lastLoadedAt: now.addingTimeInterval(-60),
            now: now,
            cacheTTL: 300
        ))
        XCTAssertFalse(BrowseRefreshPolicy.shouldSkipLoad(
            forceRefresh: false,
            isLoading: false,
            currentKey: "lan|192.168.1.10",
            lastLoadedKey: "lan|192.168.1.10",
            lastLoadedAt: now.addingTimeInterval(-301),
            now: now,
            cacheTTL: 300
        ))
    }
}
