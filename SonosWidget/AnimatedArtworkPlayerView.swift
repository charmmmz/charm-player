import AVFoundation
import SwiftUI
import UIKit

struct AnimatedArtworkPlayerView: UIViewRepresentable {
    let url: URL
    var isPlaying: Bool
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var onReadyForDisplay: (() -> Void)?

    func makeUIView(context: Context) -> AnimatedArtworkPlayerLayerView {
        let view = AnimatedArtworkPlayerLayerView()
        view.configure(
            url: url,
            videoGravity: videoGravity,
            onReadyForDisplay: onReadyForDisplay
        )
        return view
    }

    func updateUIView(_ view: AnimatedArtworkPlayerLayerView, context: Context) {
        view.configure(
            url: url,
            videoGravity: videoGravity,
            onReadyForDisplay: onReadyForDisplay
        )
        if isPlaying {
            view.player?.play()
        } else {
            view.player?.pause()
        }
    }

    static func dismantleUIView(
        _ view: AnimatedArtworkPlayerLayerView,
        coordinator: ()
    ) {
        view.stop()
    }
}

struct FullScreenAnimatedArtworkExtensionBackdrop: View {
    let size: CGSize
    let videoAspectRatio: CGFloat?

    var body: some View {
        let backdropSize = AnimatedArtworkFeature.fullScreenExtensionBackdropSize(
            containerSize: size
        )
        let start = AnimatedArtworkFeature.fullScreenExtensionBackdropStartLocation(
            containerSize: size,
            videoAspectRatio: videoAspectRatio
        )

        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: max(0, start - 0.14)),
                .init(color: .black.opacity(0.28), location: start),
                .init(color: .black.opacity(0.76), location: min(0.9, start + 0.18)),
                .init(color: .black.opacity(0.98), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: backdropSize.width, height: backdropSize.height)
    }
}

final class AnimatedArtworkPlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    private(set) var player: AVQueuePlayer? {
        get { playerLayer.player as? AVQueuePlayer }
        set { playerLayer.player = newValue }
    }

    private(set) var configuredURL: URL?
    private(set) var configuredVideoGravity: AVLayerVideoGravity = .resizeAspectFill
    private var looper: AVPlayerLooper?
    private var readyObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
    }

    func configure(
        url: URL,
        videoGravity: AVLayerVideoGravity = .resizeAspectFill,
        onReadyForDisplay: (() -> Void)?
    ) {
        playerLayer.videoGravity = videoGravity
        configuredVideoGravity = videoGravity
        guard configuredURL != url else { return }
        configuredURL = url

        readyObservation = nil
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                onReadyForDisplay?()
            }
        }
    }

    func stop() {
        player?.pause()
        player = nil
        looper = nil
        readyObservation = nil
        configuredURL = nil
        configuredVideoGravity = .resizeAspectFill
    }
}
