import Foundation
import NowPlaying

extension SonosManager {
    func manageRemoteMediaSession() {
        guard #available(iOS 27.0, *) else { return }

        guard let speaker = selectedSpeaker,
              let trackInfo,
              !trackInfo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              transportState == .playing || transportState == .paused else {
            SonosRemoteMediaSessionController.shared.end()
            return
        }

        let groupID = speaker.playbackIP
        let trackID = trackInfo.trackURI?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? [trackInfo.title, trackInfo.artist, trackInfo.album].joined(separator: "|")
        let duration = max(durationSeconds, trackInfo.durationSeconds)
        let elapsed = min(max(positionSeconds, 0), duration > 0 ? duration : .greatestFiniteMagnitude)
        let relayURLString = RelayManager.shared.appExtensionURLString(
            preferredPeerHost: groupID
        )
        let artworkURLs = remoteMediaSessionArtworkURLs(
            sourceURLString: trackInfo.source == .tv ? nil : trackInfo.albumArtURL,
            relayURLString: relayURLString
        )
        let devices = remoteMediaSessionDevices(fallbackSpeaker: speaker)
        let isTVSource = trackInfo.source == .tv
        let sessionID = "sonos-v20:\(groupID)"
        let attributes = SonosRemoteMediaSessionAttributes(
            // Bump the session namespace when the extension representation or
            // Codable contract changes so iOS doesn't reuse a cached process.
            id: sessionID,
            sessionGeneration: SonosRemoteMediaSessionGenerationStore.generation(
                for: sessionID
            ),
            groupID: groupID,
            speakerName: speaker.name,
            devices: devices,
            trackID: trackID,
            title: isTVSource ? "TV Audio" : trackInfo.title,
            artist: isTVSource
                ? trackInfo.tvFormat?.displayLabel ?? trackInfo.artist
                : trackInfo.artist,
            album: isTVSource ? "" : trackInfo.album,
            artworkURLString: artworkURLs.primary,
            artworkFallbackURLString: artworkURLs.fallback,
            animatedArtworkURLString: nil,
            playbackSourceRaw: trackInfo.source.rawValue,
            isLiveStream: isTVSource || trackInfo.isLiveStream,
            isPlaying: transportState == .playing,
            elapsedTime: isTVSource ? 0 : elapsed,
            duration: isTVSource ? 0 : duration,
            timestamp: positionFetchedAt.timeIntervalSince1970,
            volume: Float(min(max(volume, 0), 100)) / 100,
            clientID: SharedStorage.liveActivityRelayClientID,
            relayURLString: relayURLString,
            relayCommandToken: SharedStorage.liveActivityRelayPushToken(for: groupID)
        )
        SonosRemoteMediaSessionController.shared.sync(attributes)
    }

    @available(iOS 27.0, *)
    private func remoteMediaSessionDevices(
        fallbackSpeaker: SonosPlayer
    ) -> [SonosRemoteMediaDeviceAttributes] {
        let members = currentGroupMembers.isEmpty ? [fallbackSpeaker] : currentGroupMembers
        var seen = Set<String>()

        return members.compactMap { member in
            let stableID = member.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = member.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = stableID.isEmpty ? host : stableID
            guard !identity.isEmpty, seen.insert(identity).inserted else { return nil }

            let memberVolume = memberVolumes[host]
                ?? (member.id == fallbackSpeaker.id ? volume : nil)
            return SonosRemoteMediaDeviceAttributes(
                id: identity,
                name: member.name,
                host: host.nilIfEmpty,
                volume: memberVolume.map { Float(min(max($0, 0), 100)) / 100 }
            )
        }
    }
}

