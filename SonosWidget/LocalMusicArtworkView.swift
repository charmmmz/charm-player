import MusicKit
import SwiftUI

struct LocalMusicArtworkView: View {
    let artwork: Artwork

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let displaySize = LocalMusicArtworkURL.fittedDisplaySize(
                maximumWidth: artwork.maximumWidth,
                maximumHeight: artwork.maximumHeight,
                boundingWidth: Double(proxy.size.width),
                boundingHeight: Double(proxy.size.height)
            )
            let shortSidePixels = max(1, Int(min(displaySize.width, displaySize.height) * Double(displayScale)))
            let imageURL = LocalMusicArtworkURL.url(for: artwork, shortSidePixels: shortSidePixels)

            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: CGFloat(displaySize.width), height: CGFloat(displaySize.height))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
