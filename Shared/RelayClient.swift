import Foundation

/// Stateless HTTP client for the optional Sonos Live Activity relay
/// (the Node.js service we ship in `nas-relay/`). All calls use the no-proxy
/// session so a Clash / Surge running on the iPhone doesn't intercept LAN
/// traffic and bounce us through 127.0.0.1 weirdness.
///
/// Errors are intentionally **not** swallowed here — callers (RelayManager,
/// SonosManager) decide whether a failure should mark the relay unreachable
/// or just be logged.
enum RelayClient {

    struct LiveActivityCommandRoute: Equatable, Sendable {
        let baseURL: URL
        let groupId: String
        let token: String
    }

    // MARK: - Health probe

    struct HealthResponse: Decodable, Sendable {
        struct Group: Decodable, Sendable {
            let groupId: String
            let speakerName: String?
            let isPlaying: Bool?
            let title: String?
        }
        struct Sonos: Decodable, Sendable {
            enum DiscoveryMode: String, Decodable, Sendable {
                case auto
                case seed
                case unknown

                init(from decoder: Decoder) throws {
                    let raw = try decoder.singleValueContainer().decode(String.self)
                    self = DiscoveryMode(rawValue: raw) ?? .unknown
                }
            }

            enum DiscoveryStatus: String, Decodable, Sendable {
                case idle
                case starting
                case ready
                case failed
                case unknown

                init(from decoder: Decoder) throws {
                    let raw = try decoder.singleValueContainer().decode(String.self)
                    self = DiscoveryStatus(rawValue: raw) ?? .unknown
                }
            }

            let discoveryMode: DiscoveryMode
            let discoveryStatus: DiscoveryStatus
            let discoveryError: String?
        }
        struct APNs: Decodable, Sendable {
            enum Mode: String, Decodable, Sendable {
                case ready
                case dryRun = "dry-run"
                case unknown

                init(from decoder: Decoder) throws {
                    let raw = try decoder.singleValueContainer().decode(String.self)
                    self = Mode(rawValue: raw) ?? .unknown
                }
            }

            enum Environment: String, Decodable, Sendable {
                case sandbox
                case production
                case unknown

                init(from decoder: Decoder) throws {
                    let raw = try decoder.singleValueContainer().decode(String.self)
                    self = Environment(rawValue: raw) ?? .unknown
                }
            }

            let mode: Mode
            let environment: Environment
            let bundleId: String?
            let keyIdConfigured: Bool?
            let teamIdConfigured: Bool?
            let keyFilePresent: Bool?
            let missing: [String]

            private enum CodingKeys: String, CodingKey {
                case mode
                case environment
                case bundleId
                case keyIdConfigured
                case teamIdConfigured
                case keyFilePresent
                case missing
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .unknown
                environment = try container.decodeIfPresent(Environment.self, forKey: .environment) ?? .unknown
                bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
                keyIdConfigured = try container.decodeIfPresent(Bool.self, forKey: .keyIdConfigured)
                teamIdConfigured = try container.decodeIfPresent(Bool.self, forKey: .teamIdConfigured)
                keyFilePresent = try container.decodeIfPresent(Bool.self, forKey: .keyFilePresent)
                missing = try container.decodeIfPresent([String].self, forKey: .missing) ?? []
            }
        }
        struct HueAmbience: Decodable, Sendable {
            let configured: Bool?
            let enabled: Bool?
            let runtimeActive: Bool?
            let runtimePaused: Bool?
            let renderMode: HueAmbienceRelayRenderMode?
            let activeTargetIds: [String]?
            let activeGroups: [HueAmbienceActiveSyncGroup]?
            let entertainmentTargetActive: Bool?
            let entertainmentMetadataComplete: Bool?
            let lastFrameAt: String?
            let lastError: String?

