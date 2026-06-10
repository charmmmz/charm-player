import MusicKit
import SwiftUI

struct LocalMusicArtworkView: View {
    let artwork: Artwork
    let diagnosticLabel: String?

    @Environment(\.displayScale) private var displayScale

    init(artwork: Artwork, diagnosticLabel: String? = nil) {
        self.artwork = artwork
        self.diagnosticLabel = diagnosticLabel
    }

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
            let sourceDescription = "source=\(artwork.maximumWidth)x\(artwork.maximumHeight) " +
                "display=\(Int(displaySize.width))x\(Int(displaySize.height)) shortSide=\(shortSidePixels)"

            LocalMusicArtworkImage(
                artwork: artwork,
                width: CGFloat(displaySize.width),
                height: CGFloat(displaySize.height),
                url: imageURL,
                diagnosticLabel: diagnosticLabel,
                sourceDescription: sourceDescription)
            .frame(width: CGFloat(displaySize.width), height: CGFloat(displaySize.height))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct LocalMusicArtworkImage: View {
    let artwork: Artwork
    let width: CGFloat
    let height: CGFloat
    let url: URL?
    let diagnosticLabel: String?
    let sourceDescription: String

    @State private var didLogSource = false

    var body: some View {
        ArtworkImage(artwork, width: width, height: height)
            .aspectRatio(contentMode: .fit)
            .onAppear {
                logSourceIfNeeded()
            }
    }

    private func logSourceIfNeeded() {
        guard !didLogSource,
              let diagnosticLabel else {
            return
        }
        didLogSource = true
        SonosLog.debug(
            .localService,
            "MusicKit artwork source \(diagnosticLabel) \(sourceDescription) " +
                "url=\(Self.diagnosticURLStatus(url?.absoluteString))")
    }

    private static func diagnosticURLStatus(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        let status = LocalMusicArtworkURLStringValidator.isLoadableArtworkURLString(value) ? "loadable" : "not-loadable"
        return "\(status)('\(value)')"
    }
}
