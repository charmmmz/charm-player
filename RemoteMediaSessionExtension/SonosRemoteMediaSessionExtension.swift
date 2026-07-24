import CryptoKit
import ExtensionFoundation
import Foundation
import NowPlaying
import Observation

@main
@available(iOSApplicationExtension 27.0, *)
struct SonosRemoteMediaSessionExtension: RemoteMediaSessionExtension {
    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(
        _ attributes: SonosRemoteMediaSessionAttributes
    ) async throws -> SonosRemoteMediaSessionRepresentation {
        let representation = SonosRemoteMediaSessionRepresentation(attributes: attributes)
        representation.startObservingPushToken()
        Task {
            await SonosRemoteMediaSessionRelayClient.report(
                level: "info",
                message: "session-create session=\(attributes.id) "
                    + "animated=\(attributes.animatedArtworkURLString == nil ? "no" : "yes") "
                    + attributes.deviceDiagnostic,
                attributes: attributes
            )
        }
        return representation
    }
}

@available(iOSApplicationExtension 27.0, *)
@MainActor
@Observable
final class SonosRemoteMediaSessionRepresentation: RemoteMediaSessionRepresentable {
    private static let updateTokenRegistrations = SonosRemoteRegistrationLedger(
        defaults: .standard,
        storageKey: "remote-media-update-token-registrations-v2",
        refreshInterval: 15 * 60
    )

    private var attributes: SonosRemoteMediaSessionAttributes
    private(set) var devices: [MediaDevice]
    @ObservationIgnored private var pushTokenTask: Task<Void, Never>?
    @ObservationIgnored private var pushTokenRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var registeredPushTokenKey: String?
    @ObservationIgnored private var registeredSessionGeneration: String?
    @ObservationIgnored private var lastContentDiagnosticKey: String?

    init(attributes: SonosRemoteMediaSessionAttributes) {
        self.attributes = attributes
        self.devices = []
        self.devices = makeMediaDevices(from: attributes)
    }

    func startObservingPushToken() {
        guard pushTokenTask == nil else { return }
        pushTokenTask = Task { [weak self] in
            await Task.yield()
            await self?.observePushTokens()
        }
        startPushTokenRecoveryIfNeeded()
    }

    var id: String { attributes.id }