private func remoteMediaSessionArtworkURLs(
    sourceURLString: String?,
    relayURLString: String?
) -> (primary: String?, fallback: String?) {
    guard let source = sourceURLString?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !source.isEmpty else {
        return (nil, nil)
    }
    guard source.localizedCaseInsensitiveContains("/getaa"),
          let relayURLString,
          let relayURL = URL(string: relayURLString),
          let proxyURL = RelayClient.artworkProxyURL(
              baseURL: relayURL,
              sourceURLString: source
          ) else {
        return (source, nil)
    }
    return (proxyURL.absoluteString, source)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@available(iOS 27.0, *)
@MainActor
private final class SonosRemoteMediaSessionController {
    static let shared = SonosRemoteMediaSessionController()

    private enum Request {
        case active(SonosRemoteMediaSessionAttributes)
        case pushManaged(SonosRemoteMediaSessionAttributes)
        case ended
    }

    private var session: RemoteMediaSession<SonosRemoteMediaSessionAttributes>?
    private var lastPublishedAttributes: SonosRemoteMediaSessionAttributes?
    private var pendingRequest: Request?
    private var syncTask: Task<Void, Never>?
    private var pushToStartTask: Task<Void, Never>?
    private var latestAttributes: SonosRemoteMediaSessionAttributes?
    private var latestPushToStartToken: Data?
    private var startRegistrationState = SonosRemoteStartRegistrationState()
    private var pushManagedSessionID: String?
    private var deferredEndTask: Task<Void, Never>?

    func sync(_ attributes: SonosRemoteMediaSessionAttributes) {
        deferredEndTask?.cancel()
        deferredEndTask = nil
        latestAttributes = attributes
        observePushToStartTokensIfNeeded()
        if attributes.relayURLString != nil {
            enqueue(.pushManaged(attributes))
        } else {
            enqueue(.active(attributes))
        }
    }

    func end() {
        guard deferredEndTask == nil else { return }
        // Sonos briefly publishes an empty transport/metadata snapshot while
        // changing tracks and during foreground reconciliation. Ending the
        // system session immediately in that gap rotates the generation while
        // the old RemoteMediaSession representation is still alive, causing
        // its valid update token to be rejected as stale by the relay.
        deferredEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.deferredEndTask = nil
            self.latestAttributes = nil
            self.startRegistrationState.resetStartRequest()
            self.enqueue(.ended)
        }
    }

    private func observePushToStartTokensIfNeeded() {
        guard pushToStartTask == nil else { return }
        pushToStartTask = Task { [weak self] in
            for await token in RemoteMediaSession<SonosRemoteMediaSessionAttributes>
                .pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                self?.pushToStartTokenDidUpdate(token)
            }
        }
    }

    private func pushToStartTokenDidUpdate(_ token: Data) {
        latestPushToStartToken = token
        guard let latestAttributes, latestAttributes.relayURLString != nil else { return }
        enqueue(.pushManaged(latestAttributes))
    }

    private func registerCurrentPushToStartToken(requestStart: Bool) async -> Bool {
        guard let token = latestPushToStartToken
            ?? RemoteMediaSession<SonosRemoteMediaSessionAttributes>.pushToStartToken else {
            return false
        }
        return await registerPushToStartToken(token, requestStart: requestStart)
    }

    private func registerPushToStartToken(_ token: Data, requestStart: Bool) async -> Bool {
        guard let attributes = latestAttributes,
              attributes.relayURLString != nil else { return false }
        let key = [
            token.base64EncodedString(),
            attributes.id,
            attributes.groupID,
            attributes.clientID,
            attributes.speakerName,
            attributes.relayURLString ?? "",
        ].joined(separator: "|")
        guard startRegistrationState.shouldRegister(
            key: key,
            requestStart: requestStart
        ) else { return true }
        do {
            try await SonosRemoteMediaSessionRelayClient.register(
                token: token,
                kind: .start,
                attributes: attributes,
                requestStart: requestStart
            )
            startRegistrationState.recordSuccess(key: key, requestStart: requestStart)
            SonosLog.info(
                .nowPlaying,
                "registered remote media push-to-start token requestStart=\(requestStart)"
            )
            return true
        } catch {
            SonosLog.error(
                .nowPlaying,
                "remote media push-to-start registration failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func enqueue(_ request: Request) {
        pendingRequest = request
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            await self?.drainRequests()
        }
    }

    private func drainRequests() async {
        while let request = pendingRequest {
            pendingRequest = nil
            do {
                switch request {
                case .active(let attributes):
                    try await apply(attributes)
                case .pushManaged(let attributes):
                    try await preparePushManagedSession(attributes)
                case .ended:
                    try await endCurrentSession()
                }
            } catch {
                SonosLog.error(.nowPlaying, "remote media session failed: \(error.localizedDescription)")
            }
        }
        syncTask = nil
        if pendingRequest != nil {
            enqueue(pendingRequest!)
        }
    }

    private func apply(_ attributes: SonosRemoteMediaSessionAttributes) async throws {
        if session == nil {
            let existingSessions = try await RemoteMediaSession<SonosRemoteMediaSessionAttributes>
                .sessions()
            session = existingSessions.first { $0.id == attributes.id }
            for staleSession in existingSessions where staleSession.id != attributes.id {
                try await staleSession.end()
                SonosLog.info(
                    .nowPlaying,
                    "ended stale remote media session id=\(staleSession.id)"
                )
            }
        }
        if let current = session, current.id != attributes.id {
            try await current.end()
            session = nil
        }

        if let session {
            if let lastPublishedAttributes,
               lastPublishedAttributes.hasSameSignificantState(as: attributes) {
                return
            }
            try await session.update(attributes)
            lastPublishedAttributes = attributes
            SonosLog.debug(.nowPlaying, "remote media session updated id=\(attributes.id)")
            return
        }

        try await startNewSession(attributes)
    }

    private func startNewSession(_ attributes: SonosRemoteMediaSessionAttributes) async throws {
        let newSession = try await RemoteMediaSession.start(attributes: attributes)
        session = newSession
        lastPublishedAttributes = attributes
        do {
            try await newSession.requestToBecomeSystemPrimary()
        } catch {
            SonosLog.error(
                .nowPlaying,
                "remote media session could not become system primary: \(error.localizedDescription)"
            )
        }
        SonosLog.info(.nowPlaying, "remote media session started id=\(attributes.id)")
    }

    private func preparePushManagedSession(
        _ attributes: SonosRemoteMediaSessionAttributes
    ) async throws {
        if pushManagedSessionID == attributes.id {
            latestAttributes = attributes
            _ = await registerCurrentPushToStartToken(requestStart: false)
            SonosLog.debug(
                .nowPlaying,
                "remote media session remains delegated to relay id=\(attributes.id)"
            )
            return
        }

        if let current = session {
            try await current.end()
            SonosRemoteMediaSessionGenerationStore.end(sessionID: current.id)
            session = nil
            lastPublishedAttributes = nil
        }

        if session == nil {
            let existingSessions = try await RemoteMediaSession<SonosRemoteMediaSessionAttributes>
                .sessions()
            SonosLog.debug(
                .nowPlaying,
                "remote media relay reconciliation desired=\(attributes.id) existing=\(existingSessions.map(\.id).joined(separator: ","))"
            )
            let isRecoveringMatchingSession = existingSessions.contains { $0.id == attributes.id }
            for existingSession in existingSessions {
                try await existingSession.end()
                SonosLog.info(
                    .nowPlaying,
                    "ended existing remote media session during reconciliation id=\(existingSession.id)"
                )
            }
            if isRecoveringMatchingSession {
                SonosLog.info(
                    .nowPlaying,
                    "recreating persisted remote media session after process recovery id=\(attributes.id)"
                )
            }
        }

        // RemoteMediaSession.start() can return successfully after a reboot
        // without instantiating the extension representation. In that state no
        // per-session update token is ever issued and metadata freezes. Ask the
        // relay to create the replacement through APNs push-to-start instead;
        // that path reliably launches the extension and yields its update token.
        latestAttributes = attributes
        startRegistrationState.resetStartRequest()
        if await registerCurrentPushToStartToken(requestStart: true) {
            pushManagedSessionID = attributes.id
            SonosLog.info(
                .nowPlaying,
                "remote media session start delegated to relay id=\(attributes.id)"
            )
        }
    }

    private func endCurrentSession() async throws {
        if session == nil {
            session = try await RemoteMediaSession.sessions().first
        }
        guard let session else {
            pushManagedSessionID = nil
            return
        }
        try await session.end()
        SonosRemoteMediaSessionGenerationStore.end(sessionID: session.id)
        self.session = nil
        pushManagedSessionID = nil
        lastPublishedAttributes = nil
        SonosLog.info(.nowPlaying, "remote media session ended")
    }

    private func attributesWithInitialAnimatedArtwork(
        _ attributes: SonosRemoteMediaSessionAttributes
    ) async -> SonosRemoteMediaSessionAttributes {
        guard attributes.animatedArtworkURLString == nil,
              let relayURLString = attributes.relayURLString,
              let relayURL = URL(string: relayURLString),
              !attributes.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !attributes.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return attributes
        }

        do {
            let response = try await RelayClient.animatedArtworkSearch(
                baseURL: relayURL,
                artist: attributes.artist,
                album: attributes.album
            )
            guard response.status == .hit,
                  let squareURLString = response.squareURLString else {
                SonosLog.debug(
                    .nowPlaying,
                    "remote media initial animated artwork unavailable status=\(response.status.rawValue)"
                )
                return attributes
            }
            var enriched = attributes
            enriched.animatedArtworkURLString = squareURLString
            SonosLog.info(
                .nowPlaying,
                "remote media initial animated artwork attached source=\(response.source ?? "-")"
            )
            return enriched
        } catch {
            SonosLog.error(
                .nowPlaying,
                "remote media initial animated artwork lookup failed: \(error.localizedDescription)"
            )
            return attributes
        }
    }
}

