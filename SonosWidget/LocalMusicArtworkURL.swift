import Foundation
import MusicKit

nonisolated enum LocalMusicArtworkURL {
    enum ContentMode: Equatable {
        case fit
        case fill
    }

    struct RequestSize: Equatable {
        let width: Int
        let height: Int
    }

    struct DisplaySize: Equatable {
        let width: Double
        let height: Double
    }

    static func url(for artwork: Artwork, shortSidePixels: Int) -> URL? {
        let size = fittedRequestSize(
            maximumWidth: artwork.maximumWidth,
            maximumHeight: artwork.maximumHeight,
            shortSidePixels: shortSidePixels)
        return artwork.url(width: size.width, height: size.height).flatMap {
            loadableURL(from: $0, shortSidePixels: shortSidePixels)
        }
    }

    static func imageDownloadURL(for artwork: Artwork, shortSidePixels: Int) -> URL? {
        let size = fittedRequestSize(
            maximumWidth: artwork.maximumWidth,
            maximumHeight: artwork.maximumHeight,
            shortSidePixels: shortSidePixels)
        return artwork.url(width: size.width, height: size.height).flatMap {
            imageDownloadURL(from: $0, shortSidePixels: shortSidePixels)
        }
    }

    static func imageDownloadURL(from url: URL, shortSidePixels: Int? = nil) -> URL? {
        if let loadableURL = loadableURL(from: url, shortSidePixels: shortSidePixels) {
            return loadableURL
        }

        guard url.scheme?.lowercased() == "musickit" else {
            return nil
        }
        return url
    }

    static func loadableURL(from url: URL, shortSidePixels: Int? = nil) -> URL? {
        if LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(url.absoluteString) {
            return resizedAppleArtworkURL(url, shortSidePixels: shortSidePixels)
        }

        guard let appleArtworkURL = appleArtworkURL(fromMusicKitArtworkURL: url) else {
            return nil
        }
        return resizedAppleArtworkURL(appleArtworkURL, shortSidePixels: shortSidePixels)
    }

    static func loadableURLString(from value: String?, shortSidePixels: Int? = nil) -> String? {
        guard let value, let url = URL(string: value) else { return nil }
        return loadableURL(from: url, shortSidePixels: shortSidePixels)?.absoluteString
    }

    static func fittedRequestSize(
        maximumWidth: Int,
        maximumHeight: Int,
        shortSidePixels: Int
    ) -> RequestSize {
        let requestedShortSide = max(1, shortSidePixels)
        guard maximumWidth > 1, maximumHeight > 1 else {
            return RequestSize(width: requestedShortSide, height: requestedShortSide)
        }

        let sourceWidth = maximumWidth
        let sourceHeight = maximumHeight
        let shortSide = max(1, min(requestedShortSide, min(sourceWidth, sourceHeight)))

        if sourceWidth == sourceHeight {
            return RequestSize(width: shortSide, height: shortSide)
        }

        if sourceWidth > sourceHeight {
            let width = min(sourceWidth, Int((Double(shortSide) * Double(sourceWidth) / Double(sourceHeight)).rounded()))
            return RequestSize(width: max(1, width), height: shortSide)
        }

        let height = min(sourceHeight, Int((Double(shortSide) * Double(sourceHeight) / Double(sourceWidth)).rounded()))
        return RequestSize(width: shortSide, height: max(1, height))
    }

    static func fittedDisplaySize(
        maximumWidth: Int,
        maximumHeight: Int,
        boundingWidth: Double,
        boundingHeight: Double
    ) -> DisplaySize {
        let boundsWidth = max(1, boundingWidth)
        let boundsHeight = max(1, boundingHeight)
        guard maximumWidth > 1, maximumHeight > 1 else {
            return DisplaySize(width: boundsWidth, height: boundsHeight)
        }

        let sourceAspectRatio = Double(maximumWidth) / Double(maximumHeight)
        let boundsAspectRatio = boundsWidth / boundsHeight

        if sourceAspectRatio > boundsAspectRatio {
            return DisplaySize(width: boundsWidth, height: boundsWidth / sourceAspectRatio)
        }

        return DisplaySize(width: boundsHeight * sourceAspectRatio, height: boundsHeight)
    }

    static func filledDisplaySize(
        maximumWidth: Int,
        maximumHeight: Int,
        boundingWidth: Double,
        boundingHeight: Double
    ) -> DisplaySize {
        let boundsWidth = max(1, boundingWidth)
        let boundsHeight = max(1, boundingHeight)
        guard maximumWidth > 1, maximumHeight > 1 else {
            return DisplaySize(width: boundsWidth, height: boundsHeight)
        }

        let sourceAspectRatio = Double(maximumWidth) / Double(maximumHeight)
        let boundsAspectRatio = boundsWidth / boundsHeight

        if sourceAspectRatio > boundsAspectRatio {
            return DisplaySize(width: boundsHeight * sourceAspectRatio, height: boundsHeight)
        }

        return DisplaySize(width: boundsWidth, height: boundsWidth / sourceAspectRatio)
    }

    static func displaySize(
        maximumWidth: Int,
        maximumHeight: Int,
        boundingWidth: Double,
        boundingHeight: Double,
        contentMode: ContentMode
    ) -> DisplaySize {
        switch contentMode {
        case .fit:
            return fittedDisplaySize(
                maximumWidth: maximumWidth,
                maximumHeight: maximumHeight,
                boundingWidth: boundingWidth,
                boundingHeight: boundingHeight)
        case .fill:
            return filledDisplaySize(
                maximumWidth: maximumWidth,
                maximumHeight: maximumHeight,
                boundingWidth: boundingWidth,
                boundingHeight: boundingHeight)
        }
    }

    private static func appleArtworkURL(fromMusicKitArtworkURL url: URL) -> URL? {
        guard url.scheme?.lowercased() == "musickit",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let artworkURLString = components.queryItems?.first(where: {
                  $0.name.lowercased() == "aat"
              })?.value else {
            return nil
        }

        let trimmed = artworkURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let artworkURL = URL(string: trimmed),
           LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(artworkURL.absoluteString) {
            return artworkURL
        }

        guard let artworkURL = appleArtworkURL(fromRelativeArtworkPath: trimmed),
              LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(artworkURL.absoluteString) else {
            return nil
        }
        return artworkURL
    }

    private static func appleArtworkURL(fromRelativeArtworkPath value: String) -> URL? {
        var path = (value.removingPercentEncoding ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty,
              !path.contains(".."),
              !path.localizedCaseInsensitiveContains("://") else {
            return nil
        }

        if path.hasPrefix("image/thumb/") {
            path.removeFirst("image/thumb/".count)
        }

        guard path.split(separator: "/").count > 1,
              path.range(
                  of: #"(?:\.(?:jpg|jpeg|png|webp)|/\d+x\d+bb(?:\.[a-z0-9]+)?)$"#,
                  options: [.regularExpression, .caseInsensitive]
              ) != nil else {
            return nil
        }

        if path.range(of: #"/\d+x\d+bb(\.[^/]+)?$"#, options: .regularExpression) == nil {
            path += "/600x600bb.jpg"
        }

        let fullPath = "/image/thumb/\(path)"
        guard let encodedPath = fullPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "is1-ssl.mzstatic.com"
        components.percentEncodedPath = encodedPath
        return components.url
    }

    private static func resizedAppleArtworkURL(_ url: URL, shortSidePixels: Int?) -> URL {
        guard let shortSidePixels, shortSidePixels > 0,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var path = components.percentEncodedPath
        guard let range = path.range(
            of: #"/\d+x\d+bb(\.[^/]+)?$"#,
            options: .regularExpression
        ) else {
            return url
        }

        let matchedComponent = String(path[range])
        let suffix: String
        if let dotIndex = matchedComponent.lastIndex(of: ".") {
            suffix = String(matchedComponent[dotIndex...])
        } else {
            suffix = ""
        }
        path.replaceSubrange(range, with: "/\(shortSidePixels)x\(shortSidePixels)bb\(suffix)")
        components.percentEncodedPath = path
        return components.url ?? url
    }
}
