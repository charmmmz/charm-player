import Foundation

private struct PendingAppleMusicSharePayload: Codable {
    let id: UUID
    let urlString: String
    let receivedAt: Date
}

struct ShareRecentlyPlayedBrowseItem: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var albumArtURL: String?
    var detailArtworkURL: String?
    var uri: String?
    var metaXML: String?
    var duration: TimeInterval
    var resMD: String?
    var isContainer: Bool
    var serviceId: Int?
    var cloudType: String?
    var includeAlbumArtInCloudMetadata: Bool
    var cloudFavoriteId: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case albumArtURL
        case detailArtworkURL
        case uri
        case metaXML
        case duration
        case resMD
        case isContainer
        case serviceId
        case cloudType
        case includeAlbumArtInCloudMetadata
        case cloudFavoriteId
    }

    init(
        playable: ShareAppleMusicPlayable,
        credential: ShareAppleMusicSonosCredential
    ) {
        id = playable.sonosObjectID
        title = playable.title
        artist = playable.artist
        album = playable.album
        albumArtURL = playable.artworkURLString
        detailArtworkURL = playable.artworkURLString
        uri = Self.playableURI(playable: playable, credential: credential)
        metaXML = nil
        duration = playable.duration ?? 0
        resMD = nil
        isContainer = playable.kind == .album || playable.kind == .playlist
        serviceId = credential.localServiceId
        cloudType = playable.cloudType
        includeAlbumArtInCloudMetadata = true
        cloudFavoriteId = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decode(String.self, forKey: .album)
        albumArtURL = try container.decodeIfPresent(String.self, forKey: .albumArtURL)
        detailArtworkURL = try container.decodeIfPresent(String.self, forKey: .detailArtworkURL)
        uri = try container.decodeIfPresent(String.self, forKey: .uri)
        metaXML = try container.decodeIfPresent(String.self, forKey: .metaXML)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        resMD = try container.decodeIfPresent(String.self, forKey: .resMD)
        isContainer = try container.decode(Bool.self, forKey: .isContainer)
        serviceId = try container.decodeIfPresent(Int.self, forKey: .serviceId)
        cloudType = try container.decodeIfPresent(String.self, forKey: .cloudType)
        includeAlbumArtInCloudMetadata = try container.decodeIfPresent(
            Bool.self,
            forKey: .includeAlbumArtInCloudMetadata
        ) ?? true
        cloudFavoriteId = try container.decodeIfPresent(String.self, forKey: .cloudFavoriteId)
    }

    private static func playableURI(
        playable: ShareAppleMusicPlayable,
        credential: ShareAppleMusicSonosCredential
    ) -> String {
        let encodedObjectID = playable.sonosObjectID.replacingOccurrences(of: ":", with: "%3a")
        let sid = credential.localServiceId
        let accountID = credential.accountId

        switch playable.cloudType {
        case "TRACK":
            return "x-sonos-http:\(encodedObjectID).mp4?sid=\(sid)&flags=8232&sn=\(accountID)"
        case "ALBUM":
            return "x-rincon-cpcontainer:1004206c\(encodedObjectID)?sid=\(sid)&flags=8300&sn=\(accountID)"
        case "PLAYLIST":
            return "x-rincon-cpcontainer:1006206c\(encodedObjectID)?sid=\(sid)&flags=8300&sn=\(accountID)"
        case "ARTIST":
            return "x-rincon-cpcontainer:\(encodedObjectID)?sid=\(sid)&flags=8300&sn=\(accountID)"
        default:
            return ""
        }
    }
}

enum AppleMusicShareExtensionStore {
    private static let appGroupID = "group.com.charm.SonosWidget"
    private static let pendingShareKey = "pendingAppleMusicShare"
    private static let savedSpeakersKey = "savedSpeakers"
    private static let speakerIDKey = "speakerID"
    private static let speakerIPKey = "speakerIP"
    private static let speakerNameKey = "speakerName"
    private static let coordinatorIPKey = "coordinatorIP"
    private static let speakerOrderKey = "homeSpeakerGroupOrder"
    private static let appleMusicCredentialKey = "appleMusicSonosServiceCredential"
    private static let recentlyPlayedKey = "RecentlyPlayedItems"
    private static let recentlyPlayedLimit = 20

