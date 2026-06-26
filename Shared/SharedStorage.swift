import Foundation

/// URLSession that bypasses any local HTTP proxy (e.g. Clash/Surge on the same network).
let noProxySession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [:]
    return URLSession(configuration: config)
}()

nonisolated struct PendingAppleMusicShare: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let urlString: String
    let receivedAt: Date
}

nonisolated struct AppleMusicSonosServiceCredential: Codable, Equatable, Sendable {
    let cloudServiceId: String
    let localServiceId: Int
    let accountId: String
    let username: String?
    let displayName: String
}

nonisolated struct LiveActivityPushToStartRegistrationRecord: Codable, Equatable, Sendable {
    let token: String
    let relayURLString: String
    let registeredAt: Date
}

enum SharedStorage {

    nonisolated static let appGroupID = "group.com.charm.SonosWidget"

    private nonisolated static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private nonisolated static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private nonisolated static let pendingAppleMusicShareKey = "pendingAppleMusicShare"
    private nonisolated static let appleMusicSonosServiceCredentialKey = "appleMusicSonosServiceCredential"
    private nonisolated static let recentlyPlayedItemsKey = "RecentlyPlayedItems"
    private nonisolated static let liveActivityRelayPushTokensByGroupIDKey = "liveActivityRelayPushTokensByGroupID"
    private nonisolated static let liveActivityPushToStartRegistrationsByGroupIDKey =
        "liveActivityPushToStartRegistrationsByGroupID"

    // MARK: - Apple Music Share Intake

