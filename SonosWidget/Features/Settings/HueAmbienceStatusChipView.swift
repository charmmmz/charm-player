import SwiftUI
struct HueAmbienceStatusChipView: View {
    let chip: HueAmbienceStatusChip

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(chip.tone.color)
                .frame(width: 8, height: 8)
                .overlay {
                    if chip.tone == .working {
                        Circle()
                            .stroke(chip.tone.color.opacity(0.55), lineWidth: 1)
                            .scaleEffect(1.6)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(chip.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(chip.value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chip.title): \(chip.value)")
    }
}
extension HueAmbienceStatusTone {
    var color: Color {
        switch self {
        case .ready:
            return .green
        case .working:
            return .yellow
        case .critical:
            return .red
        case .neutral:
            return .secondary
        }
    }
}
