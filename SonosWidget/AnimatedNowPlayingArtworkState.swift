import Combine
import Foundation
import UIKit

@MainActor
final class AnimatedNowPlayingArtworkState: ObservableObject {
    struct Identity: Equatable, Sendable {
        let trackURI: String?
        let title: String
        let artist: String
        let album: String
    }

    struct LookupRequest: Sendable {
        let relayBaseURL: URL
        let albumURL: URL?
        let artist: String
        let album: String
    }

    typealias RelayLookup = @Sendable (LookupRequest) async throws -> RelayClient.AnimatedArtworkResponse

    @Published private(set) var currentInfo: AnimatedArtworkInfo?
    @Published private(set) var currentURL: URL?

    private let registry: AnimatedArtworkRegistry
    private let relayLookup: RelayLookup
    private let now: @Sendable () -> Date
    private var activeIdentity: Identity?
    private var lookupTask: Task<Void, Never>?

    init(
        registry: AnimatedArtworkRegistry? = nil,
        relayLookup: RelayLookup? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry ?? .shared
        self.relayLookup = relayLookup ?? { request in
            if let albumURL = request.albumURL {
                return try await RelayClient.animatedArtworkByURL(
                    baseURL: request.relayBaseURL,
                    albumURL: albumURL
                )
            }
            return try await RelayClient.animatedArtworkSearch(
                baseURL: request.relayBaseURL,
                artist: request.artist,
                album: request.album,
                countryCode: "us"
            )
        }
        self.now = now
    }

    func reset() {
        lookupTask?.cancel()
        lookupTask = nil
        activeIdentity = nil
        currentInfo = nil
        currentURL = nil
    }

    func beginLookup(identity: Identity) {
        if activeIdentity != identity {
            currentInfo = nil
            currentURL = nil
        }
        activeIdentity = identity
    }

    func apply(info: AnimatedArtworkInfo, for identity: Identity) {
        guard activeIdentity == identity else { return }
        registry.register(info)
        currentInfo = info
        currentURL = info.playerURL
    }

    func resolve(
        identity: Identity,
        albumURL: URL?,
        relayBaseURL: URL?,
        source: PlaybackSource?,
        isReduceMotionEnabled: Bool? = nil,
        isLowPowerModeEnabled: Bool? = nil
    ) {
        lookupTask?.cancel()
        guard AnimatedArtworkFeature.canRenderVideo(
            source: source,
            isReduceMotionEnabled: isReduceMotionEnabled,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        ) else {
            reset()
            return
        }

        beginLookup(identity: identity)
        if let cached = registry.artwork(
            appleMusicURLString: albumURL?.absoluteString,
            artist: identity.artist,
            album: identity.album
        ) {
            apply(info: cached, for: identity)
            return
        }

        guard let relayBaseURL else { return }
        lookupTask = Task { [relayLookup, now, weak self] in
            do {
                let request = LookupRequest(
                    relayBaseURL: relayBaseURL,
                    albumURL: albumURL,
                    artist: identity.artist,
                    album: identity.album
                )
                let response = try await relayLookup(request)
                let fallbackAppleMusicURLString = albumURL?.absoluteString

                var info = AnimatedArtworkInfo(
                    response: response,
                    fallbackAppleMusicURLString: fallbackAppleMusicURLString,
                    fallbackArtist: identity.artist,
                    fallbackAlbum: identity.album,
                    resolvedAt: now()
                )

                if info == nil, albumURL != nil {
                    SonosLog.debug(
                        .nowPlaying,
                        "Animated artwork URL lookup missed; falling back to metadata search " +
                        "artist='\(identity.artist)' album='\(identity.album)' status=\(response.status.rawValue)"
                    )
                    let fallbackResponse = try await relayLookup(
                        LookupRequest(
                            relayBaseURL: relayBaseURL,
                            albumURL: nil,
                            artist: identity.artist,
                            album: identity.album
                        )
                    )
                    info = AnimatedArtworkInfo(
                        response: fallbackResponse,
                        fallbackAppleMusicURLString: fallbackAppleMusicURLString,
                        fallbackArtist: identity.artist,
                        fallbackAlbum: identity.album,
                        resolvedAt: now()
                    )
                }

                guard let info else {
                    SonosLog.debug(
                        .nowPlaying,
                        "Animated artwork lookup miss artist='\(identity.artist)' album='\(identity.album)'"
                    )
                    return
                }
                SonosLog.debug(
                    .nowPlaying,
                    "Animated artwork lookup hit artist='\(info.artist ?? identity.artist)' " +
                    "album='\(info.album ?? identity.album)' square=\(info.squareURLString != nil) tall=\(info.tallURLString != nil)"
                )
                await MainActor.run {
                    self?.apply(info: info, for: identity)
                }
            } catch {
                SonosLog.debug(.nowPlaying, "Animated artwork lookup failed error=\(error)")
            }
        }
    }

}