    nonisolated static var pendingAppleMusicShare: PendingAppleMusicShare? {
        get {
            guard let data = defaults.data(forKey: pendingAppleMusicShareKey) else {
                return nil
            }
            return try? JSONDecoder().decode(PendingAppleMusicShare.self, from: data)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: pendingAppleMusicShareKey)
                return
            }

            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: pendingAppleMusicShareKey)
            }
        }
    }

    nonisolated static func clearPendingAppleMusicShare() {
        pendingAppleMusicShare = nil
    }

    // MARK: - Browse Recently Played

    nonisolated static var recentlyPlayedItems: [BrowseItem] {
        get {
            guard let data = defaults.data(forKey: recentlyPlayedItemsKey),
                  let items = try? JSONDecoder().decode([BrowseItem].self, from: data) else {
                return []
            }
            return items
        }
        set {
            guard !newValue.isEmpty else {
                defaults.removeObject(forKey: recentlyPlayedItemsKey)
                return
            }
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: recentlyPlayedItemsKey)
            }
        }
    }

    nonisolated static var appleMusicSonosServiceCredential: AppleMusicSonosServiceCredential? {
        get {
            guard let data = defaults.data(forKey: appleMusicSonosServiceCredentialKey) else {
                return nil
            }
            return try? JSONDecoder().decode(AppleMusicSonosServiceCredential.self, from: data)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: appleMusicSonosServiceCredentialKey)
                return
            }

            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: appleMusicSonosServiceCredentialKey)
            }
        }
    }

    // MARK: - Speaker

    nonisolated static var speakerIP: String? {
        get { defaults.string(forKey: "speakerIP") }
        set { defaults.set(newValue, forKey: "speakerIP") }
    }

    nonisolated static var speakerID: String? {
        get { defaults.string(forKey: "speakerID") }
        set { defaults.set(newValue, forKey: "speakerID") }
    }

    nonisolated static var speakerName: String? {
        get { defaults.string(forKey: "speakerName") }
        set { defaults.set(newValue, forKey: "speakerName") }
    }

    nonisolated static var coordinatorIP: String? {
        get { defaults.string(forKey: "coordinatorIP") }
        set { defaults.set(newValue, forKey: "coordinatorIP") }
    }

    // MARK: - Cached Playback State

    nonisolated static var isPlaying: Bool {
        get { defaults.bool(forKey: "isPlaying") }
        set { defaults.set(newValue, forKey: "isPlaying") }
    }

    nonisolated static var cachedTrackTitle: String? {
        get { defaults.string(forKey: "trackTitle") }
        set { defaults.set(newValue, forKey: "trackTitle") }
    }

    nonisolated static var cachedArtist: String? {
        get { defaults.string(forKey: "artist") }
        set { defaults.set(newValue, forKey: "artist") }
    }

    nonisolated static var cachedAlbum: String? {
        get { defaults.string(forKey: "album") }
        set { defaults.set(newValue, forKey: "album") }
    }

    nonisolated static var cachedAlbumArtURL: String? {
        get { defaults.string(forKey: "albumArtURL") }
        set { defaults.set(newValue, forKey: "albumArtURL") }
    }

    nonisolated static var cachedAlbumArtDataURL: String? {
        get { defaults.string(forKey: "albumArtDataURL") }
        set {
            if let newValue {
                defaults.set(newValue, forKey: "albumArtDataURL")
            } else {
                defaults.removeObject(forKey: "albumArtDataURL")
            }
        }
    }

    nonisolated static var cachedVolume: Int {
        get { defaults.integer(forKey: "volume") }
        set { defaults.set(newValue, forKey: "volume") }
    }

    nonisolated static var cachedPlaybackSource: String? {
        get { defaults.string(forKey: "playbackSource") }
        set { defaults.set(newValue, forKey: "playbackSource") }
    }

    nonisolated static var cachedDominantColorHex: String? {
        get { defaults.string(forKey: "dominantColorHex") }
        set { defaults.set(newValue, forKey: "dominantColorHex") }
    }

    nonisolated static var cachedAudioQualityLabel: String? {
        get { defaults.string(forKey: "audioQualityLabel") }
        set { defaults.set(newValue, forKey: "audioQualityLabel") }
    }

    /// Cached `TrackInfo.isLiveStream` flag. Lets the widget swap its
    /// transport row to a single Stop button (and the Live Activity hide
    /// its progress bar) for Apple Music 1 / live radio without forcing
    /// every consumer to recompute from `TrackInfo`.
    nonisolated static var cachedIsLiveStream: Bool {
        get { defaults.bool(forKey: "isLiveStream") }
        set { defaults.set(newValue, forKey: "isLiveStream") }
    }

    nonisolated static var cachedSoundbarNightMode: Bool {
        get { defaults.bool(forKey: "soundbarNightMode") }
        set { defaults.set(newValue, forKey: "soundbarNightMode") }
    }

    nonisolated static var cachedSoundbarSpeechEnhancementRawLevel: Int {
        get {
            let rawLevel = defaults.object(forKey: "soundbarSpeechEnhancementRawLevel") as? Int ?? 0
            return SpeechEnhancementLevel.from(rawLevel: rawLevel).rawValue
        }
        set {
            defaults.set(
                SpeechEnhancementLevel.from(rawLevel: newValue).rawValue,
                forKey: "soundbarSpeechEnhancementRawLevel")
        }
    }

    // MARK: - Live Activity Style

    nonisolated static var liveActivityStyle: LiveActivityStyle {
        get {
            guard let rawValue = defaults.string(forKey: "liveActivityStyle"),
                  let style = LiveActivityStyle(rawValue: rawValue) else {
                return .classic
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: "liveActivityStyle")
        }
    }

    /// Timestamp after which fetchLiveEntry may overwrite isPlaying from the device.
    /// Set by PlayPauseIntent to prevent the live fetch from reverting the optimistic update.
    nonisolated static var playStateLockUntil: Date {
        get {
            let ts = defaults.double(forKey: "playStateLockUntil")
            return ts == 0 ? .distantPast : Date(timeIntervalSince1970: ts)
        }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "playStateLockUntil") }
    }

    // MARK: - Sonos Cloud API (shared with widget extension)

    /// OAuth access token — mirrored here so widget extension can call Cloud API without Keychain sharing.
    nonisolated static var cloudAccessToken: String? {
        get { defaults.string(forKey: "cloudAccessToken") }
        set { defaults.set(newValue, forKey: "cloudAccessToken") }
    }

    nonisolated static var cloudTokenExpiry: Date {
        get {
            let ts = defaults.double(forKey: "cloudTokenExpiry")
            return ts == 0 ? .distantPast : Date(timeIntervalSince1970: ts)
        }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "cloudTokenExpiry") }
    }

    /// Cloud group ID for the currently selected speaker's group.
    nonisolated static var cloudGroupId: String? {
        get { defaults.string(forKey: "cloudGroupId") }
        set { defaults.set(newValue, forKey: "cloudGroupId") }
    }

    /// Mapping of local Sonos service id (`sid=…` in track URIs) to that
    /// service's human-readable name ("Spotify", "Apple Music",
    /// "网易云音乐"…). Populated by `SearchManager.buildServiceIdMapping`
    /// after `ListAvailableServices` finishes, and read by `SonosManager`
    /// when enriching `TrackInfo.source` — the UPnP track URI alone doesn't
    /// carry enough info to distinguish e.g. NetEase from any other
    /// hard-coded service since NetEase's local sid varies per installation.
    nonisolated static var serviceNamesByLocalSid: [String: String] {
        get {
            guard let dict = defaults.dictionary(forKey: "serviceNamesByLocalSid")
                as? [String: String] else { return [:] }
            return dict
        }
        set { defaults.set(newValue, forKey: "serviceNamesByLocalSid") }
    }

    /// Local Sonos service catalog metadata keyed by local sid. This is not an
    /// account list; it is safe no-login metadata from `ListAvailableServices`
    /// used for playback/source hints and future presentation-map quality badges.
    nonisolated static var musicServiceCatalogByLocalSid: [String: MusicServiceCatalogMetadata] {
        get {
            guard let data = defaults.data(forKey: "musicServiceCatalogByLocalSid"),
                  let decoded = try? JSONDecoder().decode(
                    [String: MusicServiceCatalogMetadata].self,
                    from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: "musicServiceCatalogByLocalSid")
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "musicServiceCatalogByLocalSid")
            }
        }
    }

    /// Total visible speakers in the currently playing group (including coordinator).
    nonisolated static var cachedGroupMemberCount: Int {
        get { defaults.integer(forKey: "groupMemberCount") }
        set { defaults.set(newValue, forKey: "groupMemberCount") }
    }

    // MARK: - Album Art File

    nonisolated static var albumArtData: Data? {
        get {
            guard let url = containerURL?.appendingPathComponent("albumArt.jpg") else { return nil }
            return try? Data(contentsOf: url)
        }
        set {
            guard let url = containerURL?.appendingPathComponent("albumArt.jpg") else { return }
            if let data = newValue {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Live Activity Relay

    /// User-configured base URL of the optional NAS relay (e.g.
    /// `http://192.168.50.10:8787`). Empty / nil = relay disabled, fall
    /// back to local Activity updates.
    nonisolated static var relayURLString: String? {
        get { defaults.string(forKey: "relayURL") }
        set { defaults.set(newValue, forKey: "relayURL") }
    }

    nonisolated static var discoveredRelayURLString: String? {
        get { defaults.string(forKey: "discoveredRelayURL") }
        set { defaults.set(newValue, forKey: "discoveredRelayURL") }
    }

    nonisolated static var liveActivityRelayClientID: String {
        if let existing = defaults.string(forKey: "liveActivityRelayClientID"), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: "liveActivityRelayClientID")
        return value
    }

    nonisolated static var liveActivityRelayPushToken: String? {
        get { defaults.string(forKey: "liveActivityRelayPushToken") }
        set { defaults.set(newValue, forKey: "liveActivityRelayPushToken") }
    }

    nonisolated static var liveActivityRelayPushTokensByGroupID: [String: String] {
        get {
            guard let data = defaults.data(forKey: liveActivityRelayPushTokensByGroupIDKey),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: liveActivityRelayPushTokensByGroupIDKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: liveActivityRelayPushTokensByGroupIDKey)
            }
        }
    }

    nonisolated static func liveActivityRelayPushToken(for groupId: String?) -> String? {
        let cleanGroupId = groupId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanGroupId.isEmpty,
           let token = liveActivityRelayPushTokensByGroupID[cleanGroupId],
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token
        }
        return liveActivityRelayPushToken
    }

    nonisolated static func setLiveActivityRelayPushToken(_ token: String?, for groupId: String) {
        let cleanGroupId = groupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGroupId.isEmpty else { return }
        var tokens = liveActivityRelayPushTokensByGroupID
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            tokens[cleanGroupId] = token
        } else {
            tokens.removeValue(forKey: cleanGroupId)
        }
        liveActivityRelayPushTokensByGroupID = tokens
    }

    nonisolated static var liveActivityPushToStartToken: String? {
        get { defaults.string(forKey: "liveActivityPushToStartToken") }
        set { defaults.set(newValue, forKey: "liveActivityPushToStartToken") }
    }

    nonisolated static var liveActivityPushToStartRegisteredAt: Date {
        get {
            let ts = defaults.double(forKey: "liveActivityPushToStartRegisteredAt")
            return ts == 0 ? .distantPast : Date(timeIntervalSince1970: ts)
        }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "liveActivityPushToStartRegisteredAt") }
    }

    nonisolated static var liveActivityPushToStartRegisteredToken: String? {
        get { defaults.string(forKey: "liveActivityPushToStartRegisteredToken") }
        set { defaults.set(newValue, forKey: "liveActivityPushToStartRegisteredToken") }
    }

    nonisolated static var liveActivityPushToStartRegisteredGroupID: String? {
        get { defaults.string(forKey: "liveActivityPushToStartRegisteredGroupID") }
        set { defaults.set(newValue, forKey: "liveActivityPushToStartRegisteredGroupID") }
    }

    nonisolated static var liveActivityPushToStartRegisteredRelayURLString: String? {
        get { defaults.string(forKey: "liveActivityPushToStartRegisteredRelayURLString") }
        set { defaults.set(newValue, forKey: "liveActivityPushToStartRegisteredRelayURLString") }
    }

    nonisolated static var liveActivityPushToStartRegistrationsByGroupID:
        [String: LiveActivityPushToStartRegistrationRecord] {
        get {
            guard let data = defaults.data(forKey: liveActivityPushToStartRegistrationsByGroupIDKey),
                  let decoded = try? JSONDecoder().decode(
                    [String: LiveActivityPushToStartRegistrationRecord].self,
                    from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: liveActivityPushToStartRegistrationsByGroupIDKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: liveActivityPushToStartRegistrationsByGroupIDKey)
            }
        }
    }

    nonisolated static func liveActivityPushToStartRegistration(
        for groupId: String
    ) -> LiveActivityPushToStartRegistrationRecord? {
        liveActivityPushToStartRegistrationsByGroupID[groupId]
    }

    nonisolated static func setLiveActivityPushToStartRegistration(
        _ record: LiveActivityPushToStartRegistrationRecord?,
        for groupId: String
    ) {
        let cleanGroupId = groupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGroupId.isEmpty else { return }
        var records = liveActivityPushToStartRegistrationsByGroupID
        records[cleanGroupId] = record
        liveActivityPushToStartRegistrationsByGroupID = records
    }

    // MARK: - NAS LLM Agent

    /// Base URL of the optional Python agent (`nas-agent/`), e.g. `http://192.168.50.10:8790`.
    nonisolated static var agentURLString: String? {
        get { defaults.string(forKey: "agentURL") }
        set { defaults.set(newValue, forKey: "agentURL") }
    }

    /// Bearer token matching the agent's `AGENT_USER_TOKEN` env var.
    nonisolated static var agentTokenString: String? {
        get { defaults.string(forKey: "agentToken") }
        set { defaults.set(newValue, forKey: "agentToken") }
    }

    // MARK: - Hue Ambience

    nonisolated static var hueAmbienceEnabled: Bool {
        get { defaults.bool(forKey: "hueAmbienceEnabled") }
        set { defaults.set(newValue, forKey: "hueAmbienceEnabled") }
    }

    nonisolated static var hueBridgeData: Data? {
        get { defaults.data(forKey: "hueBridgeData") }
        set { defaults.set(newValue, forKey: "hueBridgeData") }
    }

    nonisolated static var hueMappingsData: Data? {
        get { defaults.data(forKey: "hueMappingsData") }
        set { defaults.set(newValue, forKey: "hueMappingsData") }
    }

    nonisolated static var hueResourcesData: Data? {
        get { defaults.data(forKey: "hueResourcesData") }
        set { defaults.set(newValue, forKey: "hueResourcesData") }
    }

    nonisolated static var hueGroupStrategyRaw: String? {
        get { defaults.string(forKey: "hueGroupStrategy") }
        set { defaults.set(newValue, forKey: "hueGroupStrategy") }
    }

    nonisolated static var hueStopBehaviorRaw: String? {
        get { defaults.string(forKey: "hueStopBehavior") }
        set { defaults.set(newValue, forKey: "hueStopBehavior") }
    }

    nonisolated static var hueMotionStyleRaw: String? {
        get { defaults.string(forKey: "hueMotionStyle") }
        set { defaults.set(newValue, forKey: "hueMotionStyle") }
    }

    nonisolated static var hueFlowSpeedRaw: String? {
        get { defaults.string(forKey: "hueFlowSpeed") }
        set { defaults.set(newValue, forKey: "hueFlowSpeed") }
    }

    nonisolated static var hueLastStatusText: String? {
        get { defaults.string(forKey: "hueLastStatusText") }
        set { defaults.set(newValue, forKey: "hueLastStatusText") }
    }

    // MARK: - Saved Speakers

    nonisolated static var savedSpeakers: [SonosPlayer] {
        get {
            guard let data = defaults.data(forKey: "savedSpeakers"),
                  let speakers = try? JSONDecoder().decode([SonosPlayer].self, from: data) else { return [] }
            return speakers
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: "savedSpeakers")
        }
    }

    nonisolated static var homeSpeakerGroupOrder: [String] {
        get { defaults.stringArray(forKey: "homeSpeakerGroupOrder") ?? [] }
        set { defaults.set(newValue, forKey: "homeSpeakerGroupOrder") }
    }
}
