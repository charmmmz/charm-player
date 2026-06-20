import Foundation
import MusicKit

struct PlaybackArtworkRequest: Sendable {
    let service: PlaybackArtworkService
    let kind: LocalServiceAppleMusicPlayable.Kind
    let catalogID: String?
    let title: String
    let artist: String
    let album: String
    let currentArtworkURLString: String?
    let identity: PlaybackArtworkIdentity
    let countryCode: String?
}

struct AppleMusicPlaybackArtworkResolver {
    typealias RegistryLookup = (PlaybackArtworkRequest) async -> String?
    typealias MusicKitDirectLookup = (LocalServiceAppleMusicPlayable.Kind, String) async throws -> String?
    typealias MusicKitSearchLookup = (PlaybackArtworkRequest) async throws -> String?
    typealias ITunesLookup = (String, String?) async throws -> String?
    typealias ITunesSearch = (PlaybackArtworkRequest) async throws -> String?
    typealias SonosCloudArtworkLookup = (PlaybackArtworkRequest) async throws -> String?

    static let shared = AppleMusicPlaybackArtworkResolver()

    private let cache: PlaybackArtworkURLCache
    private let registryLookup: RegistryLookup
    private let musicKitIsAuthorized: () -> Bool
    private let musicKitDirectLookup: MusicKitDirectLookup
    private let musicKitSearchLookup: MusicKitSearchLookup
    private let iTunesLookup: ITunesLookup
    private let iTunesSearch: ITunesSearch
    private let sonosCloudArtworkLookup: SonosCloudArtworkLookup