            private enum CodingKeys: String, CodingKey {
                case configured
                case enabled
                case runtimeActive
                case runtimePaused
                case renderMode
                case activeTargetIds
                case activeGroups
                case entertainmentTargetActive
                case entertainmentMetadataComplete
                case lastFrameAt
                case lastError
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                configured = try container.decodeIfPresent(Bool.self, forKey: .configured)
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
                runtimeActive = try container.decodeIfPresent(Bool.self, forKey: .runtimeActive)
                runtimePaused = try container.decodeIfPresent(Bool.self, forKey: .runtimePaused)
                renderMode = try container
                    .decodeIfPresent(String.self, forKey: .renderMode)
                    .flatMap(HueAmbienceRelayRenderMode.init(rawValue:))
                activeTargetIds = try container.decodeIfPresent([String].self, forKey: .activeTargetIds)
                activeGroups = try container.decodeIfPresent([HueAmbienceActiveSyncGroup].self, forKey: .activeGroups)
                entertainmentTargetActive = try container.decodeIfPresent(Bool.self, forKey: .entertainmentTargetActive)
                entertainmentMetadataComplete = try container.decodeIfPresent(Bool.self, forKey: .entertainmentMetadataComplete)
                lastFrameAt = try container.decodeIfPresent(String.self, forKey: .lastFrameAt)
                lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
            }
        }
        struct HueEntertainment: Decodable, Sendable {
            let configured: Bool?
            let bridgeReachable: Bool?
            let streaming: HueEntertainmentStreamingStatus
            let activeStreamer: String?
            let activeAreaId: String?
            let lastError: String?

            private enum CodingKeys: String, CodingKey {
                case configured
                case bridgeReachable
                case streaming
                case activeStreamer
                case activeAreaId
                case lastError
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                configured = try container.decodeIfPresent(Bool.self, forKey: .configured)
                bridgeReachable = try container.decodeIfPresent(Bool.self, forKey: .bridgeReachable)
                streaming = try container
                    .decodeIfPresent(String.self, forKey: .streaming)
                    .flatMap(HueEntertainmentStreamingStatus.init(rawValue:)) ?? .unknown
                activeStreamer = try container.decodeIfPresent(String.self, forKey: .activeStreamer)
                activeAreaId = try container.decodeIfPresent(String.self, forKey: .activeAreaId)
                lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
            }
        }
        let ok: Bool
        let groups: [Group]
        let sonos: Sonos?
        let apns: APNs?
        let hueAmbience: HueAmbience?
        let hueEntertainment: HueEntertainment?
    }

    static func health(baseURL: URL) async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("/api/health")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    // MARK: - Artwork proxy

    static func artworkProxyURL(baseURL: URL, sourceURLString: String) -> URL? {
        let source = sourceURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }

