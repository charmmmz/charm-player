import Foundation

enum LocalMusicAlbumDetailPresentation {
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

    private static func isLibraryAlbumID(_ id: String) -> Bool {
        id.hasPrefix("l.")
    }
}
