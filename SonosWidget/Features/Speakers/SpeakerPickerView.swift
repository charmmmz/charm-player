import SwiftUI

enum SpeakerPickerCardLayout {
    nonisolated static let cornerRadius: CGFloat = 8
    nonisolated static let iconSize: CGFloat = 36
    nonisolated static let minimumRowHeight: CGFloat = 68
    nonisolated static let horizontalPadding: CGFloat = 12
    nonisolated static let rowVerticalPadding: CGFloat = 8
    nonisolated static let rowSpacing: CGFloat = 8
    nonisolated static let indicatorSlotSize = CGSize(width: 30, height: 38)
    nonisolated static let pillHeight: CGFloat = 46
    nonisolated static let pillHorizontalPadding: CGFloat = 18
    nonisolated static let pillRailTopPadding: CGFloat = 14
    nonisolated static let pillRailBottomPadding: CGFloat = 10
    nonisolated static let volumeRowSpacing: CGFloat = 8
    nonisolated static let volumeTopPadding: CGFloat = 2
    nonisolated static let volumeBottomPadding: CGFloat = 8
    nonisolated static let nowPlayingArtworkSize: CGFloat = 56
    nonisolated static let separatorHeight: CGFloat = 0.5
    nonisolated static let headerSeparatorOpacity = 0.14
    nonisolated static let activeRowSeparatorOpacity = 0.16
}

enum SpeakerPickerPillLayout {
    static let showsLeadingIcon = false
}

enum SpeakerPickerSheetBackgroundCoverage: Equatable, Sendable {
    case contentFrame
    case presentationChrome
}

enum SpeakerPickerSheetLayout {
    nonisolated static let backgroundCoverage = SpeakerPickerSheetBackgroundCoverage.presentationChrome
    nonisolated static let usesNavigationCloseButton = false
    nonisolated static let extendsIntoBottomSafeArea = true
    nonisolated static let baseScrollContentBottomPadding: CGFloat = 22

    nonisolated static func contentFrameSize(
        containerSize: CGSize,
        bottomSafeAreaInset: CGFloat = 0
    ) -> CGSize {
        CGSize(
            width: max(containerSize.width, 0),
            height: max(containerSize.height + max(bottomSafeAreaInset, 0), 0)
        )
    }

    nonisolated static func scrollContentBottomPadding(bottomSafeAreaInset: CGFloat) -> CGFloat {
        baseScrollContentBottomPadding + max(bottomSafeAreaInset, 0)
    }
}

enum SpeakerPickerRowIndicator: Equatable, Sendable {
    case add
    case restingWaveform
    case playingWaveform
    case processing

    static func make(isProcessing: Bool, isActive: Bool, isPlaying: Bool) -> SpeakerPickerRowIndicator {
        if isProcessing {
            return .processing
        }
        if isActive {
            return isPlaying ? .playingWaveform : .restingWaveform
        }
        return .add
    }

    var showsSpinner: Bool {
        self == .processing
    }

    var showsWaveform: Bool {
        switch self {
        case .restingWaveform, .playingWaveform:
            return true
        case .add, .processing:
            return false
        }
    }

    var animatesWaveform: Bool {
        self == .playingWaveform
    }

    var systemImageName: String? {
        switch self {
        case .add:
            return "plus.circle.fill"
        case .restingWaveform, .playingWaveform, .processing:
            return nil
        }
    }
}

enum SpeakerPickerPlaybackPresentation {
    nonisolated static func orderedSpeakers(
        _ speakers: [SonosPlayer],
        selectedSpeaker: SonosPlayer?,
        currentGroupMembers: [SonosPlayer] = []
    ) -> [SonosPlayer] {
        var seen = Set<String>()
        let visible = speakers.filter { speaker in
            !speaker.isInvisible && seen.insert(speaker.id).inserted
        }
        let selectedGroupID = selectedSpeaker.map(groupID(for:))
        let currentMemberIDs = Set(currentGroupMembers.filter { !$0.isInvisible }.map(\.id))

        return visible.sorted { left, right in
            let leftRank = orderRank(
                for: left,
                selectedGroupID: selectedGroupID,
                currentMemberIDs: currentMemberIDs
            )
            let rightRank = orderRank(
                for: right,
                selectedGroupID: selectedGroupID,
                currentMemberIDs: currentMemberIDs
            )
            if leftRank != rightRank { return leftRank < rightRank }

            let leftGroupID = groupID(for: left).lowercased()
            let rightGroupID = groupID(for: right).lowercased()
            if leftGroupID != rightGroupID { return leftGroupID < rightGroupID }

            if left.isCoordinator != right.isCoordinator {
                return left.isCoordinator
            }

            let leftName = left.name.lowercased()
            let rightName = right.name.lowercased()
            if leftName != rightName { return leftName < rightName }
            return left.id < right.id
        }
    }

