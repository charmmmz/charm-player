import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit

extension LocalMusicAlbumDetailView {

    var detailBackground: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                staticDetailBackground

                if let url = animatedArtworkBackgroundURL {
                    albumAnimatedArtworkBackground(
                        url: url,
                        size: size
                    )
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .opacity(animatedArtworkBackgroundReadyURL == url ? 1 : 0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }

                albumBackgroundScrim
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.28), value: animatedArtworkBackgroundReadyURL)
    }

    var staticDetailBackground: some View {
        SonosArtworkBackground(
            image: coverImage ?? manager.albumArtImage,
            fallbackColor: themeColor ?? manager.albumArtDominantColor
        )
        .animation(.easeInOut(duration: 0.8), value: coverURL)
        .animation(.easeInOut(duration: 0.8), value: themeColor)
    }

    @ViewBuilder
    func albumAnimatedArtworkBackground(
        url: URL,
        size: CGSize
    ) -> some View {
        let containerAspectRatio = size.height > 0 ? size.width / size.height : 0
        let videoAspectRatio = animatedArtworkBackgroundAspectRatio
        let usesBlurFill = AnimatedArtworkFeature.shouldUseBlurFillForFullScreenArtwork(
            videoAspectRatio: videoAspectRatio,
            containerAspectRatio: containerAspectRatio
        )

        if usesBlurFill {
            albumAnimatedArtworkBlurFill(
                url: url,
                size: size,
                videoAspectRatio: videoAspectRatio
            )
        } else {
            AnimatedArtworkPlayerView(
                url: url,
                isPlaying: shouldPlayAnimatedArtworkVideo,
                videoGravity: .resizeAspectFill,
                onReadyForDisplay: {
                    markAnimatedArtworkBackgroundReady(url)
                }
            )
        }
    }

    func albumAnimatedArtworkBlurFill(
        url: URL,
        size: CGSize,
        videoAspectRatio: CGFloat?
    ) -> some View {
        let foregroundSize = AnimatedArtworkFeature.fullScreenBlurFillForegroundSize(
            containerSize: size,
            videoAspectRatio: videoAspectRatio
        )
        let foregroundTopOffset = AnimatedArtworkFeature.fullScreenBlurFillForegroundTopOffset(
            containerSize: size
        )

        return ZStack(alignment: .top) {
            FullScreenAnimatedArtworkExtensionBackdrop(
                size: size,
                videoAspectRatio: videoAspectRatio
            )

            AnimatedArtworkPlayerView(
                url: url,
                isPlaying: shouldPlayAnimatedArtworkVideo,
                videoGravity: .resizeAspect,
                onReadyForDisplay: {
                    markAnimatedArtworkBackgroundReady(url)
                }
            )
            .frame(width: foregroundSize.width, height: foregroundSize.height, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.54),
                        .init(color: .black.opacity(0.6), location: 0.72),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .offset(y: foregroundTopOffset)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }

    func markAnimatedArtworkBackgroundReady(_ url: URL) {
        if animatedArtworkBackgroundURL == url {
            animatedArtworkBackgroundReadyURL = url
        }
    }

    @ViewBuilder
    var albumBackgroundScrim: some View {
        if usesImmersiveAnimatedArtwork {
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.08), location: 0.0),
                        .init(color: .black.opacity(0.08), location: 0.36),
                        .init(color: .black.opacity(0.48), location: 0.58),
                        .init(color: .black.opacity(0.88), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.32)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.34),
                                .init(color: .black.opacity(0.35), location: 0.58),
                                .init(color: .black, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        } else {
            Color.clear
        }
    }

}
