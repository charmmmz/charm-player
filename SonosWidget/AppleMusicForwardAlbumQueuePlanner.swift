import Foundation

struct AppleMusicForwardAlbumTrackCandidate: Equatable, Sendable {
    let item: BrowseItem
    let ordinal: Int?
}

struct AppleMusicForwardAlbumQueuePlan: Equatable, Sendable {
    let items: [BrowseItem]
    let targetTrackNumber: Int
    let skippedUnsupportedItemCount: Int

    var transferredTrackCount: Int { items.count }
}

enum AppleMusicForwardAlbumQueuePlanner {
    static let defaultMaxItems = 50

    static func isSupportedAlbumTrackType(itemType: String?, resourceType: String?) -> Bool {
        let normalizedItemType = normalizedType(itemType)
        let normalizedResourceType = normalizedType(resourceType)

        switch normalizedItemType {
        case nil:
            return normalizedResourceType == nil || normalizedResourceType == "TRACK"
        case "TRACK":
            return true
        case "ITEM_TRACK":
            return normalizedResourceType == "TRACK"
        default:
            return false
        }
    }

    static func makePlan(
        albumTracks: [AppleMusicForwardAlbumTrackCandidate],
        matchedItem: BrowseItem,
        sourceTrack: AppleMusicHandoffTrack,
        matchedOrdinal: Int? = nil,
        maxItems: Int = defaultMaxItems
    ) -> AppleMusicForwardAlbumQueuePlan? {
        guard maxItems > 0 else { return nil }
        let limitedTracks = Array(albumTracks.prefix(maxItems))
        guard !limitedTracks.isEmpty else { return nil }

        guard let targetOriginalIndex = targetIndex(
            in: limitedTracks,
            matchedItem: matchedItem,
            sourceTrack: sourceTrack,
            matchedOrdinal: matchedOrdinal)
        else { return nil }

        var playable: [(originalIndex: Int, item: BrowseItem)] = []
        var skipped = 0
        for (index, candidate) in limitedTracks.enumerated() {
            if isPlayable(candidate.item) {
                playable.append((index, candidate.item))
            } else {
                skipped += 1
            }
        }

        guard let targetPlayableIndex = playable.firstIndex(where: { $0.originalIndex == targetOriginalIndex }) else {
            return nil
        }

        return AppleMusicForwardAlbumQueuePlan(
            items: playable.map(\.item),
            targetTrackNumber: targetPlayableIndex + 1,
            skippedUnsupportedItemCount: skipped)
    }

    private static func targetIndex(
        in tracks: [AppleMusicForwardAlbumTrackCandidate],
        matchedItem: BrowseItem,
        sourceTrack: AppleMusicHandoffTrack,
        matchedOrdinal: Int?
    ) -> Int? {
        let matchedID = trimmed(matchedItem.id)
        if !matchedID.isEmpty,
           let index = tracks.firstIndex(where: { trimmed($0.item.id) == matchedID }) {
            return index
        }

        if let matchedStoreID = storeID(from: matchedItem),
           let index = tracks.firstIndex(where: { storeID(from: $0.item) == matchedStoreID }) {
            return index
        }

        let metadataMatches = tracks.indices.filter {
            Self.metadataMatches(tracks[$0].item, sourceTrack: sourceTrack)
        }
        if metadataMatches.count == 1 {
            return metadataMatches[0]
        }

        if let matchedOrdinal {
            let ordinalMatches = tracks.indices.filter { tracks[$0].ordinal == matchedOrdinal }
            if ordinalMatches.count == 1 {
                return ordinalMatches[0]
            }
        }

        return nil
    }

    private static func metadataMatches(
        _ item: BrowseItem,
        sourceTrack: AppleMusicHandoffTrack
    ) -> Bool {
        let itemTitle = HandoffMatcher.normalized(item.title)
        let sourceTitle = HandoffMatcher.normalized(sourceTrack.title)
        guard !itemTitle.isEmpty, itemTitle == sourceTitle else { return false }

        let itemArtist = HandoffMatcher.normalized(item.artist)
        let sourceArtist = HandoffMatcher.normalized(sourceTrack.artist)
        guard sourceArtist.isEmpty || itemArtist.isEmpty || itemArtist == sourceArtist else {
            return false
        }

        if let sourceDuration = sourceTrack.duration,
           sourceDuration > 0,
           item.duration > 0 {
            return abs(sourceDuration - item.duration) <= 8
        }

        return true
    }

    private static func isPlayable(_ item: BrowseItem) -> Bool {
        item.playbackDescriptor.isQueueable && item.cloudType == "TRACK"
    }

    private static func storeID(from item: BrowseItem) -> String? {
        SonosAppleMusicTrackResolver.storeID(fromTrackURI: item.playbackDescriptor.directURI)
            ?? SonosAppleMusicTrackResolver.storeID(fromObjectID: item.id)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedType(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue.uppercased()
    }
}