    nonisolated static func isSpeakerInCurrentGroup(
        _ speaker: SonosPlayer,
        currentGroupMembers: [SonosPlayer],
        selectedSpeaker: SonosPlayer?
    ) -> Bool {
        let currentMemberIDs = Set(currentGroupMembers.filter { !$0.isInvisible }.map(\.id))
        if !currentMemberIDs.isEmpty {
            return currentMemberIDs.contains(speaker.id)
        }

        guard let selectedSpeaker else { return false }
        return groupID(for: speaker) == groupID(for: selectedSpeaker)
    }

    nonisolated static func subtitle(
        for speaker: SonosPlayer,
        groupStatuses: [SpeakerGroupStatus],
        fallback: String
    ) -> String {
        guard let trackInfo = groupStatus(for: speaker, groupStatuses: groupStatuses)?.trackInfo,
              let display = displayText(for: trackInfo) else {
            return fallback
        }
        return display
    }

    nonisolated static func isPlaying(
        for speaker: SonosPlayer,
        groupStatuses: [SpeakerGroupStatus],
        fallback: Bool
    ) -> Bool {
        guard let status = groupStatus(for: speaker, groupStatuses: groupStatuses) else {
            return fallback
        }
        return status.transportState == .playing
    }

    static func headerControlSystemImage(
        trackInfo: TrackInfo?,
        isPlaying: Bool
    ) -> String {
        PlaybackControlPresentation.primarySystemImage(
            isPlaying: isPlaying,
            isLiveStream: trackInfo?.isLiveStream == true
        )
    }

    static func headerControlAccessibilityLabel(
        trackInfo: TrackInfo?,
        isPlaying: Bool
    ) -> String {
        PlaybackControlPresentation.primaryAccessibilityLabel(
            isPlaying: isPlaying,
            isLiveStream: trackInfo?.isLiveStream == true
        )
    }

    nonisolated static func selectableGroups(
        _ groupStatuses: [SpeakerGroupStatus],
        currentGroupMembers: [SonosPlayer] = []
    ) -> [SpeakerGroupStatus] {
        var seen = Set<String>()
        let currentMemberIDs = Set(currentGroupMembers.filter { !$0.isInvisible }.map(\.id))
        return groupStatuses.filter { status in
            guard seen.insert(status.id).inserted else { return false }
            let members = visibleMembers(for: status)
            guard members.count > 1 else { return false }

            let isUnnamedCurrentPlaybackGroup = displayableMetadataText(status.name) == nil
                && !currentMemberIDs.isEmpty
                && Set(members.map(\.id)) == currentMemberIDs
            return !isUnnamedCurrentPlaybackGroup
        }
    }

    nonisolated static func selectableAreas(_ areas: [SonosArea]) -> [SonosArea] {
        var seen = Set<String>()
        return areas.filter { area in
            guard !area.isReadOnly,
                  !area.playerIds.isEmpty,
                  seen.insert(area.id).inserted else {
                return false
            }
            return true
        }
    }

    nonisolated static func visibleMembers(for group: SpeakerGroupStatus) -> [SonosPlayer] {
        group.members.filter { !$0.isInvisible }
    }

    nonisolated static func groupDisplayName(for group: SpeakerGroupStatus) -> String {
        if let name = displayableMetadataText(group.name) {
            return name
        }

        let names = visibleMembers(for: group).map(\.name)
        if !names.isEmpty {
            return names.joined(separator: " + ")
        }

        return group.coordinator.name
    }

    nonisolated static func groupSubtitle(for group: SpeakerGroupStatus) -> String {
        if let trackInfo = group.trackInfo,
           let display = displayText(for: trackInfo) {
            return display
        }

        let count = visibleMembers(for: group).count
        return count == 1 ? "1 speaker" : "\(count) speakers"
    }

