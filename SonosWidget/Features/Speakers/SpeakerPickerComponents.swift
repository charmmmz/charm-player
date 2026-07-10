import SwiftUI
extension View {
    func cardChrome(isActive: Bool, accent: Color) -> some View {
        background {
            ZStack {
                RoundedRectangle(cornerRadius: SpeakerPickerCardLayout.cornerRadius)
                    .fill(.white.opacity(isActive ? 0.13 : 0.06))
                RoundedRectangle(cornerRadius: SpeakerPickerCardLayout.cornerRadius)
                    .fill(accent.opacity(isActive ? 0.24 : 0))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: SpeakerPickerCardLayout.cornerRadius)
                .stroke(isActive ? accent.opacity(0.98) : .white.opacity(0.14), lineWidth: 1.2)
        }
    }
}

struct SpeakerPickerWaveform: View {
    let isPlaying: Bool
    let color: Color

    @State private var animates = false

    private static let scales: [CGFloat] = [0.58, 1.0, 0.68, 0.92, 0.62]

    private var heights: [CGFloat] {
        isPlaying
            ? SharePlaybackWaveformLayout.activeHeights
            : SharePlaybackWaveformLayout.restingHeights
    }

    var body: some View {
        HStack(spacing: SharePlaybackWaveformLayout.barSpacing) {
            ForEach(heights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: SharePlaybackWaveformLayout.barWidth / 2)
                    .fill(color)
                    .frame(
                        width: SharePlaybackWaveformLayout.barWidth,
                        height: heights[index]
                    )
                    .scaleEffect(
                        y: isPlaying ? (animates ? Self.scales[index] : 1) : 1,
                        anchor: .center
                    )
                    .animation(
                        isPlaying
                            ? .easeInOut(duration: 0.58 + Double(index) * 0.05)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.06)
                            : .default,
                        value: animates
                    )
            }
        }
        .frame(
            width: SharePlaybackWaveformLayout.size.width,
            height: SharePlaybackWaveformLayout.size.height
        )
        .task(id: isPlaying) {
            animates = false
            guard isPlaying else { return }
            try? await Task.sleep(for: .milliseconds(50))
            animates = true
        }
    }
}

// MARK: - Volume Bar (tap left = −2, tap right = +2, matches Home page GroupVolumeBar)

struct PickerVolumeBar: View {
    var volume: Int
    var accent: Color
    var onStep: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let progress = min(max(Double(volume) / 100.0, 0), 1)
            let thumbX = geo.size.width * progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(height: 4)
                Capsule()
                    .fill(accent.opacity(0.78))
                    .frame(width: max(0, thumbX), height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { gesture in
                        guard abs(gesture.translation.width) < 6 else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onStep(gesture.startLocation.x < thumbX ? -2 : 2)
                    }
            )
        }
        .frame(height: 28)
    }
}
