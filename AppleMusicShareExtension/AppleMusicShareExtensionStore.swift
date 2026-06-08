import Foundation

private struct PendingAppleMusicSharePayload: Codable {
    let id: UUID
    let urlString: String
    let receivedAt: Date
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