    nonisolated static func areaSubtitle(
        for area: SonosArea,
        allSpeakers: [SonosPlayer]
    ) -> String {
        let speakersByID = Dictionary(
            allSpeakers.filter { !$0.isInvisible }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let names = area.playerIds.compactMap { speakersByID[$0]?.name }
        if !names.isEmpty {
            return names.joined(separator: " + ")
        }

        let count = area.playerIds.count
        return count == 1 ? "1 speaker" : "\(count) speakers"
    }

    nonisolated static func isCurrentGroup(
        _ group: SpeakerGroupStatus,
        selectedSpeaker: SonosPlayer?
    ) -> Bool {
        guard let selectedSpeaker else { return false }
        let selectedGroupID = selectedSpeaker.groupId ?? selectedSpeaker.id
        return group.id == selectedGroupID
            || group.coordinator.id == selectedSpeaker.id
            || group.coordinator.groupId == selectedGroupID
    }

    nonisolated static func isAreaActive(
        _ area: SonosArea,
        currentGroupMembers: [SonosPlayer]
    ) -> Bool {
        let areaPlayers = Set(area.playerIds)
        let currentPlayers = Set(currentGroupMembers.filter { !$0.isInvisible }.map(\.id))
        return !areaPlayers.isEmpty && areaPlayers == currentPlayers
    }

    nonisolated static func artworkImage(
        for speaker: SonosPlayer,
        groupStatuses: [SpeakerGroupStatus],
        groupImages: [String: UIImage],
        selectedSpeaker: SonosPlayer?,
        selectedAlbumArtImage: UIImage?
    ) -> UIImage? {
        let status = groupStatus(for: speaker, groupStatuses: groupStatuses)
        let groupID = status?.id ?? speaker.groupId ?? speaker.id

        if let image = groupImages[groupID] {
            return image
        }

        if isSelectedSpeakerGroup(speaker, selectedSpeaker: selectedSpeaker) {
            return selectedAlbumArtImage
        }

        return nil
    }

    nonisolated static func usesTelevisionIcon(
        for speaker: SonosPlayer,
        groupStatuses: [SpeakerGroupStatus],
        selectedSpeaker: SonosPlayer?,
        selectedTrackInfo: TrackInfo?
    ) -> Bool {
        if let source = groupStatus(for: speaker, groupStatuses: groupStatuses)?.trackInfo?.source {
            return source == .tv
        }
        if isSelectedSpeakerGroup(speaker, selectedSpeaker: selectedSpeaker) {
            return selectedTrackInfo?.source == .tv
        }
        return false
    }

    nonisolated static func isSelectedSpeakerGroup(
        _ speaker: SonosPlayer,
        selectedSpeaker: SonosPlayer?
    ) -> Bool {
        guard let selectedSpeaker else { return false }
        if selectedSpeaker.id == speaker.id { return true }

        let speakerGroupID = speaker.groupId ?? speaker.id
        let selectedGroupID = selectedSpeaker.groupId ?? selectedSpeaker.id
        return speakerGroupID == selectedGroupID
    }

    nonisolated static func orderRank(
        for speaker: SonosPlayer,
        selectedGroupID: String?,
        currentMemberIDs: Set<String>
    ) -> Int {
        if currentMemberIDs.contains(speaker.id) {
            return speaker.isCoordinator ? 0 : 1
        }
        if let selectedGroupID, groupID(for: speaker) == selectedGroupID {
            return speaker.isCoordinator ? 0 : 1
        }
        return speaker.isCoordinator ? 2 : 3
    }

    nonisolated static func groupID(for speaker: SonosPlayer) -> String {
        speaker.groupId ?? speaker.id
    }

    nonisolated static func groupStatus(
        for speaker: SonosPlayer,
        groupStatuses: [SpeakerGroupStatus]
    ) -> SpeakerGroupStatus? {
        let groupID = speaker.groupId ?? speaker.id
        return groupStatuses.first { status in
            status.id == groupID
                || status.coordinator.id == speaker.id
                || status.coordinator.groupId == groupID
                || status.members.contains { member in
                    member.id == speaker.id || member.groupId == groupID
                }
        }
    }

    nonisolated static func displayText(for trackInfo: TrackInfo) -> String? {
        guard let title = displayableMetadataText(trackInfo.title) else {
            return nil
        }
        guard let artist = displayableMetadataText(trackInfo.artist) else {
            return title
        }
        return "\(title) - \(artist)"
    }

    nonisolated static func displayableMetadataText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        switch trimmed.lowercased() {
        case "unknown", "idle", "not playing", "not_implemented":
            return nil
        default:
            return trimmed
        }
    }
}

