import SwiftUI

struct AlbumPrimaryActionBar: View {
    let favoriteKind: AlbumFavoriteKind
    let tint: Color?
    let isPlayActive: Bool
    let isShuffleActive: Bool
    let isFavoriteActive: Bool
    let isFavoriteBusy: Bool
    let isFavoriteDisabled: Bool
    let isPlaybackDisabled: Bool
    let play: () -> Void
    let shuffle: () -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let metrics = AlbumPrimaryActionBarMetrics(width: geometry.size.width)

            HStack(spacing: metrics.spacing) {
                AlbumCircleActionButton(
                    systemImage: "shuffle",
                    accessibilityTitle: "Shuffle",
                    tint: tint,
                    isActive: isShuffleActive,
                    isDisabled: isPlaybackDisabled || isShuffleActive,
                    dimension: metrics.circleDimension,
                    action: shuffle
                )

                Button(action: play) {
                    HStack(spacing: 8) {
                        if isPlayActive {
                            ProgressView()
                                .controlSize(.regular)
                                .tint(.black)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.headline.weight(.bold))
                        }

                        Text("Play")
                            .font(.headline.weight(.bold))
                    }
                    .frame(width: metrics.playWidth, height: metrics.playHeight)
                    .foregroundStyle(.black.opacity(0.86))
                    .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isPlaybackDisabled || isPlayActive)
                .opacity((isPlaybackDisabled || isPlayActive) ? 0.45 : 1)
                .accessibilityLabel("Play")

                AlbumCircleActionButton(
                    systemImage: isFavoriteActive ? "heart.fill" : "heart",
                    accessibilityTitle: AlbumPrimaryAction.favorite(favoriteKind).accessibilityTitle,
                    accessibilityValue: favoriteAccessibilityValue,
                    tint: tint,
                    isActive: isFavoriteBusy,
                    isDisabled: isFavoriteDisabled || isFavoriteBusy,
                    dimension: metrics.circleDimension,
                    action: toggleFavorite
                )
            }
            .padding(.horizontal, metrics.horizontalPadding)
        }
        .frame(height: AlbumPrimaryActionBarMetrics.maximumHeight)
    }

    private var favoriteAccessibilityValue: String {
        if isFavoriteBusy {
            return "Loading"
        }

        return isFavoriteActive ? "Favorited" : "Not Favorited"
    }
}

private struct AlbumCircleActionButton: View {
    let systemImage: String
    let accessibilityTitle: String
    var accessibilityValue: String? = nil
    let tint: Color?
    let isActive: Bool
    let isDisabled: Bool
    let dimension: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill((tint ?? .white).opacity(0.18))
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }

                if isActive {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(width: dimension, height: dimension)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityValue ?? "")
    }
}

private struct AlbumPrimaryActionBarMetrics {
    static let maximumHeight: CGFloat = 64

    let circleDimension: CGFloat
    let horizontalPadding: CGFloat = 16
    let playHeight: CGFloat = 56
    let playWidth: CGFloat
    let spacing: CGFloat

    init(width: CGFloat) {
        circleDimension = width < 360 ? 56 : 64
        spacing = width < 360 ? 18 : 30

        let remainingWidth = width
            - (horizontalPadding * 2)
            - (circleDimension * 2)
            - (spacing * 2)

        playWidth = min(max(remainingWidth, 0), 184)
    }
}
