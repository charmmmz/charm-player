import Foundation

enum LocalMusicAlbumDetailPresentation {
    private static let animatedArtworkRetryDelays: [UInt64] = [
        400_000_000,
        1_000_000_000,
        2_000_000_000,
        3_500_000_000,
        5_000_000_000
    ]

    static func shouldShowCompleteAlbumButton(
        currentAlbumID: String,
        currentTrackCount: Int,
        completeAlbumID: String?,
        completeTrackCount: Int?
    ) -> Bool {
        guard let completeAlbumID,
              let completeTrackCount,
              !completeAlbumID.isEmpty,
              completeAlbumID != currentAlbumID else {
            return false
        }
        return completeTrackCount > currentTrackCount
    }

    static func playbackAlbumID(
        currentAlbumID: String,
        completeAlbumID _: String?
    ) -> String {
        currentAlbumID
    }

    static func shouldPlayDisplayedTracks(
        currentAlbumID: String,
        currentTrackCount: Int,
        completeAlbumID: String?,
        completeTrackCount: Int?
    ) -> Bool {
        guard currentTrackCount > 0,
              isLibraryAlbumID(currentAlbumID),
              shouldShowCompleteAlbumButton(
                currentAlbumID: currentAlbumID,
                currentTrackCount: currentTrackCount,
                completeAlbumID: completeAlbumID,
                completeTrackCount: completeTrackCount
              ) else {
            return false
        }
        return true
    }

    static func animatedArtworkLookupID(
        currentAlbumID: String,
        title: String,
        artist: String,
        completeCatalogAlbumID: String?
    ) -> String {
        [
            currentAlbumID,
            title,
            artist,
            completeCatalogAlbumID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].joined(separator: "|")
    }

    static func preferredAnimatedArtworkCatalogID(
        currentPlayableCatalogID: String?,
        completeCatalogAlbumID: String?
    ) -> String? {
        if let completeCatalogAlbumID,
           let catalogID = LocalMusicAppleMusicURL.publicCatalogID(
            from: completeCatalogAlbumID,
            kind: .album
           ) {
            return catalogID
        }

        if let currentPlayableCatalogID {
            return LocalMusicAppleMusicURL.publicCatalogID(
                from: currentPlayableCatalogID,
                kind: .album
            )
        }

        return nil
    }

    static func animatedArtworkRetryDelayNanoseconds(
        afterFailedAttempt failedAttempt: Int,
        hasAnimatedArtwork: Bool
    ) -> UInt64? {
        guard !hasAnimatedArtwork,
              failedAttempt >= 0,
              failedAttempt < animatedArtworkRetryDelays.count else {
            return nil
        }
        return animatedArtworkRetryDelays[failedAttempt]
    }

    static func shouldClearAnimatedArtworkBeforeLookup(isEnabled: Bool) -> Bool {
        !isEnabled
    }

    static func animatedArtworkInfoAfterCacheLookup(
        current: AnimatedArtworkInfo?,
        cached: AnimatedArtworkInfo?,
        isEnabled: Bool
    ) -> AnimatedArtworkInfo? {
        guard isEnabled else { return nil }
        return cached ?? current
    }

    static func shouldResolveAnimatedArtwork(
        albumURL: URL?,
        title: String,
        artist: String,
        isEnabled: Bool
    ) -> Bool {
        guard isEnabled else { return false }
        guard meaningfulMetadataValue(title) != nil,
              meaningfulMetadataValue(artist) != nil else {
            return false
        }
        return true
    }

    static func animatedArtworkHeaderURL(
        info: AnimatedArtworkInfo?,
        isEnabled: Bool
    ) -> URL? {
        AlbumAnimatedArtworkPresentation.headerURL(
            info: info,
            isEnabled: isEnabled
        )
    }

    static func animatedArtworkHeaderURL(
        info: AnimatedArtworkInfo?,
        isEnabled: Bool,
        isImmersiveLayoutActive: Bool
    ) -> URL? {
        AlbumAnimatedArtworkPresentation.headerURL(
            info: info,
            isEnabled: isEnabled,
            isImmersiveLayoutActive: isImmersiveLayoutActive
        )
    }

    static func animatedArtworkBackgroundURL(
        info: AnimatedArtworkInfo?,
        isEnabled: Bool
    ) -> URL? {
        AlbumAnimatedArtworkPresentation.fullScreenBackgroundURL(
            info: info,
            isEnabled: isEnabled
        )
    }

    private static func isLibraryAlbumID(_ id: String) -> Bool {
        id.hasPrefix("l.")
    }

    private static func meaningfulMetadataValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "—",
              trimmed.localizedCaseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        return trimmed
    }
}
