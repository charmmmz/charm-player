import Foundation

@MainActor
struct LocalMusicAlbumAnimatedArtworkResolver {
    typealias RelayURLLookup = @Sendable (URL) async throws -> RelayClient.AnimatedArtworkResponse
    typealias RelayMetadataLookup = @Sendable (String, String) async throws -> RelayClient.AnimatedArtworkResponse

    private let registry: AnimatedArtworkRegistry
    private let relayURLLookup: RelayURLLookup
    private let relayMetadataLookup: RelayMetadataLookup
    private let now: @Sendable () -> Date

    init(
        registry: AnimatedArtworkRegistry,
        relayURLLookup: @escaping RelayURLLookup,
        relayMetadataLookup: @escaping RelayMetadataLookup,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry
        self.relayURLLookup = relayURLLookup
        self.relayMetadataLookup = relayMetadataLookup
        self.now = now
    }

    init(
        relayBaseURL: URL,
        registry: AnimatedArtworkRegistry,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            registry: registry,
            relayURLLookup: { albumURL in
                try await RelayClient.animatedArtworkByURL(
                    baseURL: relayBaseURL,
                    albumURL: albumURL
                )
            },
            relayMetadataLookup: { artist, album in
                try await RelayClient.animatedArtworkSearch(
                    baseURL: relayBaseURL,
                    artist: artist,
                    album: album,
                    countryCode: "us"
                )
            },
            now: now
        )
    }

    func resolve(
        albumURL: URL?,
        title: String,
        artist: String
    ) async -> AnimatedArtworkInfo? {
        let normalizedTitle = meaningfulMetadataValue(title)
        let normalizedArtist = meaningfulMetadataValue(artist)

        if let cached = registry.artwork(
            appleMusicURLString: albumURL?.absoluteString,
            artist: normalizedArtist,
            album: normalizedTitle
        ) {
            return cached
        }

        if let albumURL,
           let info = await resolveByURL(
            albumURL,
            fallbackArtist: normalizedArtist,
            fallbackAlbum: normalizedTitle
           ) {
            return info
        }

        guard let normalizedTitle,
              let normalizedArtist else {
            return nil
        }

        return await resolveByMetadata(
            title: normalizedTitle,
            artist: normalizedArtist,
            fallbackAppleMusicURLString: albumURL?.absoluteString
        )
    }

    private func resolveByURL(
        _ albumURL: URL,
        fallbackArtist: String?,
        fallbackAlbum: String?
    ) async -> AnimatedArtworkInfo? {
        do {
            let response = try await relayURLLookup(albumURL)
            return registerInfo(
                response: response,
                fallbackAppleMusicURLString: albumURL.absoluteString,
                fallbackArtist: fallbackArtist,
                fallbackAlbum: fallbackAlbum
            )
        } catch {
            SonosLog.debug(
                .albumDetail,
                "Local Music animated album artwork URL lookup failed " +
                    "url='\(albumURL.absoluteString)' error=\(error)"
            )
            return nil
        }
    }

    private func resolveByMetadata(
        title: String,
        artist: String,
        fallbackAppleMusicURLString: String?
    ) async -> AnimatedArtworkInfo? {
        do {
            let response = try await relayMetadataLookup(artist, title)
            return registerInfo(
                response: response,
                fallbackAppleMusicURLString: fallbackAppleMusicURLString,
                fallbackArtist: artist,
                fallbackAlbum: title
            )
        } catch {
            SonosLog.debug(
                .albumDetail,
                "Local Music animated album artwork metadata lookup failed " +
                    "title='\(title)' artist='\(artist)' error=\(error)"
            )
            return nil
        }
    }

    private func registerInfo(
        response: RelayClient.AnimatedArtworkResponse,
        fallbackAppleMusicURLString: String?,
        fallbackArtist: String?,
        fallbackAlbum: String?
    ) -> AnimatedArtworkInfo? {
        guard let info = AnimatedArtworkInfo(
            response: response,
            fallbackAppleMusicURLString: fallbackAppleMusicURLString,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum,
            resolvedAt: now()
        ) else {
            return nil
        }
        registry.register(info)
        return info
    }

    private func meaningfulMetadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "—",
              trimmed.localizedCaseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        return trimmed
    }
}
