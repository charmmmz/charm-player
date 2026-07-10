import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit

extension LocalMusicAlbumDetailView {

    func loadDetails() async {
        guard detailedAlbum == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            detailedAlbum = try await LocalMusicLibraryClient.shared.albumDetails(for: album)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadCompleteCatalogAlbumIfNeeded() async {
        guard completeCatalogAlbum == nil else { return }

        do {
            let catalogAlbum = try await LocalMusicLibraryClient.shared.completeCatalogAlbumDetails(for: displayAlbum)
            guard !Task.isCancelled else { return }
            completeCatalogAlbum = catalogAlbum
            SonosLog.debug(
                .albumDetail,
                "Local Music complete album resolved current='\(displayAlbum.title)' " +
                    "currentID='\(displayAlbum.id.rawValue)' currentTracks=\(currentTrackCount) " +
                    "catalogID='\(catalogAlbum.id.rawValue)' catalogTracks=\(catalogAlbum.tracks?.count ?? catalogAlbum.trackCount)")
        } catch {
            guard !Task.isCancelled else { return }
            SonosLog.debug(
                .albumDetail,
                "Local Music complete album lookup skipped current='\(displayAlbum.title)' " +
                    "currentID='\(displayAlbum.id.rawValue)' error=\(error)")
        }
    }

    func loadCoverImage(from url: URL?) async {
        guard let url else {
            coverImage = nil
            themeColor = nil
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            let image = UIImage(data: data)
            coverImage = image
            if let uiColor = image?.dominantUIColor() {
                themeColor = AlbumThemeColorPolicy.mutedColor(from: uiColor)
            } else {
                themeColor = image?.dominantColor()?.opacity(0.55)
            }
        } catch {
            guard !Task.isCancelled else { return }
            SonosLog.error(.albumDetail, "Local Music cover image load failed: \(error)")
            coverImage = nil
            themeColor = nil
        }
    }

    func openAppleMusicFromTitle() {
        Task {
            guard let url = await resolveAppleMusicURLIfNeeded() else {
                SonosLog.debug(
                    .localService,
                    "Album Apple Music title tap has no resolved URL title='\(displayAlbum.title)' " +
                        "rawURL='\(displayAlbum.url?.absoluteString ?? "nil")' " +
                        "playableID='\(albumPlayable?.catalogID ?? "nil")'")
                return
            }
            openLocalMusicAppleMusicURL(url, context: "album-title title='\(displayAlbum.title)'")
        }
    }

    func toggleAppleMusicFavorite() {
        guard !isAppleMusicFavoriteBusy else { return }
        guard let resource = albumFavoriteResource else {
            SonosLog.debug(
                .localService,
                "Apple Music album favorite unavailable title='\(displayAlbum.title)' id='\(displayAlbum.id.rawValue)'")
            return
        }
        isAppleMusicFavoriteBusy = true
        let targetState = !isAppleMusicFavorited
        isAppleMusicFavorited = targetState

        Task { @MainActor in
            defer { isAppleMusicFavoriteBusy = false }
            do {
                if targetState {
                    try await searchManager.addToAppleMusicFavorites(resource: resource)
                } else {
                    try await searchManager.removeFromAppleMusicFavorites(resource: resource)
                }
                SonosLog.debug(
                    .localService,
                    "Apple Music album favorite updated title='\(displayAlbum.title)' " +
                        "resource='\(resource.id)' isFavorited=\(targetState)")
            } catch {
                isAppleMusicFavorited.toggle()
                SonosLog.error(
                    .localService,
                    "Apple Music album favorite failed title='\(displayAlbum.title)' " +
                        "resource='\(resource.id)' target=\(targetState) error=\(error)")
            }
        }
    }

    func toggleAppleMusicTrackFavorite(_ track: Track) {
        guard let resource = favoriteResource(for: track) else {
            SonosLog.debug(
                .localService,
                "Apple Music track favorite unavailable title='\(track.title)' id='\(track.id.rawValue)'")
            return
        }

        let trackID = track.id.rawValue
        let targetState = !appleMusicFavoritedTrackIDs.contains(trackID)
        if targetState {
            appleMusicFavoritedTrackIDs.insert(trackID)
        } else {
            appleMusicFavoritedTrackIDs.remove(trackID)
        }

        Task { @MainActor in
            do {
                if targetState {
                    try await searchManager.addToAppleMusicFavorites(resource: resource)
                } else {
                    try await searchManager.removeFromAppleMusicFavorites(resource: resource)
                }
                SonosLog.debug(
                    .localService,
                    "Apple Music track favorite updated title='\(track.title)' " +
                        "resource='\(resource.id)' isFavorited=\(targetState)")
            } catch {
                if targetState {
                    appleMusicFavoritedTrackIDs.remove(trackID)
                } else {
                    appleMusicFavoritedTrackIDs.insert(trackID)
                }
                SonosLog.error(
                    .localService,
                    "Apple Music track favorite failed title='\(track.title)' " +
                        "resource='\(resource.id)' target=\(targetState) error=\(error)")
            }
        }
    }

    func loadAppleMusicFavoriteState() async {
        guard let resource = albumFavoriteResource else {
            isAppleMusicFavorited = false
            return
        }

        do {
            isAppleMusicFavorited = try await searchManager.appleMusicFavoriteStatus(for: resource)
        } catch {
            SonosLog.debug(
                .localService,
                "Apple Music album favorite status skipped title='\(displayAlbum.title)' " +
                    "resource='\(resource.id)' error=\(error)")
        }
    }

    func loadAppleMusicTrackFavoriteStates() async {
        var favorited: Set<String> = []
        for track in tracks {
            guard !Task.isCancelled else { return }
            guard let resource = favoriteResource(for: track) else { continue }
            do {
                if try await searchManager.appleMusicFavoriteStatus(for: resource) {
                    favorited.insert(track.id.rawValue)
                }
            } catch {
                SonosLog.debug(
                    .localService,
                    "Apple Music album track favorite status skipped title='\(track.title)' " +
                        "resource='\(resource.id)' error=\(error)")
            }
        }

        guard !Task.isCancelled else { return }
        appleMusicFavoritedTrackIDs = favorited
    }

    func favoriteResource(for track: Track) -> AppleMusicFavoriteResource? {
        AppleMusicFavoriteResource.fromLocalServicePlayable(
            LocalServiceAppleMusicPlayable.make(track: track)
        )
    }

    @discardableResult
    func resolveAppleMusicURLIfNeeded() async -> URL? {
        if let appleMusicURL { return appleMusicURL }

        if let catalogID = LocalMusicAlbumDetailPresentation.preferredAnimatedArtworkCatalogID(
            currentPlayableCatalogID: albumPlayable?.catalogID,
            completeCatalogAlbumID: completeCatalogAlbum?.id.rawValue
        ) {
            do {
                let urlString = try await AppleMusicCatalogSearchClient.shared.appleMusicURLString(
                    kind: LocalMusicAppleMusicURL.Kind.album,
                    catalogID: catalogID)
                if let urlString,
                   let url = URL(string: urlString),
                   let resolved = LocalMusicAppleMusicURL.externalURL(
                    existingURL: nil,
                    catalogURL: url,
                    kind: .album
                   ) {
                    guard !Task.isCancelled else { return nil }
                    SonosLog.debug(
                        .localService,
                        "Album Apple Music link resolved by catalog id title='\(displayAlbum.title)' " +
                            "catalogID='\(catalogID)' url='\(urlString)'")
                    catalogAppleMusicURL = resolved
                    return resolved
                }
            } catch {
                guard !Task.isCancelled else { return nil }
                SonosLog.debug(
                    .localService,
                    "Album Apple Music catalog id lookup failed title='\(displayAlbum.title)' " +
                        "catalogID='\(catalogID)' error=\(error)")
            }
        }

        let term = LocalMusicCatalogMatcher.searchTerm(
            kind: .album,
            title: displayAlbum.title,
            artist: displayAlbum.artistName,
            album: displayAlbum.title)
        guard !term.isEmpty else { return nil }

        do {
            let items = try await AppleMusicCatalogSearchClient.shared.search(term: term, limit: 8)
            let urlString = LocalMusicCatalogWebURLFallback.urlString(
                in: items,
                kind: .album,
                title: displayAlbum.title,
                artist: displayAlbum.artistName,
                album: displayAlbum.title,
                allowGeneratedFallback: true)
            guard !Task.isCancelled,
                  let urlString,
                  let url = URL(string: urlString),
                  let resolved = LocalMusicAppleMusicURL.externalURL(
                    existingURL: nil,
                    catalogURL: url,
                    kind: .album
                  ) else {
                SonosLog.debug(
                    .localService,
                    "Album Apple Music link search produced no usable URL title='\(displayAlbum.title)' term='\(term)'")
                return nil
            }

            SonosLog.debug(.localService, "Album Apple Music link resolved title='\(displayAlbum.title)' url='\(urlString)'")
            catalogAppleMusicURL = resolved
            return resolved
        } catch {
            guard !Task.isCancelled else { return nil }
            SonosLog.debug(.localService, "Album Apple Music link lookup failed title='\(displayAlbum.title)' error=\(error)")
            return nil
        }
    }

    @MainActor
    func refreshAnimatedArtworkUntilAvailable() async {
        if LocalMusicAlbumDetailPresentation.shouldClearAnimatedArtworkBeforeLookup(
            isEnabled: AnimatedArtworkFeature.isEnabled
        ) {
            setAnimatedArtworkInfo(nil)
        }

        var failedAttempt = 0
        while !Task.isCancelled {
            let isEligible = await refreshAnimatedArtworkAttempt()
            guard isEligible else { return }
            if animatedArtworkInfo != nil { return }

            guard let delay = LocalMusicAlbumDetailPresentation.animatedArtworkRetryDelayNanoseconds(
                afterFailedAttempt: failedAttempt,
                hasAnimatedArtwork: animatedArtworkInfo != nil
            ) else {
                return
            }

            failedAttempt += 1
            SonosLog.debug(
                .albumDetail,
                "Local Music animated album artwork retry scheduled " +
                    "title='\(displayAlbum.title)' artist='\(displayAlbum.artistName)' attempt=\(failedAttempt)")

            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
        }
    }

    @MainActor
    func refreshAnimatedArtworkAttempt() async -> Bool {
        let albumURL = appleMusicURL
        guard LocalMusicAlbumDetailPresentation.shouldResolveAnimatedArtwork(
                albumURL: albumURL,
                title: displayAlbum.title,
                artist: displayAlbum.artistName,
                isEnabled: AnimatedArtworkFeature.isEnabled
              ) else {
            return false
        }

        await prewarmAnimatedArtwork(albumURL: albumURL)
        return true
    }

    @MainActor
    func prewarmAnimatedArtwork(albumURL: URL?) async {
        guard AnimatedArtworkFeature.isEnabled,
              let relayBaseURL = RelayManager.shared.url else {
            applyCachedAnimatedArtwork(appleMusicURLString: albumURL?.absoluteString)
            return
        }

        applyCachedAnimatedArtwork(appleMusicURLString: albumURL?.absoluteString)
        if animatedArtworkInfo != nil { return }

        let resolver = LocalMusicAlbumAnimatedArtworkResolver(
            relayBaseURL: relayBaseURL,
            registry: .shared
        )
        if let info = await resolver.resolve(
            albumURL: albumURL,
            title: displayAlbum.title,
            artist: displayAlbum.artistName
        ) {
            setAnimatedArtworkInfo(info)
        }
    }

    @MainActor
    func applyCachedAnimatedArtwork(appleMusicURLString: String?) {
        guard AnimatedArtworkFeature.isEnabled else {
            setAnimatedArtworkInfo(nil)
            return
        }

        let cached = AnimatedArtworkRegistry.shared.artwork(
            appleMusicURLString: appleMusicURLString,
            artist: displayAlbum.artistName,
            album: displayAlbum.title
        )
        let next = LocalMusicAlbumDetailPresentation.animatedArtworkInfoAfterCacheLookup(
            current: animatedArtworkInfo,
            cached: cached,
            isEnabled: AnimatedArtworkFeature.isEnabled
        )
        setAnimatedArtworkInfo(next)
    }

    func setAnimatedArtworkInfo(_ next: AnimatedArtworkInfo?) {
        let shouldResetReadyState = AlbumAnimatedArtworkPresentation.shouldResetReadyState(
            current: animatedArtworkInfo,
            next: next
        )
        guard animatedArtworkInfo != next else { return }
        animatedArtworkInfo = next
        if shouldResetReadyState {
            animatedArtworkReadyURL = nil
            animatedArtworkBackgroundReadyURL = nil
        }
    }

}
