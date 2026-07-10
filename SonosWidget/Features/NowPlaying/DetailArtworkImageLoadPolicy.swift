import Foundation

enum DetailArtworkImageLoadPolicy {
    static func shouldKeepDisplayingLoadedImage(
        hasLoadedImage: Bool,
        selectedURL: String?,
        loadedURL: String?
    ) -> Bool {
        hasLoadedImage && selectedURL != nil && loadedURL != nil
    }

    static func shouldCommitLoadedImage(requestedURL: String, selectedURL: String?) -> Bool {
        requestedURL == selectedURL
    }
}