        let lowercasedSource = source.lowercased()
        guard lowercasedSource.hasPrefix("http://") || lowercasedSource.hasPrefix("https://") else {
            return nil
        }

        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("artwork")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: source)
        ]
        return components.url
    }

    static func fetchArtwork(baseURL: URL, sourceURLString: String) async throws -> Data {
        guard let url = artworkProxyURL(baseURL: baseURL, sourceURLString: sourceURLString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return data
    }

    // MARK: - Animated artwork

    struct AnimatedArtworkResponse: Decodable, Equatable, Sendable {
        enum Status: String, Decodable, Sendable {
            case hit
            case miss
            case negativeCache = "negative-cache"
            case rateLimited = "rate-limited"
            case disabled
            case error
            case unknown

            init(from decoder: Decoder) throws {
                let rawValue = try decoder.singleValueContainer().decode(String.self)
                self = Status(rawValue: rawValue) ?? .unknown
            }
        }

        let ok: Bool
        let status: Status
        let artist: String?
        let album: String?
        let appleMusicURLString: String?
        let squareURLString: String?
        let squareWidth: Int?
        let squareHeight: Int?
        let squareAspectRatio: Double?
        let tallURLString: String?
        let tallWidth: Int?
        let tallHeight: Int?
        let tallAspectRatio: Double?
        let source: String?

        private enum CodingKeys: String, CodingKey {
            case ok
            case status
            case artist
            case album
            case appleMusicURLString = "appleMusicUrl"
            case squareURLString = "squareUrl"
            case squareWidth
            case squareHeight
            case squareAspectRatio
            case tallURLString = "tallUrl"
            case tallWidth
            case tallHeight
            case tallAspectRatio
            case source
        }

        init(
            ok: Bool,
            status: Status,
            artist: String?,
            album: String?,
            appleMusicURLString: String?,
            squareURLString: String?,
            squareWidth: Int? = nil,
            squareHeight: Int? = nil,
            squareAspectRatio: Double? = nil,
            tallURLString: String?,
            tallWidth: Int? = nil,
            tallHeight: Int? = nil,
            tallAspectRatio: Double? = nil,
            source: String?
        ) {
            self.ok = ok
            self.status = status
            self.artist = artist
            self.album = album
            self.appleMusicURLString = appleMusicURLString
            self.squareURLString = squareURLString
            self.squareWidth = squareWidth
            self.squareHeight = squareHeight
            self.squareAspectRatio = squareAspectRatio
            self.tallURLString = tallURLString
            self.tallWidth = tallWidth
            self.tallHeight = tallHeight
            self.tallAspectRatio = tallAspectRatio
            self.source = source
        }

        var bestPlayerArtworkURL: URL? {
            let candidates: [String?] = [squareURLString, tallURLString]
            return candidates.compactMap { value -> URL? in
                guard let value else { return nil }
                return URL(string: value)
            }.first
        }
    }

    static func animatedArtworkURL(
        baseURL: URL,
        albumURL: URL,
        countryCode: String? = nil
    ) -> URL? {
        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("animated-artwork")
            .appendingPathComponent("url")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: albumURL.absoluteString),
            countryCode.map { URLQueryItem(name: "country", value: $0) }
        ].compactMap { $0 }
        return components.url
    }

    static func animatedArtworkSearchURL(
        baseURL: URL,
        artist: String,
        album: String,
        countryCode: String? = nil
    ) -> URL? {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty, !trimmedAlbum.isEmpty else { return nil }

        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("animated-artwork")
            .appendingPathComponent("search")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "artist", value: trimmedArtist),
            URLQueryItem(name: "album", value: trimmedAlbum),
            countryCode.map { URLQueryItem(name: "country", value: $0) }
        ].compactMap { $0 }
        return components.url
    }

    static func animatedArtworkByURL(
        baseURL: URL,
        albumURL: URL,
        countryCode: String? = nil
    ) async throws -> AnimatedArtworkResponse {
        guard let url = animatedArtworkURL(
            baseURL: baseURL,
            albumURL: albumURL,
            countryCode: countryCode
        ) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(AnimatedArtworkResponse.self, from: data)
    }

    static func animatedArtworkSearch(
        baseURL: URL,
        artist: String,
        album: String,
        countryCode: String? = nil
    ) async throws -> AnimatedArtworkResponse {
        guard let url = animatedArtworkSearchURL(
            baseURL: baseURL,
            artist: artist,
            album: album,
            countryCode: countryCode
        ) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(AnimatedArtworkResponse.self, from: data)
    }

    // MARK: - Cached playback state

    struct PlaybackStateResponse: Decodable, Sendable {
        let ok: Bool
        let source: String?
        let state: RelayPlaybackState?
    }

    static func playbackStateURL(baseURL: URL, groupId: String) -> URL? {
        let trimmedGroupId = groupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGroupId.isEmpty else { return nil }

        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("playback-state")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "groupId", value: trimmedGroupId)
        ]
        return components.url
    }

    static func fetchPlaybackState(baseURL: URL, groupId: String) async throws -> RelayPlaybackState? {
        guard let url = playbackStateURL(baseURL: baseURL, groupId: groupId) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 2.5)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(PlaybackStateResponse.self, from: data).state
    }

    // MARK: - Artwork hints

    struct ArtworkHintsBody: Encodable, Sendable {
        let hints: [ArtworkHint]

        init(hints: [ArtworkHint]) {
            self.hints = hints
        }

        init(items: [BrowseItem], limit: Int = 100) {
            self.hints = Array(items.compactMap(ArtworkHint.init(item:)).prefix(max(0, limit)))
        }
    }

    struct ArtworkHint: Encodable, Sendable {
        let id: String
        let uri: String?
        let title: String
        let artist: String
        let album: String
        let cloudType: String?
        let artworkUrl: String

        init?(
            id: String,
            uri: String?,
            title: String,
            artist: String,
            album: String,
            cloudType: String?,
            artworkUrl: String?
        ) {
            let normalizedArtworkURL = ArtworkURLNormalizer.loadableURLString(
                from: artworkUrl,
                preserveExistingAppleArtworkSize: true
            )
            guard let normalizedArtworkURL,
                  !Self.isLocalSonosArtworkURL(normalizedArtworkURL) else {
                return nil
            }

            self.id = id
            self.uri = uri
            self.title = title
            self.artist = artist
            self.album = album
            self.cloudType = cloudType
            self.artworkUrl = normalizedArtworkURL
        }

        init?(item: BrowseItem) {
            self.init(
                id: item.id,
                uri: item.uri,
                title: item.title,
                artist: item.artist,
                album: item.album,
                cloudType: item.cloudType,
                artworkUrl: item.thumbnailArtworkURL ?? item.preferredDetailArtworkURL
            )
        }

        private static func isLocalSonosArtworkURL(_ value: String) -> Bool {
            guard let url = URL(string: value),
                  url.scheme?.lowercased() == "http",
                  url.port == 1400 else {
                return false
            }
            return url.path.lowercased().contains("getaa")
        }
    }

    static func postArtworkHints(baseURL: URL, body: ArtworkHintsBody) async throws {
        guard !body.hints.isEmpty else { return }

        let url = baseURL.appendingPathComponent("/api/artwork-hints")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    // MARK: - Device diagnostics

    struct DeviceLogEntryBody: Encodable, Sendable {
        let timestamp: String
        let category: String
        let level: String
        let message: String
        let line: String
    }

    struct DeviceLogBody: Encodable, Sendable {
        let clientId: String
        let bundleId: String?
        let processName: String?
        let entries: [DeviceLogEntryBody]
    }

    static func deviceLogsURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("/api/device-logs")
    }

    static func postDeviceLogs(baseURL: URL, body: DeviceLogBody) async throws {
        guard !body.entries.isEmpty else { return }

        let url = deviceLogsURL(baseURL: baseURL)
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    // MARK: - Activity registration

    /// Sent in the JSON body of `POST /api/register-activity`.
    struct ActivityRegistrationBody: Encodable, Sendable {
        let groupId: String
        let token: String
        let clientId: String
        let activityId: String
        let attributes: Attributes
        let liveActivityStyleRaw: String?
        struct Attributes: Encodable, Sendable { let speakerName: String }

        init(
            groupId: String,
            token: String,
            clientId: String,
            activityId: String,
            speakerName: String,
            liveActivityStyleRaw: String?
        ) {
            self.groupId = groupId
            self.token = token
            self.clientId = clientId
            self.activityId = activityId
            self.attributes = .init(speakerName: speakerName)
            self.liveActivityStyleRaw = liveActivityStyleRaw
        }
    }

    struct ActivityRegistrationResponse: Decodable, Sendable {
        let ok: Bool
        let initialState: SonosActivityAttributes.ContentState?
    }

    static func registerActivity(
        baseURL: URL,
        groupId: String,
        token: String,
        clientId: String,
        activityId: String,
        speakerName: String,
        liveActivityStyleRaw: String?
    ) async throws -> ActivityRegistrationResponse {
        let url = baseURL.appendingPathComponent("/api/register-activity")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ActivityRegistrationBody(
            groupId: groupId,
            token: token,
            clientId: clientId,
            activityId: activityId,
            speakerName: speakerName,
            liveActivityStyleRaw: liveActivityStyleRaw
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(ActivityRegistrationResponse.self, from: data)
    }

    /// Sent in the JSON body of `POST /api/register-push-to-start`.
    struct PushToStartRegistrationBody: Encodable, Sendable {
        let groupId: String
        let token: String
        let clientId: String
        let speakerName: String?
        let liveActivityStyleRaw: String?
        let activeActivityIds: [String]
        let clearDismissalSuppression: Bool
    }

    static func registerPushToStart(
        baseURL: URL,
        groupId: String,
        token: String,
        clientId: String,
        speakerName: String?,
        liveActivityStyleRaw: String?,
        activeActivityIds: [String],
        clearDismissalSuppression: Bool = false
    ) async throws {
        let url = baseURL.appendingPathComponent("/api/register-push-to-start")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PushToStartRegistrationBody(
                groupId: groupId,
                token: token,
                clientId: clientId,
                speakerName: speakerName,
                liveActivityStyleRaw: liveActivityStyleRaw,
                activeActivityIds: activeActivityIds,
                clearDismissalSuppression: clearDismissalSuppression
            )
        )
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    struct RelayPlaybackState: Decodable, Sendable {
        let groupId: String
        let speakerName: String?
        let trackTitle: String
        let artist: String
        let album: String
        let albumArtUri: String?
        let isPlaying: Bool
        let playbackSourceRaw: String?
        let audioQualityLabel: String?
        let soundbarNightMode: Bool?
        let soundbarSpeechEnhancementRawLevel: Int?
        let positionSeconds: Double
        let durationSeconds: Double
        let groupMemberCount: Int

        var trackInfo: TrackInfo {
            TrackInfo(
                title: trackTitle,
                artist: artist,
                album: album,
                albumArtURL: albumArtUri,
                duration: Self.sonosTime(from: durationSeconds),
                position: Self.sonosTime(from: positionSeconds),
                source: playbackSourceRaw.flatMap(PlaybackSource.init(rawValue:)) ?? .unknown,
                audioQuality: audioQualityLabel.map { AudioQuality(codec: $0) }
            )
        }

        private static func sonosTime(from seconds: Double) -> String {
            let total = max(0, Int(seconds.rounded()))
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let secs = total % 60
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
    }

    struct LiveActivityCommandBody: Encodable, Sendable {
        let groupId: String
        let token: String
        let command: String
        let volume: Int?
        let nightMode: Bool?
        let speechEnhancementRawLevel: Int?
    }

    private struct LiveActivityCommandResponse: Decodable {
        let ok: Bool
        let state: RelayPlaybackState?
    }

    static func sendLiveActivityCommand(
        baseURL: URL,
        groupId: String,
        token: String,
        command: String,
        volume: Int? = nil,
        nightMode: Bool? = nil,
        speechEnhancementRawLevel: Int? = nil
    ) async throws -> RelayPlaybackState? {
        let url = baseURL.appendingPathComponent("/api/live-activity-command")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LiveActivityCommandBody(
                groupId: groupId,
                token: token,
                command: command,
                volume: volume,
                nightMode: nightMode,
                speechEnhancementRawLevel: speechEnhancementRawLevel
            )
        )
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(LiveActivityCommandResponse.self, from: data).state
    }

    static func liveActivityCommandRoute(
        relayURLString: String?,
        relayPushToken: String?,
        coordinatorIP: String?,
        fallbackGroupId: String
    ) -> LiveActivityCommandRoute? {
        let urlString = relayURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = relayPushToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let coordinator = coordinatorIP?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = fallbackGroupId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let groupId = coordinator.isEmpty ? fallback : coordinator

        guard let url = URL(string: urlString),
              !token.isEmpty,
              !groupId.isEmpty else {
            return nil
        }

        return LiveActivityCommandRoute(
            baseURL: url,
            groupId: groupId,
            token: token
        )
    }

    static func unregisterActivity(baseURL: URL, token: String) async throws {
        let escaped = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        let url = baseURL.appendingPathComponent("/api/register-activity/\(escaped)")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "DELETE"
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    struct LiveActivityDismissalBody: Encodable, Sendable {
        let groupId: String
        let clientId: String
        let activityId: String?
        let token: String?
        let suppressForSeconds: Int
    }

    static func postLiveActivityDismissal(
        baseURL: URL,
        body: LiveActivityDismissalBody
    ) async throws {
        let url = baseURL.appendingPathComponent("/api/live-activity-dismissed")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    // MARK: - Live Activity preferences

    struct LiveActivityPreferencesBody: Encodable, Sendable {
        let groupId: String
        let liveActivityStyleRaw: String?
        let selectedGroupId: String?
        let clientId: String?
        let resumeLiveActivity: Bool?
    }

    static func postLiveActivityPreferences(
        baseURL: URL,
        body: LiveActivityPreferencesBody
    ) async throws {
        let url = baseURL.appendingPathComponent("/api/live-activity-preferences")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    // MARK: - Helpers

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
    }
}
