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

    static func shouldPlayDisplayedTracks(trackCount: Int) -> Bool {
        trackCount > 0
    }
}
