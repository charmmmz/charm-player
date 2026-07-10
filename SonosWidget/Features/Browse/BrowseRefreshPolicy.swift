import Foundation

nonisolated enum BrowseRefreshPolicy {
    static let cacheTTL: TimeInterval = 5 * 60

    static func showsBlockingLoader(isLoading: Bool, hasLoadedContent: Bool) -> Bool {
        isLoading && !hasLoadedContent
    }

    static func shouldSkipLoad(
        forceRefresh: Bool,
        isLoading: Bool,
        currentKey: String?,
        lastLoadedKey: String?,
        lastLoadedAt: Date?,
        now: Date = Date(),
        cacheTTL: TimeInterval = Self.cacheTTL
    ) -> Bool {
        if isLoading { return true }
        guard !forceRefresh,
              let currentKey,
              let lastLoadedKey,
              currentKey == lastLoadedKey,
              let lastLoadedAt else {
            return false
        }

        return now.timeIntervalSince(lastLoadedAt) < cacheTTL
    }
}
