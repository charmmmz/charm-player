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

struct AlbumTrackRow<MenuContent: View>: View {
    let number: String
    let title: String
    let subtitle: String?
    let duration: String?
    let isExplicit: Bool
    let isPlaying: Bool
    let isDisabled: Bool
    let isLast: Bool
    let action: () -> Void

    private let menuContent: () -> MenuContent

    init(
        number: String,
        title: String,
        subtitle: String?,
        duration: String?,
        isExplicit: Bool,
        isPlaying: Bool,
        isDisabled: Bool,
        isLast: Bool,
        action: @escaping () -> Void,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        self.number = number
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.isExplicit = isExplicit
        self.isPlaying = isPlaying
        self.isDisabled = isDisabled
        self.isLast = isLast
        self.action = action
        self.menuContent = menuContent
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(number)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if isExplicit {
                            Image(systemName: "e.square.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                trailingAccessory
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .opacity(isDisabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contextMenu { menuContent() }
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 40)
            }
        }
    }

    private var trailingAccessory: some View {
        HStack(spacing: 8) {
            if isPlaying {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 32, height: 32)
            } else {
                if let duration {
                    Text(duration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Menu {
                    menuContent()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
        .frame(minWidth: 64, alignment: .trailing)
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

struct AlbumPrimaryActionBarMetrics: Equatable {
    static let maximumHeight: CGFloat = 56

    let circleDimension: CGFloat
    let horizontalPadding: CGFloat = 16
    let playHeight: CGFloat = 54
    let playWidth: CGFloat
    let spacing: CGFloat

    init(width: CGFloat) {
        circleDimension = width < 360 ? 52 : 56
        spacing = width < 360 ? 18 : 24

        let remainingWidth = width
            - (horizontalPadding * 2)
            - (circleDimension * 2)
            - (spacing * 2)

        playWidth = min(max(remainingWidth, 0), 177)
    }
}
