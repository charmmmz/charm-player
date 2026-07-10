import SwiftUI

extension SpeakerPickerView {

    // MARK: - Area Pills

    var pillRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if visibleSpeakers.count > 1 {
                    everywherePill
                }

                ForEach(selectableAreas) { area in
                    areaPill(area)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    var everywherePill: some View {
        return Button {
            guard !isProcessing else { return }
            Task { await toggleEverywhere() }
        } label: {
            pillContent(
                title: "Everywhere",
                isActive: isEverywhere
            )
        }
        .buttonStyle(.plain)
    }

    func areaPill(_ area: SonosArea) -> some View {
        let isActive = SpeakerPickerPlaybackPresentation.isAreaActive(
            area,
            currentGroupMembers: currentGroupMembers
        )

        return Button {
            guard !isProcessing else { return }
            Task { await selectArea(area) }
        } label: {
            pillContent(
                title: area.name,
                isActive: isActive
            )
        }
        .buttonStyle(.plain)
    }

    func pillContent(
        title: String,
        isActive: Bool
    ) -> some View {
        HStack {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, SpeakerPickerCardLayout.pillHorizontalPadding)
        .frame(height: SpeakerPickerCardLayout.pillHeight)
        .background {
            Capsule()
                .fill(.white.opacity(isActive ? 0.18 : 0.11))
                .overlay {
                    Capsule()
                        .fill(accent.opacity(isActive ? 0.22 : 0))
                }
        }
        .overlay {
            Capsule()
                .stroke(isActive ? accent.opacity(0.86) : .white.opacity(0.10), lineWidth: 1)
        }
        .contentShape(Capsule())
    }

    // MARK: - Load Volumes

    func loadVolumes() {
        Task {
            let members = manager.currentGroupMembers
            if members.count > 1 {
                await manager.fetchMemberVolumes()
            } else if let solo = members.first {
                if manager.memberVolumes[solo.ipAddress] == nil {
                    manager.memberVolumes[solo.ipAddress] = manager.volume
                }
            }
        }
    }

}
