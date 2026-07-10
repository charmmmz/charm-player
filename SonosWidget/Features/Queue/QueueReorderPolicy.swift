import Foundation

nonisolated enum QueueReorderPolicy {
    static func reordered(_ queue: [QueueItem], from source: IndexSet, to destination: Int) -> [QueueItem] {
        normalizedTrackNumbers(moving(queue, from: source, to: destination))
    }

    static func playingNextQueue(_ queue: [QueueItem],
                                 itemID: String,
                                 afterCurrentItemID currentItemID: String) -> [QueueItem] {
        guard let itemIndex = queue.firstIndex(where: { $0.id == itemID }),
              let currentIndex = queue.firstIndex(where: { $0.id == currentItemID }),
              itemIndex != currentIndex else {
            return normalizedTrackNumbers(queue)
        }

        return reordered(queue, from: IndexSet(integer: itemIndex), to: currentIndex + 1)
    }

    static func confirmedQueue(_ remoteQueue: [QueueItem], preservingIDsFrom currentQueue: [QueueItem]) -> [QueueItem] {
        let preservedIDs = stableIDsByFingerprint(from: currentQueue)
        var remoteOccurrences: [String: Int] = [:]

        let merged = remoteQueue.map { item in
            let fingerprint = fingerprint(for: item)
            let occurrence = remoteOccurrences[fingerprint, default: 0]
            remoteOccurrences[fingerprint] = occurrence + 1

            var mergedItem = item
            if let ids = preservedIDs[fingerprint], ids.indices.contains(occurrence) {
                mergedItem.id = ids[occurrence]
            } else {
                mergedItem.id = stableID(for: item, occurrence: occurrence)
            }
            return mergedItem
        }

        return normalizedTrackNumbers(merged)
    }

    static func stableID(for item: QueueItem, occurrence: Int) -> String {
        "queue-item|\(occurrence)|\(fingerprint(for: item))"
    }

    private static func normalizedTrackNumbers(_ queue: [QueueItem]) -> [QueueItem] {
        queue.enumerated().map { index, item in
            var normalized = item
            normalized.trackNumber = index + 1
            return normalized
        }
    }

    private static func moving(_ queue: [QueueItem], from source: IndexSet, to destination: Int) -> [QueueItem] {
        let offsets = source.sorted()
        guard !offsets.isEmpty else { return queue }

        let movingItems = offsets.compactMap { index in
            queue.indices.contains(index) ? queue[index] : nil
        }
        guard !movingItems.isEmpty else { return queue }

        var remaining = queue
        for index in offsets.reversed() where remaining.indices.contains(index) {
            remaining.remove(at: index)
        }

        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = max(0, min(destination - removedBeforeDestination, remaining.count))
        remaining.insert(contentsOf: movingItems, at: insertionIndex)
        return remaining
    }

    private static func stableIDsByFingerprint(from queue: [QueueItem]) -> [String: [String]] {
        queue.reduce(into: [:]) { result, item in
            result[fingerprint(for: item), default: []].append(item.id)
        }
    }

    private static func fingerprint(for item: QueueItem) -> String {
        if let uri = normalized(item.uri) {
            return "uri:\(component(uri))"
        }

        let metadataParts = [
            normalized(item.title),
            normalized(item.artist),
            normalized(item.album),
            normalized(item.albumArtURL)
        ].compactMap { $0 }

        if !metadataParts.isEmpty {
            let title = normalized(item.title) ?? ""
            let artist = normalized(item.artist) ?? ""
            let album = normalized(item.album) ?? ""
            let albumArtURL = normalized(item.albumArtURL) ?? ""

            return [
                "title:\(component(title))",
                "artist:\(component(artist))",
                "album:\(component(album))",
                "art:\(component(albumArtURL))"
            ].joined(separator: "|")
        }

        return "object:\(component(item.objectID))"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func component(_ value: String) -> String {
        "\(value.count):\(value)"
    }
}