    var content: (any MediaContentRepresentable)? {
        reportContentEvaluationIfNeeded()
        let duration: MediaDuration = attributes.isLiveStream
            ? .live
            : .finite(attributes.duration)
        let contentID = SonosRemoteIdentifier.make(
            prefix: "content",
            values: [attributes.id, attributes.trackID]
        )
        guard let artwork else {
            return MusicContent(
                id: contentID,
                songTitle: attributes.title,
                artistName: attributes.artist,
                albumName: attributes.album,
                type: .audio,
                duration: duration,
                artwork: nil
            )
        }
        return MusicContent(
            id: contentID,
            songTitle: attributes.title,
            artistName: attributes.artist,
            albumName: attributes.album,
            type: .audio,
            duration: duration,
            artwork: artwork,
            animatedArtwork: animatedArtwork
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        MediaPlaybackSnapshot(
            state: attributes.isPlaying ? .playing() : .paused,
            elapsedTime: attributes.isLiveStream ? nil : attributes.elapsedTime,
            timestamp: Date(timeIntervalSince1970: attributes.timestamp)
        )
    }

    var commands: [MediaCommand] {
        var result: [MediaCommand] = [
            attributes.isPlaying
                ? .pause { [weak self] in try await self?.perform("pause", playing: false) }
                : .play { [weak self] in try await self?.perform("play", playing: true) }
        ]
        if !attributes.isLiveStream {
            result.append(.previous { [weak self] in try await self?.perform("previous") })
            result.append(.next { [weak self] in try await self?.perform("next") })
        }
        return result
    }

    private func makeMediaDevices(
        from attributes: SonosRemoteMediaSessionAttributes
    ) -> [MediaDevice] {
        let members = attributes.devices ?? []
        guard !members.isEmpty else {
            let currentVolume = attributes.volume
            return [
                MediaDevice(
                    id: attributes.groupID,
                    name: attributes.speakerName,
                    type: .speaker,
                    capabilities: [
                        .absoluteVolume(currentVolume) { [weak self] newLevel in
                            try await self?.setGroupVolume(newLevel)
                        }
                    ]
                )
            ]
        }

        return members.map { member in
            var capabilities: [MediaDevice.Capability] = []
            if let volume = member.volume {
                capabilities.append(
                    .absoluteVolume(volume) { [weak self] newLevel in
                        try await self?.setMemberVolume(newLevel, member: member)
                    }
                )
            }
            return MediaDevice(
                id: member.id,
                name: member.name,
                type: .speaker,
                capabilities: capabilities
            )
        }
    }

    func update(_ attributes: SonosRemoteMediaSessionAttributes) {
        let previousAnimated = self.attributes.animatedArtworkURLString
        self.attributes = attributes
        // Device membership can change without the track changing. Keep the
        // protocol requirement as a directly observable stored property so
        // NowPlaying receives an explicit mutation for grouping changes.
        devices = makeMediaDevices(from: attributes)
        Task {
            await SonosRemoteMediaSessionRelayClient.report(
                level: "info",
                message: "session-update session=\(attributes.id) track=\(attributes.trackID) "
                    + "animated=\(attributes.animatedArtworkURLString == nil ? "no" : "yes") "
                    + "animatedChanged=\(previousAnimated != attributes.animatedArtworkURLString) "
                    + attributes.deviceDiagnostic,
                attributes: attributes
            )
        }
        registerCurrentPushToken()
        startPushTokenRecoveryIfNeeded()
    }

    private func reportContentEvaluationIfNeeded() {
        let key = [
            attributes.trackID,
            attributes.animatedArtworkURLString ?? "-",
        ].joined(separator: "|")
        guard lastContentDiagnosticKey != key else { return }
        lastContentDiagnosticKey = key
        let diagnosticAttributes = attributes
        Task {
            await SonosRemoteMediaSessionRelayClient.report(
                level: "info",
                message: "content-evaluated session=\(diagnosticAttributes.id) "
                    + "track=\(diagnosticAttributes.trackID) "
                    + "animated=\(diagnosticAttributes.animatedArtworkURLString == nil ? "no" : "yes")",
                attributes: diagnosticAttributes
            )
        }
    }

    private var artworkCandidates: [String] {
        [
            attributes.artworkURLString,
            attributes.artworkFallbackURLString,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
    }

    private var artwork: Artwork? {
        let candidates = artworkCandidates
        guard !candidates.isEmpty else {
            return nil
        }
        let diagnosticAttributes = attributes
        let artworkID = SonosRemoteIdentifier.make(
            prefix: "artwork",
            values: [attributes.id] + candidates
        )
        return Artwork(id: artworkID) { size in
            try await SonosRemoteArtworkLoader.load(
                candidates: candidates,
                requestedSize: size,
                attributes: diagnosticAttributes
            )
        }
    }

    private var animatedArtwork: AnimatedArtwork? {
        guard !artworkCandidates.isEmpty,
              let playlistURL = animatedArtworkPlaylistURL else {
            return nil
        }

        let value = playlistURL.absoluteString
        let candidates = artworkCandidates
        let diagnosticAttributes = attributes
        return AnimatedArtwork(
            id: SonosRemoteIdentifier.make(
                prefix: "animated",
                values: [attributes.id, value]
            ),
            supportedAspectRatios: [.square],
            preview: { size, _ in
                try await SonosRemoteArtworkLoader.load(
                    candidates: candidates,
                    requestedSize: size,
                    attributes: diagnosticAttributes
                )
            },
            video: { size, _ in
                do {
                    // Diagnostics must never consume the system's bounded
                    // animated-artwork request window.
                    Task {
                        await SonosRemoteMediaSessionRelayClient.report(
                            level: "info",
                            message: "animated-request-start requested="
                                + "\(Int(size.width.rounded()))x\(Int(size.height.rounded())) "
                                + "host=\(playlistURL.host ?? "-")",
                            attributes: diagnosticAttributes
                        )
                    }
                    let localURL = try await SonosRemoteAnimatedArtworkCache.shared.videoURL(
                        for: playlistURL,
                        requestedSize: size
                    )
                    print("[NowPlaying] animated artwork ready file=\(localURL.lastPathComponent)")
                    Task {
                        await SonosRemoteMediaSessionRelayClient.report(
                            level: "info",
                            message: "animated-ready file=\(localURL.lastPathComponent)",
                            attributes: diagnosticAttributes
                        )
                    }
                    return localURL
                } catch {
                    print("[NowPlaying] animated artwork failed url=\(playlistURL) error=\(error)")
                    Task {
                        await SonosRemoteMediaSessionRelayClient.report(
                            level: "error",
                            message: "animated-failed host=\(playlistURL.host ?? "-") error=\(error.localizedDescription)",
                            attributes: diagnosticAttributes
                        )
                    }
                    throw error
                }
            }
        )
    }

    private var animatedArtworkPlaylistURL: URL? {
        guard let value = attributes.animatedArtworkURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return URL(string: value)
    }

    private func observePushTokens() async {
        registerCurrentPushToken()
        for await token in pushTokenUpdates {
            guard !Task.isCancelled else { return }
            _ = await registerPushToken(token)
        }
    }

    private func startPushTokenRecoveryIfNeeded() {
        guard pushTokenRecoveryTask == nil,
              registeredPushTokenKey == nil
                || registeredSessionGeneration != attributes.sessionGeneration else { return }
        pushTokenRecoveryTask = Task { [self] in
            // The framework associates the returned representation with its
            // system session after session(_:) returns. Keep this bounded task
            // alive across that hand-off before reading the framework token.
            try? await Task.sleep(for: .milliseconds(250))
            await SonosRemoteMediaSessionRelayClient.report(
                category: "NowPlayingToken",
                level: "info",
                message: "observer-start session=\(attributes.id) "
                    + "generation=\(attributes.sessionGeneration ?? "-")",
                attributes: attributes
            )
            defer { pushTokenRecoveryTask = nil }
            for attempt in 0..<30 {
                guard !Task.isCancelled else { return }
                if let token = pushToken,
                   await registerPushToken(token) {
                    return
                }
                if attempt == 0 {
                    await SonosRemoteMediaSessionRelayClient.report(
                        category: "NowPlayingToken",
                        level: "info",
                        message: "waiting-for-token session=\(attributes.id)",
                        attributes: attributes
                    )
                }
                try? await Task.sleep(for: .seconds(1))
            }
            await SonosRemoteMediaSessionRelayClient.report(
                category: "NowPlayingToken",
                level: "error",
                message: "token-timeout session=\(attributes.id)",
                attributes: attributes
            )
        }
    }

    private func registerCurrentPushToken() {
        guard let token = pushToken else { return }
        Task { [weak self] in
            _ = await self?.registerPushToken(token)
        }
    }

    private func registerPushToken(_ token: Data) async -> Bool {
        guard let relayURLString = attributes.relayURLString else { return false }
        let registrationKey = SonosRemoteRegistrationKey.make(
            token: token,
            values: [
                attributes.id,
                attributes.sessionGeneration ?? "legacy-session",
                attributes.groupID,
                attributes.clientID,
                relayURLString,
            ]
        )
        if registeredPushTokenKey == registrationKey {
            return true
        }
        let decision = Self.updateTokenRegistrations.begin(key: registrationKey)
        switch decision {
        case .register:
            break
        case .recent:
            registeredPushTokenKey = registrationKey
            registeredSessionGeneration = attributes.sessionGeneration
            print(
                "[NowPlaying] skipped duplicate update token registration "
                + "session=\(attributes.id) reason=\(decision)"
            )
            return true
        case .inFlight:
            return false
        }
        do {
            try await SonosRemoteMediaSessionRelayClient.register(
                token: token,
                kind: .update,
                attributes: attributes
            )
            Self.updateTokenRegistrations.complete(key: registrationKey, succeeded: true)
            registeredPushTokenKey = registrationKey
            registeredSessionGeneration = attributes.sessionGeneration
            print("[NowPlaying] registered remote media update token session=\(attributes.id)")
            await SonosRemoteMediaSessionRelayClient.report(
                category: "NowPlayingToken",
                level: "info",
                message: "registered session=\(attributes.id) "
                    + "generation=\(attributes.sessionGeneration ?? "-")",
                attributes: attributes
            )
            return true
        } catch {
            Self.updateTokenRegistrations.complete(key: registrationKey, succeeded: false)
            print("[NowPlaying] remote media update token registration failed error=\(error)")
            await SonosRemoteMediaSessionRelayClient.report(
                category: "NowPlayingToken",
                level: "error",
                message: "registration-failed session=\(attributes.id) "
                    + "error=\(error.localizedDescription)",
                attributes: attributes
            )
            return false
        }
    }

    private func perform(_ command: String, playing: Bool? = nil) async throws {
        try await SonosRemoteCommandClient.send(
            command,
            attributes: attributes,
            commandToken: pushToken
        )
        if let playing {
            attributes.isPlaying = playing
            attributes.timestamp = Date.now.timeIntervalSince1970
        }
    }

    private func setGroupVolume(_ level: Float) async throws {
        let clamped = min(max(level, 0), 1)
        try await SonosRemoteCommandClient.send(
            "setGroupVolume",
            volume: Int((clamped * 100).rounded()),
            attributes: attributes,
            commandToken: pushToken
        )
        attributes.volume = clamped
    }

    private func setMemberVolume(
        _ level: Float,
        member: SonosRemoteMediaDeviceAttributes
    ) async throws {
        let clamped = min(max(level, 0), 1)
        try await SonosRemoteCommandClient.send(
            "setMemberVolume",
            volume: Int((clamped * 100).rounded()),
            memberID: member.id,
            memberHost: member.host,
            attributes: attributes,
            commandToken: pushToken
        )
        if let index = attributes.devices?.firstIndex(where: { $0.id == member.id }) {
            attributes.devices?[index].volume = clamped
        }
    }
}

@available(iOSApplicationExtension 27.0, *)
private extension SonosRemoteMediaSessionAttributes {
    var deviceDiagnostic: String {
        let names = (devices ?? []).map(\.name)
        return "devices=\(names.count)[\(names.joined(separator: "|"))]"
    }
}

@available(iOSApplicationExtension 27.0, *)
private enum SonosRemoteArtworkLoader {
    static func load(
        candidates: [String],
        requestedSize: CGSize,
        attributes: SonosRemoteMediaSessionAttributes
    ) async throws -> ArtworkRepresentation {
        var lastError: Error = URLError(.badURL)
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            do {
                let cached = try await SonosRemoteArtworkDataCache.shared.data(for: url)
                let representation: ArtworkRepresentation
                do {
                    representation = try ArtworkRepresentation(data: cached.data)
                } catch {
                    await SonosRemoteArtworkDataCache.shared.remove(url)
                    throw error
                }
                let requestedWidth = Int(requestedSize.width.rounded())
                let requestedHeight = Int(requestedSize.height.rounded())
                print(
                    "[NowPlaying] artwork \(cached.source) bytes=\(cached.data.count) "
                    + "requested=\(requestedWidth)x\(requestedHeight) host=\(url.host ?? "-")"
                )
                if cached.source == .network {
                    await SonosRemoteMediaSessionRelayClient.report(
                        level: "info",
                        message: "network-load bytes=\(cached.data.count) "
                            + "requested=\(requestedWidth)x\(requestedHeight) "
                            + "host=\(url.host ?? "-") session=\(attributes.id)",
                        attributes: attributes
                    )
                }
                return representation
            } catch {
                lastError = error
                print("[NowPlaying] artwork load failed url=\(url.absoluteString) error=\(error)")
                await SonosRemoteMediaSessionRelayClient.report(
                    level: "error",
                    message: "failed host=\(url.host ?? "-") error=\(error.localizedDescription)",
                    attributes: attributes
                )
            }
        }
        throw lastError
    }

}

@available(iOSApplicationExtension 27.0, *)
private enum SonosRemoteIdentifier {
    static func make(prefix: String, values: [String]) -> String {
        let digest = SHA256.hash(data: Data(values.joined(separator: "\u{1F}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)-\(digest.prefix(24))"
    }
}

@available(iOSApplicationExtension 27.0, *)
private enum SonosRemoteCommandClient {
    private struct RelayBody: Encodable {
        let groupId: String
        let token: String
        let command: String
        let volume: Int?
        let memberId: String?
    }

    static func send(
        _ command: String,
        volume: Int? = nil,
        memberID: String? = nil,
        memberHost: String? = nil,
        attributes: SonosRemoteMediaSessionAttributes,
        commandToken: Data? = nil
    ) async throws {
        do {
            if try await sendViaRelay(
                command,
                volume: volume,
                memberID: memberID,
                attributes: attributes,
                commandToken: commandToken
            ) {
                return
            }
        } catch {
            // The speaker may still be reachable on the LAN when the relay is not.
        }
        try await sendDirectly(
            command,
            volume: volume,
            groupID: attributes.groupID,
            memberHost: memberHost
        )
    }

    private static func sendViaRelay(
        _ command: String,
        volume: Int?,
        memberID: String?,
        attributes: SonosRemoteMediaSessionAttributes,
        commandToken: Data?
    ) async throws -> Bool {
        guard let rawURL = attributes.relayURLString,
              let token = commandToken?.hexString ?? attributes.relayCommandToken,
              !token.isEmpty,
              let baseURL = URL(string: rawURL) else {
            return false
        }
        let endpoint = baseURL.appendingPathComponent("api/live-activity-command")
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RelayBody(
                groupId: attributes.groupID,
                token: token,
                command: command,
                volume: volume,
                memberId: memberID
            )
        )
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return true
    }

    private static func sendDirectly(
        _ command: String,
        volume: Int?,
        groupID: String,
        memberHost: String?
    ) async throws {
        let service: String
        let action: String
        let path: String
        let body: String

        switch command {
        case "play":
            service = "AVTransport"
            action = "Play"
            path = "/MediaRenderer/AVTransport/Control"
            body = "<InstanceID>0</InstanceID><Speed>1</Speed>"
        case "pause":
            service = "AVTransport"
            action = "Pause"
            path = "/MediaRenderer/AVTransport/Control"
            body = "<InstanceID>0</InstanceID>"
        case "next":
            service = "AVTransport"
            action = "Next"
            path = "/MediaRenderer/AVTransport/Control"
            body = "<InstanceID>0</InstanceID>"
        case "previous":
            service = "AVTransport"
            action = "Previous"
            path = "/MediaRenderer/AVTransport/Control"
            body = "<InstanceID>0</InstanceID>"
        case "setGroupVolume":
            service = "GroupRenderingControl"
            action = "SetGroupVolume"
            path = "/MediaRenderer/GroupRenderingControl/Control"
            body = "<InstanceID>0</InstanceID><DesiredVolume>\(volume ?? 0)</DesiredVolume>"
        case "setMemberVolume":
            service = "RenderingControl"
            action = "SetVolume"
            path = "/MediaRenderer/RenderingControl/Control"
            body = "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(volume ?? 0)</DesiredVolume>"
        default:
            throw URLError(.unsupportedURL)
        }

        let targetHost = command == "setMemberVolume" ? memberHost : groupID
        guard let targetHost,
              let url = URL(string: "http://\(targetHost):1400\(path)") else {
            throw URLError(.badURL)
        }
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(body)</u:\(action)></s:Body>
        </s:Envelope>
        """
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:\(service):1#\(action)\"",
            forHTTPHeaderField: "SOAPACTION"
        )
        request.httpBody = Data(envelope.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