    enum StoreError: LocalizedError {
        case missingAppleMusicURL
        case appGroupUnavailable
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .missingAppleMusicURL:
                return "This share does not contain a supported Apple Music link."
            case .appGroupUnavailable:
                return "Charm Player could not access shared app storage."
            case .encodingFailed:
                return "Charm Player could not save this Apple Music link."
            }
        }
    }

    static func saveFirstAppleMusicURL(from value: String) throws -> String {
        guard let urlString = firstAppleMusicURLString(in: value) else {
            throw StoreError.missingAppleMusicURL
        }
        guard let defaults else {
            throw StoreError.appGroupUnavailable
        }

        let payload = PendingAppleMusicSharePayload(
            id: UUID(),
            urlString: urlString,
            receivedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            throw StoreError.encodingFailed
        }

        defaults.set(data, forKey: pendingShareKey)
        return urlString
    }

    static func clearPendingAppleMusicShare() {
        defaults?.removeObject(forKey: pendingShareKey)
    }

    @discardableResult
    static func recordRecentlyPlayed(
        _ playable: ShareAppleMusicPlayable,
        credential: ShareAppleMusicSonosCredential
    ) -> Bool {
        guard let defaults else { return false }
        let item = ShareRecentlyPlayedBrowseItem(
            playable: playable,
            credential: credential)
        guard !item.id.isEmpty, !item.title.isEmpty else { return false }

        var items = recentlyPlayedItems(from: defaults)
        items.removeAll { existing in
            existing.id == item.id ||
            (existing.title == item.title && existing.artist == item.artist)
        }
        items.insert(item, at: 0)
        if items.count > recentlyPlayedLimit {
            items = Array(items.prefix(recentlyPlayedLimit))
        }

        guard let data = try? JSONEncoder().encode(items) else { return false }
        defaults.set(data, forKey: recentlyPlayedKey)
        return true
    }

    static var appleMusicCredential: ShareAppleMusicSonosCredential? {
        guard let data = defaults?.data(forKey: appleMusicCredentialKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ShareAppleMusicSonosCredential.self, from: data)
    }

    static var cachedSpeakerGroups: [ShareSpeakerGroup] {
        let speakers = savedSpeakers
        let groups = speakerGroups(from: speakers)
        guard !groups.isEmpty else {
            return recentSelectedSpeakerFallback().map {
                [ShareSpeakerGroup(id: $0.groupId ?? $0.id, coordinator: $0, members: [$0])]
            } ?? []
        }
        return sorted(groups)
    }

    static func refreshedSpeakerGroups() async -> [ShareSpeakerGroup] {
        let entryIP = defaults?.string(forKey: coordinatorIPKey)
            ?? defaults?.string(forKey: speakerIPKey)
            ?? savedSpeakers.first?.playbackIP
        guard let entryIP, !entryIP.isEmpty,
              let speakers = try? await ShareSonosAPI.getZoneGroupState(ip: entryIP),
              !speakers.isEmpty else {
            return cachedSpeakerGroups
        }
        return sorted(speakerGroups(from: speakers))
    }

    static func firstAppleMusicURLString(in value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directURL = sanitizedURL(from: trimmed), isAppleMusicURL(directURL) {
            return directURL.absoluteString
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for match in detector.matches(in: trimmed, range: range) {
            guard let url = match.url,
                  let sanitizedURL = sanitizedURL(from: url.absoluteString),
                  isAppleMusicURL(sanitizedURL) else {
                continue
            }
            return sanitizedURL.absoluteString
        }

        return nil
    }

    private static func sanitizedURL(from value: String) -> URL? {
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,)]}>'\""))
        return URL(string: sanitized)
    }

    private static func recentlyPlayedItems(
        from defaults: UserDefaults
    ) -> [ShareRecentlyPlayedBrowseItem] {
        guard let data = defaults.data(forKey: recentlyPlayedKey),
              let items = try? JSONDecoder().decode([ShareRecentlyPlayedBrowseItem].self, from: data) else {
            return []
        }
        return items
    }

    private static func isAppleMusicURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "music.apple.com" || host.hasSuffix(".music.apple.com")
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    private static var savedSpeakers: [ShareSpeaker] {
        guard let data = defaults?.data(forKey: savedSpeakersKey),
              let speakers = try? JSONDecoder().decode([ShareSpeaker].self, from: data) else {
            return []
        }
        return speakers
    }

    private static func recentSelectedSpeakerFallback() -> ShareSpeaker? {
        guard let ip = defaults?.string(forKey: speakerIPKey), !ip.isEmpty else {
            return nil
        }
        return ShareSpeaker(
            id: defaults?.string(forKey: speakerIDKey) ?? ip,
            name: defaults?.string(forKey: speakerNameKey) ?? "Saved Speaker",
            ipAddress: ip,
            isCoordinator: true,
            groupId: nil,
            coordinatorIP: defaults?.string(forKey: coordinatorIPKey)
        )
    }

    private static func speakerGroups(from speakers: [ShareSpeaker]) -> [ShareSpeakerGroup] {
        let visible = speakers.filter { !$0.isInvisible }
        guard !visible.isEmpty else { return [] }

        var groups: [ShareSpeakerGroup] = []
        let coordinators = visible.filter(\.isCoordinator)
        if coordinators.isEmpty {
            return visible.map {
                ShareSpeakerGroup(id: $0.groupId ?? $0.id, coordinator: $0, members: [$0])
            }
        }

        for coordinator in coordinators {
            let groupID = coordinator.groupId ?? coordinator.id
            let members = visible.filter { member in
                member.id == coordinator.id || member.groupId == coordinator.groupId
            }
            groups.append(ShareSpeakerGroup(
                id: groupID,
                coordinator: coordinator,
                members: members.isEmpty ? [coordinator] : members
            ))
        }
        return groups
    }

    private static func sorted(_ groups: [ShareSpeakerGroup]) -> [ShareSpeakerGroup] {
        let selectedID = defaults?.string(forKey: speakerIDKey)
        let preferredOrder = defaults?.stringArray(forKey: speakerOrderKey) ?? []
        return groups.sorted { left, right in
            let leftSelected = selectedID.map { left.id == $0 || left.coordinator.id == $0 } ?? false
            let rightSelected = selectedID.map { right.id == $0 || right.coordinator.id == $0 } ?? false
            if leftSelected != rightSelected { return leftSelected }

            let leftOrder = orderIndex(for: left, preferredOrder: preferredOrder)
            let rightOrder = orderIndex(for: right, preferredOrder: preferredOrder)
            if leftOrder != rightOrder { return leftOrder < rightOrder }

            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    private static func orderIndex(
        for group: ShareSpeakerGroup,
        preferredOrder: [String]
    ) -> Int {
        let candidates = [group.id, group.coordinator.id, group.coordinator.groupId].compactMap { $0 }
        return preferredOrder.firstIndex(where: { candidates.contains($0) }) ?? Int.max
    }
}