struct SpeakerPickerView: View {
    enum ProcessingTarget: Equatable {
        case everywhere
        case area(String)
        case group(String)
        case speaker(String)
    }

    @Bindable var manager: SonosManager
    @State var processingTarget: ProcessingTarget?
    @State var premuteMemberVolumes: [String: Int] = [:]

    var visibleSpeakers: [SonosPlayer] {
        SpeakerPickerPlaybackPresentation.orderedSpeakers(
            manager.allSpeakers,
            selectedSpeaker: manager.selectedSpeaker,
            currentGroupMembers: currentGroupMembers
        )
    }

    var selectableGroups: [SpeakerGroupStatus] {
        SpeakerPickerPlaybackPresentation.selectableGroups(
            manager.groupStatuses,
            currentGroupMembers: currentGroupMembers
        )
    }

    var selectableAreas: [SonosArea] {
        SpeakerPickerPlaybackPresentation.selectableAreas(manager.savedAreas)
    }

    var everywhereArea: SonosArea? {
        manager.savedAreas.first { area in
            area.isReadOnly && area.name.compare("Everywhere", options: .caseInsensitive) == .orderedSame
        }
    }

    var currentGroupMembers: [SonosPlayer] {
        manager.currentGroupMembers
    }

    func isInCurrentGroup(_ speaker: SonosPlayer) -> Bool {
        SpeakerPickerPlaybackPresentation.isSpeakerInCurrentGroup(
            speaker,
            currentGroupMembers: currentGroupMembers,
            selectedSpeaker: manager.selectedSpeaker
        )
    }

    var accent: Color { manager.albumArtDominantColor ?? .accentColor }
    var isEverywhere: Bool { manager.isEverywhereActive }
    var isProcessing: Bool { processingTarget != nil }
    var hasPillTargets: Bool {
        visibleSpeakers.count > 1 || !selectableAreas.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            let contentSize = SpeakerPickerSheetLayout.contentFrameSize(
                containerSize: proxy.size,
                bottomSafeAreaInset: proxy.safeAreaInsets.bottom
            )

            sheetContent(bottomSafeAreaInset: proxy.safeAreaInsets.bottom)
                .frame(
                    width: contentSize.width,
                    height: contentSize.height,
                    alignment: .top
                )
                .clipped()
        }
        .background { speakerPickerBackground }
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear { loadVolumes() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        .presentationBackground {
            speakerPickerBackground
        }
        .tint(accent)
    }

    func sheetContent(bottomSafeAreaInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            nowPlayingHeader
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 18)

            speakerPickerSeparator(opacity: SpeakerPickerCardLayout.headerSeparatorOpacity)

            if hasPillTargets {
                pillRail
                    .padding(.top, SpeakerPickerCardLayout.pillRailTopPadding)
                    .padding(.bottom, SpeakerPickerCardLayout.pillRailBottomPadding)
            }

            ScrollView {
                if visibleSpeakers.isEmpty && selectableGroups.isEmpty {
                    ContentUnavailableView("No Speakers Found",
                                           systemImage: "hifispeaker.slash",
                                           description: Text("Make sure your Sonos speakers are on the same network."))
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: SpeakerPickerCardLayout.rowSpacing) {
                        ForEach(selectableGroups) { group in
                            groupRow(group)
                        }

                        ForEach(visibleSpeakers) { speaker in
                            let inGroup = isInCurrentGroup(speaker)
                            speakerRow(speaker, inGroup: inGroup)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, SpeakerPickerSheetLayout.scrollContentBottomPadding(
                        bottomSafeAreaInset: bottomSafeAreaInset
                    ))
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    var speakerPickerBackground: some View {
        SonosArtworkBackground(
            image: manager.albumArtImage,
            fallbackColor: manager.albumArtDominantColor,
            overlayOpacity: 0.56
        )
        .ignoresSafeArea()
        .overlay {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.04),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.58)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

}