@available(iOS 27.0, *)
private enum SonosRemoteMediaSessionGenerationStore {
    private static let defaultsKey = "remote-media-session-generations-v1"

    static func generation(for sessionID: String) -> String {
        var generations = UserDefaults.standard.dictionary(forKey: defaultsKey)
            as? [String: String] ?? [:]
        if let existing = generations[sessionID] {
            return existing
        }
        let generation = UUID().uuidString.lowercased()
        generations[sessionID] = generation
        UserDefaults.standard.set(generations, forKey: defaultsKey)
        return generation
    }

    static func end(sessionID: String) {
        var generations = UserDefaults.standard.dictionary(forKey: defaultsKey)
            as? [String: String] ?? [:]
        guard generations.removeValue(forKey: sessionID) != nil else { return }
        UserDefaults.standard.set(generations, forKey: defaultsKey)
    }
}

@available(iOS 27.0, *)
private extension SonosRemoteMediaSessionAttributes {
    func hasSameSignificantState(as other: Self) -> Bool {
        id == other.id
            && sessionGeneration == other.sessionGeneration
            && groupID == other.groupID
            && speakerName == other.speakerName
            && devices == other.devices
            && trackID == other.trackID
            && title == other.title
            && artist == other.artist
            && album == other.album
            && artworkURLString == other.artworkURLString
            && artworkFallbackURLString == other.artworkFallbackURLString
            && playbackSourceRaw == other.playbackSourceRaw
            && isLiveStream == other.isLiveStream
            && isPlaying == other.isPlaying
            && duration == other.duration
            && volume == other.volume
            && clientID == other.clientID
            && relayURLString == other.relayURLString
            && relayCommandToken == other.relayCommandToken
    }
}