    init(
        cache: PlaybackArtworkURLCache = .shared,
        registryLookup: @escaping RegistryLookup = { request in
            await MainActor.run {
                PlaybackArtworkRegistry.shared.artworkURLString(for: request.identity)
            }
        },
        musicKitIsAuthorized: @escaping () -> Bool = {
            MusicAuthorization.currentStatus == .authorized
        },
        musicKitDirectLookup: @escaping MusicKitDirectLookup = { kind, catalogID in
            try await AppleMusicCatalogSearchClient.shared.artworkURLString(
                kind: kind,
                catalogID: catalogID
            )
        },
        musicKitSearchLookup: @escaping MusicKitSearchLookup = { request in
            let term = LocalMusicCatalogMatcher.searchTerm(
                kind: request.kind,
                title: request.title,
                artist: request.artist,
                album: request.album
            )
            guard !term.isEmpty else { return nil }
            let items = try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: 8)
            return LocalMusicCatalogArtworkFallback.artworkURLString(
                in: items,
                kind: request.kind,
                title: request.title,
                artist: request.artist,
                album: request.album
            )
        },
        iTunesLookup: @escaping ITunesLookup = { catalogID, countryCode in
            try await AppleMusicITunesArtworkClient.shared.lookupArtworkURLString(
                catalogID: catalogID,
                countryCode: countryCode
            )
        },
        iTunesSearch: @escaping ITunesSearch = { request in
            try await AppleMusicITunesArtworkClient.shared.searchArtworkURLString(
                kind: request.kind,
                title: request.title,
                artist: request.artist,
                album: request.album,
                countryCode: request.countryCode
            )
        },
        sonosCloudArtworkLookup: @escaping SonosCloudArtworkLookup = { _ in nil }
    ) {
        self.cache = cache
        self.registryLookup = registryLookup
        self.musicKitIsAuthorized = musicKitIsAuthorized
        self.musicKitDirectLookup = musicKitDirectLookup
        self.musicKitSearchLookup = musicKitSearchLookup
        self.iTunesLookup = iTunesLookup
        self.iTunesSearch = iTunesSearch
        self.sonosCloudArtworkLookup = sonosCloudArtworkLookup
    }

    func resolve(request: PlaybackArtworkRequest) async -> PlaybackArtworkResolution? {
        guard request.service == .appleMusic else {
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver skipped service=\(request.service.rawValue)")
            return nil
        }

        SonosLog.debug(
            .playbackLink,
            "Playback artwork resolver start service=\(request.service.rawValue) kind=\(request.kind) " +
                "catalogID=\(SonosLog.playbackLinkValue(request.catalogID, maxLength: 120)) " +
                "title='\(SonosLog.playbackLinkValue(request.title, maxLength: 120))' " +
                "current=\(artworkState(request.currentArtworkURLString))")

        if let existing = normalizedPublicArtworkURLString(request.currentArtworkURLString) {
            cache.storeURLString(
                existing,
                service: request.service,
                source: .existingPublic,
                identity: request.identity
            )
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver hit stage=existing_public " +
                    "url=\(SonosLog.playbackLinkValue(existing, maxLength: 240))")
            return PlaybackArtworkResolution(urlString: existing, source: .existingPublic)
        }

        if let cached = cache.cachedURL(for: request.identity, service: request.service) {
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver hit stage=persistent_cache source=\(cached.source.rawValue) " +
                    "url=\(SonosLog.playbackLinkValue(cached.urlString, maxLength: 240))")
            return PlaybackArtworkResolution(urlString: cached.urlString, source: .persistentCache)
        }

        if let registryURL = normalizedPublicArtworkURLString(await registryLookup(request)) {
            cache.storeURLString(
                registryURL,
                service: request.service,
                source: .registry,
                identity: request.identity
            )
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver hit stage=registry " +
                    "url=\(SonosLog.playbackLinkValue(registryURL, maxLength: 240))")
            return PlaybackArtworkResolution(urlString: registryURL, source: .registry)
        }
        SonosLog.debug(.playbackLink, "Playback artwork resolver miss stage=registry")

        if musicKitIsAuthorized() {
            if let direct = await musicKitDirectArtworkURL(request) {
                store(direct, source: .musicKitDirect, request: request)
                return PlaybackArtworkResolution(urlString: direct, source: .musicKitDirect)
            }

            if let searched = await musicKitSearchArtworkURL(request) {
                store(searched, source: .musicKitSearch, request: request)
                return PlaybackArtworkResolution(urlString: searched, source: .musicKitSearch)
            }
        } else {
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver skip stage=musicKit reason=unauthorized_or_not_determined")
        }

        if let lookup = await iTunesLookupArtworkURL(request) {
            store(lookup, source: .iTunesLookup, request: request)
            return PlaybackArtworkResolution(urlString: lookup, source: .iTunesLookup)
        }

        if let searched = await iTunesSearchArtworkURL(request) {
            store(searched, source: .iTunesSearch, request: request)
            return PlaybackArtworkResolution(urlString: searched, source: .iTunesSearch)
        }

        if let sonosCloud = await sonosCloudArtworkURL(request) {
            store(sonosCloud, source: .sonosCloud, request: request)
            return PlaybackArtworkResolution(urlString: sonosCloud, source: .sonosCloud)
        }

        SonosLog.debug(.playbackLink, "Playback artwork resolver miss all stages")
        return nil
    }

    private func musicKitDirectArtworkURL(_ request: PlaybackArtworkRequest) async -> String? {
        guard let catalogID = nonEmpty(request.catalogID) else {
            SonosLog.debug(.playbackLink, "Playback artwork resolver skip stage=musicKit_direct reason=missing_catalog_id")
            return nil
        }

        do {
            let urlString = try await musicKitDirectLookup(request.kind, catalogID)
                .flatMap(normalizedPublicArtworkURLString)
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver \(urlString == nil ? "miss" : "hit") stage=musicKit_direct " +
                    "url=\(SonosLog.playbackLinkValue(urlString, maxLength: 240))")
            return urlString
        } catch {
            SonosLog.debug(.playbackLink, "Playback artwork resolver failed stage=musicKit_direct error=\(error)")
            return nil
        }
    }

    private func musicKitSearchArtworkURL(_ request: PlaybackArtworkRequest) async -> String? {
        do {
            let urlString = try await musicKitSearchLookup(request)
                .flatMap(normalizedPublicArtworkURLString)
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver \(urlString == nil ? "miss" : "hit") stage=musicKit_search " +
                    "url=\(SonosLog.playbackLinkValue(urlString, maxLength: 240))")
            return urlString
        } catch {
            SonosLog.debug(.playbackLink, "Playback artwork resolver failed stage=musicKit_search error=\(error)")
            return nil
        }
    }

    private func iTunesLookupArtworkURL(_ request: PlaybackArtworkRequest) async -> String? {
        guard let catalogID = nonEmpty(request.catalogID) else {
            SonosLog.debug(.playbackLink, "Playback artwork resolver skip stage=itunes_lookup reason=missing_catalog_id")
            return nil
        }

        do {
            let urlString = try await iTunesLookup(catalogID, request.countryCode)
                .flatMap(normalizedPublicArtworkURLString)
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver \(urlString == nil ? "miss" : "hit") stage=itunes_lookup " +
                    "url=\(SonosLog.playbackLinkValue(urlString, maxLength: 240))")
            return urlString
        } catch {
            SonosLog.debug(.playbackLink, "Playback artwork resolver failed stage=itunes_lookup error=\(error)")
            return nil
        }
    }

    private func iTunesSearchArtworkURL(_ request: PlaybackArtworkRequest) async -> String? {
        do {
            let urlString = try await iTunesSearch(request)
                .flatMap(normalizedPublicArtworkURLString)
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver \(urlString == nil ? "miss" : "hit") stage=itunes_search " +
                    "url=\(SonosLog.playbackLinkValue(urlString, maxLength: 240))")
            return urlString
        } catch {
            SonosLog.debug(.playbackLink, "Playback artwork resolver failed stage=itunes_search error=\(error)")
            return nil
        }
    }

    private func sonosCloudArtworkURL(_ request: PlaybackArtworkRequest) async -> String? {
        do {
            let urlString = try await sonosCloudArtworkLookup(request)
                .flatMap(normalizedPublicArtworkURLString)
            SonosLog.debug(
                .playbackLink,
                "Playback artwork resolver \(urlString == nil ? "miss" : "hit") stage=sonos_cloud " +
                    "url=\(SonosLog.playbackLinkValue(urlString, maxLength: 240))")
            return urlString
        } catch {
            SonosLog.debug(.playbackLink, "Playback artwork resolver failed stage=sonos_cloud error=\(error)")
            return nil
        }
    }

    private func store(
        _ urlString: String,
        source: PlaybackArtworkResolutionSource,
        request: PlaybackArtworkRequest
    ) {
        cache.storeURLString(
            urlString,
            service: request.service,
            source: source,
            identity: request.identity
        )
    }

    private func normalizedPublicArtworkURLString(_ value: String?) -> String? {
        guard let normalized = ArtworkURLNormalizer.loadableURLString(
            from: value,
            preserveExistingAppleArtworkSize: true
        ),
              !QueueArtPrefetchPolicy.isLocalSonosArtworkURL(normalized) else {
            return nil
        }
        return normalized
    }

    private func artworkState(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "missing" }
        if QueueArtPrefetchPolicy.isLocalSonosArtworkURL(trimmed) {
            return "local_getaa"
        }
        if normalizedPublicArtworkURLString(trimmed) != nil {
            return "public"
        }
        return "unsupported"
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
