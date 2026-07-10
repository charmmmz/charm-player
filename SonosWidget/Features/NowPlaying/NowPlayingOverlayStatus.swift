import AVFoundation
import SwiftUI
import UIKit

extension NowPlayingOverlay {

    // MARK: - Error Banner

    @ViewBuilder
    var errorBanner: some View {
        if manager.connectionState == .disconnected, let error = manager.errorMessage {
            VStack(spacing: 8) {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
                Button("Retry") { Task { await manager.refreshState() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.bottom, 8)
        }
    }
}

// MARK: - ThumblessSlider

/// - When `thumbDragOnly` is false: full-bar drag to any position (e.g. volume slider).
///   A short tap (< 6 pt movement) triggers `onStepTap` if provided, so the bar also
///   supports "tap left of thumb → −2, tap right of thumb → +2" without jumping.
/// - When `thumbDragOnly` is true: drag must start within `thumbTolerance` of the current
///   thumb; a tap anywhere else does nothing. A small thumb circle is shown.
struct ThumblessSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tintColor: Color = .white
    var trackHeight: CGFloat = 5
    var thumbDragOnly: Bool = false
    var thumbTolerance: CGFloat = 28
    /// Called with ±2 when the user taps left/right of the current position instead of dragging.
    var onStepTap: ((Int) -> Void)? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State var dragStartX: CGFloat = 0
    @State var dragStartValue: Double = 0
    @State var dragValid: Bool = false
    @State var hasDragged: Bool = false
    @State var lastHapticInteger: Int = Int.min

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let progress = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let thumbX = geo.size.width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tintColor.opacity(0.2))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(tintColor)
                    .frame(width: max(0, thumbX), height: trackHeight)
                if thumbDragOnly {
                    Circle()
                        .fill(tintColor)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .offset(x: max(0, thumbX - 6.5))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let moved = abs(gesture.translation.width) > 6
                        if thumbDragOnly {
                            if !dragValid {
                                let nearThumb = abs(gesture.startLocation.x - thumbX) <= thumbTolerance
                                if nearThumb && moved {
                                    dragValid = true
                                    hasDragged = true
                                    dragStartX = gesture.startLocation.x
                                    dragStartValue = value
                                    lastHapticInteger = Int(value)
                                }
                            }
                            guard dragValid else { return }
                            let delta = gesture.location.x - dragStartX
                            let pct = min(max(0, (dragStartValue - range.lowerBound) / span + delta / geo.size.width), 1)
                            value = range.lowerBound + pct * span
                            fireTickIfNeeded()
                            onEditingChanged(true)
                        } else {
                            if moved || hasDragged {
                                if !hasDragged { lastHapticInteger = Int(value) }
                                hasDragged = true
                                let pct = min(max(0, gesture.location.x / geo.size.width), 1)
                                value = range.lowerBound + pct * span
                                fireTickIfNeeded()
                                onEditingChanged(true)
                            }
                        }
                    }
                    .onEnded { gesture in
                        defer { dragValid = false; hasDragged = false; lastHapticInteger = Int.min }
                        if hasDragged {
                            onEditingChanged(false)
                        } else if let step = onStepTap {
                            // Short tap — left of thumb = −2, right = +2
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            let tapped = gesture.startLocation.x
                            step(tapped < thumbX ? -2 : 2)
                        }
                    }
            )
        }
        .frame(height: 28)
    }

    func fireTickIfNeeded() {
        let cur = Int(value)
        if cur != lastHapticInteger {
            lastHapticInteger = cur
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
