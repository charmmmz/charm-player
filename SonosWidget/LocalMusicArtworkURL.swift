import Foundation
import MusicKit

enum LocalMusicArtworkURL {
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
        return artwork.url(width: size.width, height: size.height)
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
}
