import SwiftUI

struct MusicResourceCardLabel<ArtworkContent: View>: View {
    let resource: MusicResourcePresentation
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let isDimmed: Bool
    let isLoading: Bool
    @ViewBuilder let artwork: () -> ArtworkContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                artwork()
                    .frame(width: width, height: height)

                if isLoading {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial.opacity(0.88))
                        .overlay {
                            ProgressView()
                                .tint(.white)
                        }
                }
            }
            .frame(width: width, height: height)

            Text(resource.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(resource.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .opacity(isDimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(resource.title)
    }
}

struct MusicResourceRowLabel<ArtworkContent: View>: View {
    let resource: MusicResourcePresentation
    @ViewBuilder let artwork: () -> ArtworkContent

    var body: some View {
        HStack(spacing: 12) {
            artwork()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(resource.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !resource.subtitle.isEmpty {
                    Text(resource.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let detail = resource.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            accessory
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var accessory: some View {
        switch resource.accessory {
        case .play:
            Image(systemName: "play.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 32, height: 32)
        case .progress:
            ProgressView()
                .frame(width: 32, height: 32)
        case .none:
            EmptyView()
        }
    }
}

struct MusicResourceContextMenu: View {
    let actions: [MusicResourceMenuAction]
    let perform: (MusicResourceMenuAction) -> Void

    var body: some View {
        ForEach(actions) { action in
            Button {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(!action.isEnabled)
        }
    }
}
