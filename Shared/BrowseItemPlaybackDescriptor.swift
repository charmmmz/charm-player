import Foundation

struct BrowseItemPlaybackDescriptor: Equatable, Sendable {
    let objectID: String
    let uri: String?
    let resourceMetadata: String?
    let cloudType: String?
    let serviceId: Int?
    let isContainer: Bool

    var directURI: String? {
        uri
    }

    var isPlayable: Bool {
        directURI != nil
    }

    var isQueueable: Bool {
        directURI != nil
    }

    var hasActionSurface: Bool {
        isPlayable || resourceMetadata != nil
    }

    func queuePayload(metadata: String) -> SonosQueuedURI? {
        payload(uri: directURI, metadata: metadata)
    }

    func transportPayload(metadata: String, fallbackURI: String? = nil) -> SonosQueuedURI? {
        payload(uri: directURI ?? Self.nonEmpty(fallbackURI), metadata: metadata)
    }

    private func payload(uri: String?, metadata: String) -> SonosQueuedURI? {
        guard let uri = Self.nonEmpty(uri) else { return nil }
        return SonosQueuedURI(uri: uri, metadata: metadata)
    }

    fileprivate static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PlaylistContainerPlaybackRoute: Equatable, Sendable {
    case container
    case displayedTracks
}

enum PlaylistContainerPlaybackPolicy {
    static func route(for item: BrowseItem, hasLoadedTracks: Bool) -> PlaylistContainerPlaybackRoute {
        if item.playbackDescriptor.isPlayable {
            return .container
        }
        return hasLoadedTracks ? .displayedTracks : .container
    }
}

extension BrowseItem {
    var playbackDescriptor: BrowseItemPlaybackDescriptor {
        BrowseItemPlaybackDescriptor(
            objectID: id,
            uri: BrowseItemPlaybackDescriptor.nonEmpty(uri),
            resourceMetadata: BrowseItemPlaybackDescriptor.nonEmpty(resMD),
            cloudType: BrowseItemPlaybackDescriptor.nonEmpty(cloudType),
            serviceId: serviceId,
            isContainer: isContainer
        )
    }
}
