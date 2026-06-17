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
        struct HueAmbience: Decodable, Sendable {
            let configured: Bool?
            let enabled: Bool?
            let runtimeActive: Bool?
            let renderMode: HueAmbienceRelayRenderMode?
            let activeTargetIds: [String]?
            let entertainmentTargetActive: Bool?
            let entertainmentMetadataComplete: Bool?
            let lastFrameAt: String?
            let lastError: String?

            private enum CodingKeys: String, CodingKey {
                case configured
                case enabled
                case runtimeActive
                case renderMode
                case activeTargetIds
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
                renderMode = try container
                    .decodeIfPresent(String.self, forKey: .renderMode)
                    .flatMap(HueAmbienceRelayRenderMode.init(rawValue:))
                activeTargetIds = try container.decodeIfPresent([String].self, forKey: .activeTargetIds)
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
        struct CS2Lighting: Decodable, Sendable {
            let enabled: Bool?
            let active: Bool?
            let mode: CS2LightingMode
            let transport: CS2LightingTransport
            let fallbackReason: String?
            let areaId: String?
            let areaName: String?

            private enum CodingKeys: String, CodingKey {
                case enabled
                case active
                case mode
                case transport
                case fallbackReason
                case areaId
                case areaName
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
                active = try container.decodeIfPresent(Bool.self, forKey: .active)
                mode = try container
                    .decodeIfPresent(String.self, forKey: .mode)
                    .flatMap(CS2LightingMode.init(rawValue:)) ?? .unknown
                transport = try container
                    .decodeIfPresent(String.self, forKey: .transport)
                    .flatMap(CS2LightingTransport.init(rawValue:)) ?? .unknown
                fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
                areaId = try container.decodeIfPresent(String.self, forKey: .areaId)
                areaName = try container.decodeIfPresent(String.self, forKey: .areaName)
            }
        }
        let ok: Bool
        let groups: [Group]
        let hueAmbience: HueAmbience?
        let hueEntertainment: HueEntertainment?
        let cs2Lighting: CS2Lighting?
    }

    static func health(baseURL: URL) async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("/api/health")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
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

    static func registerActivity(
        baseURL: URL,
        groupId: String,
        token: String,
        clientId: String,
        activityId: String,
        speakerName: String,
        liveActivityStyleRaw: String?
    ) async throws {
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

    // MARK: - Live Activity preferences

    /// App-owned presentation preferences. Playback metadata and audio quality
    /// are intentionally not sent here; the relay owns those snapshots.
    struct LiveActivityPreferencesBody: Encodable, Sendable {
        let groupId: String
        let liveActivityStyleRaw: String?
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
