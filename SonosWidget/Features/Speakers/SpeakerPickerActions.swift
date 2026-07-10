import SwiftUI

extension SpeakerPickerView {

    // MARK: - Actions

    func handleTap(_ speaker: SonosPlayer, inGroup: Bool, isCoord: Bool) async {
        processingTarget = .speaker(speaker.id)
        defer { processingTarget = nil }

        if inGroup {
            if isCoord {
                let others = manager.currentGroupMembers.filter { $0.id != speaker.id }
                if let target = others.first {
                    await manager.transferPlayback(to: target)
                }
            } else {
                await manager.removeSpeakerFromGroup(speaker)
            }
        } else {
            await manager.addSpeakerToGroup(speaker)
        }

        await manager.fetchMemberVolumes()
    }

    func selectGroup(_ group: SpeakerGroupStatus) async {
        processingTarget = .group(group.id)
        defer { processingTarget = nil }

        await manager.selectSpeaker(
            group.coordinator,
            userInitiatedLiveActivityResume: true
        )
        await manager.fetchMemberVolumes()
    }

    func selectArea(_ area: SonosArea) async {
        processingTarget = .area(area.id)
        defer { processingTarget = nil }

        await manager.applyArea(area)
    }

    // MARK: - Everywhere

    func toggleEverywhere() async {
        processingTarget = .everywhere
        defer { processingTarget = nil }

        if isEverywhere {
            await manager.disablePartyMode()
        } else if let everywhereArea {
            await manager.applyArea(everywhereArea)
        } else {
            await manager.enablePartyMode()
        }

        await manager.fetchMemberVolumes()
    }
}
