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

    private nonisolated static func isSelectedSpeakerGroup(
        _ speaker: SonosPlayer,
        selectedSpeaker: SonosPlayer?
    ) -> Bool {
        guard let selectedSpeaker else { return false }
        if selectedSpeaker.id == speaker.id { return true }

        let speakerGroupID = speaker.groupId ?? speaker.id
        let selectedGroupID = selectedSpeaker.groupId ?? selectedSpeaker.id
        return speakerGroupID == selectedGroupID
    }

    private nonisolated static func orderRank(
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

    private nonisolated static func groupID(for speaker: SonosPlayer) -> String {
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

    private nonisolated static func displayableMetadataText(_ value: String?) -> String? {
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
    private enum ProcessingTarget: Equatable {
        case everywhere
        case area(String)
        case group(String)
        case speaker(String)
    }

    @Bindable var manager: SonosManager
    @State private var processingTarget: ProcessingTarget?
    @State private var premuteMemberVolumes: [String: Int] = [:]

    private var visibleSpeakers: [SonosPlayer] {
        SpeakerPickerPlaybackPresentation.orderedSpeakers(
            manager.allSpeakers,
            selectedSpeaker: manager.selectedSpeaker,
            currentGroupMembers: currentGroupMembers
        )
    }

    private var selectableGroups: [SpeakerGroupStatus] {
        SpeakerPickerPlaybackPresentation.selectableGroups(
            manager.groupStatuses,
            currentGroupMembers: currentGroupMembers
        )
    }

    private var selectableAreas: [SonosArea] {
        SpeakerPickerPlaybackPresentation.selectableAreas(manager.savedAreas)
    }

    private var everywhereArea: SonosArea? {
        manager.savedAreas.first { area in
            area.isReadOnly && area.name.compare("Everywhere", options: .caseInsensitive) == .orderedSame
        }
    }

    private var currentGroupMembers: [SonosPlayer] {
        manager.currentGroupMembers
    }

    private func isInCurrentGroup(_ speaker: SonosPlayer) -> Bool {
        SpeakerPickerPlaybackPresentation.isSpeakerInCurrentGroup(
            speaker,
            currentGroupMembers: currentGroupMembers,
            selectedSpeaker: manager.selectedSpeaker
        )
    }

    private var accent: Color { manager.albumArtDominantColor ?? .accentColor }
    private var isEverywhere: Bool { manager.isEverywhereActive }
    private var isProcessing: Bool { processingTarget != nil }
    private var hasPillTargets: Bool {
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

    private func sheetContent(bottomSafeAreaInset: CGFloat) -> some View {
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

    private var speakerPickerBackground: some View {
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

    // MARK: - Now Playing Header

    private var nowPlayingHeader: some View {
        HStack(spacing: 14) {
            nowPlayingArtwork

            VStack(alignment: .leading, spacing: 4) {
                Text(manager.trackInfo?.title ?? "Not Playing")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                HStack(spacing: 6) {
                    Image(systemName: sourceIconName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    Text(nowPlayingSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                currentGroupBadge

                Button {
                    Task { await manager.togglePlayPause() }
                } label: {
                    Image(systemName: SpeakerPickerPlaybackPresentation.headerControlSystemImage(
                        trackInfo: manager.trackInfo,
                        isPlaying: manager.isPlaying
                    ))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.74))
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(.white.opacity(0.08)))
                        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SpeakerPickerPlaybackPresentation.headerControlAccessibilityLabel(
                    trackInfo: manager.trackInfo,
                    isPlaying: manager.isPlaying
                ))
            }
        }
    }

    private var nowPlayingArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SpeakerPickerCardLayout.cornerRadius)
                .fill(.white.opacity(0.12))

            if manager.trackInfo?.source == .tv {
                Image(systemName: "tv")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.76))
            } else if let image = manager.albumArtImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: SpeakerPickerCardLayout.cornerRadius))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(
            width: SpeakerPickerCardLayout.nowPlayingArtworkSize,
            height: SpeakerPickerCardLayout.nowPlayingArtworkSize
        )
        .overlay {
            RoundedRectangle(cornerRadius: SpeakerPickerCardLayout.cornerRadius)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var sourceIconName: String {
        switch manager.trackInfo?.source {
        case .tv:
            return "tv"
        case .appleMusic:
            return "apple.logo"
        default:
            return "music.note"
        }
    }

    private var nowPlayingSubtitle: String {
        guard let trackInfo = manager.trackInfo else {
            return selectedSpeakerTitle
        }
        if trackInfo.source == .tv {
            return trackInfo.tvFormat?.geekLabel ?? "TV Audio"
        }

        let artist = trackInfo.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = trackInfo.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty && !album.isEmpty {
            return "\(artist) • \(album)"
        }
        if !artist.isEmpty { return artist }
        if !album.isEmpty { return album }
        return selectedSpeakerTitle
    }

    private var selectedSpeakerTitle: String {
        guard !currentGroupMembers.isEmpty else {
            return manager.selectedSpeaker?.name ?? "Choose a speaker"
        }
        let names = currentGroupMembers.map(\.name)
        return names.joined(separator: " + ")
    }

    private var currentGroupBadge: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))
                .frame(width: 34, height: 34)

            if currentGroupMembers.count > 1 {
                Text("\(currentGroupMembers.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(.white.opacity(0.22)))
                    .offset(x: 7, y: -5)
            }
        }
        .frame(width: 42, height: 46)
    }

    // MARK: - Area Pills

    private var pillRail: some View {
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

    private var everywherePill: some View {
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

    private func areaPill(_ area: SonosArea) -> some View {
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

    private func pillContent(
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

    private func loadVolumes() {
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

    // MARK: - Group Row

    private func groupRow(_ group: SpeakerGroupStatus) -> some View {
        let isActive = SpeakerPickerPlaybackPresentation.isCurrentGroup(
            group,
            selectedSpeaker: manager.selectedSpeaker
        )
        let rowIsProcessing = processingTarget == .group(group.id)
        let rowIsPlaying = group.transportState == .playing
        let indicator = SpeakerPickerRowIndicator.make(
            isProcessing: rowIsProcessing,
            isActive: isActive || rowIsPlaying,
            isPlaying: rowIsPlaying
        )
        let artworkImage = group.trackInfo?.source == .tv ? nil : manager.groupAlbumImages[group.id]

        return Button {
            guard !isProcessing else { return }
            Task { await selectGroup(group) }
        } label: {
            pickerRowContent(
                title: SpeakerPickerPlaybackPresentation.groupDisplayName(for: group),
                subtitle: SpeakerPickerPlaybackPresentation.groupSubtitle(for: group),
                iconName: group.trackInfo?.source == .tv ? "tv" : "speaker.3.fill",
                artworkImage: artworkImage,
                isActive: isActive,
                indicator: indicator
            )
        }
        .buttonStyle(.plain)
        .cardChrome(isActive: isActive, accent: accent)
    }

    // MARK: - Speaker Row

    private func speakerRow(_ speaker: SonosPlayer, inGroup: Bool) -> some View {
        let isCoord = speaker.id == manager.selectedSpeaker?.id
        let vol = manager.memberVolumes[speaker.ipAddress] ?? manager.volume
        let rowIsProcessing = processingTarget == .speaker(speaker.id)
        let rowIsPlaying = SpeakerPickerPlaybackPresentation.isPlaying(
            for: speaker,
            groupStatuses: manager.groupStatuses,
            fallback: isCoord && manager.isPlaying
        )
        let usesTelevisionIcon = SpeakerPickerPlaybackPresentation.usesTelevisionIcon(
            for: speaker,
            groupStatuses: manager.groupStatuses,
            selectedSpeaker: manager.selectedSpeaker,
            selectedTrackInfo: manager.trackInfo
        )
        let artworkImage = usesTelevisionIcon ? nil : SpeakerPickerPlaybackPresentation.artworkImage(
            for: speaker,
            groupStatuses: manager.groupStatuses,
            groupImages: manager.groupAlbumImages,
            selectedSpeaker: manager.selectedSpeaker,
            selectedAlbumArtImage: manager.albumArtImage
        )
        let indicator = SpeakerPickerRowIndicator.make(
            isProcessing: rowIsProcessing,
            isActive: inGroup || rowIsPlaying,
            isPlaying: rowIsPlaying
        )

        return VStack(spacing: 0) {
            Button {
                guard !isProcessing else { return }
                Task { await handleTap(speaker, inGroup: inGroup, isCoord: isCoord) }
            } label: {
                pickerRowContent(
                    title: speaker.name,
                    subtitle: subtitle(for: speaker, inGroup: inGroup, isCoordinator: isCoord),
                    iconName: usesTelevisionIcon ? "tv" : "hifispeaker.fill",
                    artworkImage: artworkImage,
                    isActive: inGroup,
                    indicator: indicator
                )
            }
            .buttonStyle(.plain)

            if inGroup {
                speakerPickerSeparator(opacity: SpeakerPickerCardLayout.activeRowSeparatorOpacity)
                    .padding(.horizontal, SpeakerPickerCardLayout.horizontalPadding)

                volumeRow(speaker: speaker, vol: vol)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardChrome(isActive: inGroup, accent: accent)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: inGroup)
    }

    private func speakerPickerSeparator(opacity: Double) -> some View {
        Rectangle()
            .fill(.white.opacity(opacity))
            .frame(height: SpeakerPickerCardLayout.separatorHeight)
            .accessibilityHidden(true)
    }

    private func subtitle(for speaker: SonosPlayer, inGroup: Bool, isCoordinator: Bool) -> String {
        let fallback: String
        if isCoordinator {
            fallback = manager.isPlaying ? "Currently playing" : "Selected speaker"
        } else if inGroup {
            fallback = "In current group"
        } else {
            fallback = "Tap to add"
        }

        let statusSubtitle = SpeakerPickerPlaybackPresentation.subtitle(
            for: speaker,
            groupStatuses: manager.groupStatuses,
            fallback: fallback
        )
        if statusSubtitle != fallback {
            return statusSubtitle
        }

        guard isCoordinator, let trackInfo = manager.trackInfo else {
            return fallback
        }
        return SpeakerPickerPlaybackPresentation.displayText(for: trackInfo) ?? fallback
    }

    private func pickerRowContent(
        title: String,
        subtitle: String,
        iconName: String,
        artworkImage: UIImage? = nil,
        isActive: Bool,
        indicator: SpeakerPickerRowIndicator
    ) -> some View {
        HStack(spacing: 12) {
            iconTile(iconName, artworkImage: artworkImage, isActive: isActive)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(isActive ? .white.opacity(0.62) : .white.opacity(0.44))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            indicatorView(indicator, isActive: isActive)
        }
        .padding(.horizontal, SpeakerPickerCardLayout.horizontalPadding)
        .padding(.vertical, SpeakerPickerCardLayout.rowVerticalPadding)
        .frame(minHeight: SpeakerPickerCardLayout.minimumRowHeight)
        .contentShape(Rectangle())
    }

    private func iconTile(_ systemName: String, artworkImage: UIImage? = nil, isActive: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: SpeakerPickerCardLayout.cornerRadius)
                .fill(isActive ? accent.opacity(0.22) : .white.opacity(0.10))

            if let artworkImage {
                Image(uiImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(
                        width: SpeakerPickerCardLayout.iconSize,
                        height: SpeakerPickerCardLayout.iconSize
                    )
                    .clipShape(RoundedRectangle(cornerRadius: SpeakerPickerCardLayout.cornerRadius))
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isActive ? accent : .white.opacity(0.78))
            }
        }
        .frame(
            width: SpeakerPickerCardLayout.iconSize,
            height: SpeakerPickerCardLayout.iconSize
        )
        .overlay {
            RoundedRectangle(cornerRadius: SpeakerPickerCardLayout.cornerRadius)
                .stroke(.white.opacity(artworkImage == nil ? 0.08 : 0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func indicatorView(_ indicator: SpeakerPickerRowIndicator, isActive: Bool) -> some View {
        ZStack {
            if indicator.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.68))
            } else if indicator.showsWaveform {
                SpeakerPickerWaveform(
                    isPlaying: indicator.animatesWaveform,
                    color: isActive ? accent : .white.opacity(0.48)
                )
            } else if let systemImageName = indicator.systemImageName {
                Image(systemName: systemImageName)
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.34))
            }
        }
        .frame(
            width: SpeakerPickerCardLayout.indicatorSlotSize.width,
            height: SpeakerPickerCardLayout.indicatorSlotSize.height
        )
    }

    // MARK: - Volume Row (matches Home page GroupVolumeBar pattern)

    private func volumeRow(speaker: SonosPlayer, vol: Int) -> some View {
        HStack(spacing: SpeakerPickerCardLayout.volumeRowSpacing) {
            Image(systemName: vol == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    let newVol = max(0, vol - 2)
                    Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: newVol) }
                }
                .onLongPressGesture {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if vol > 0 {
                        premuteMemberVolumes[speaker.ipAddress] = vol
                        Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: 0) }
                    } else if let saved = premuteMemberVolumes[speaker.ipAddress] {
                        premuteMemberVolumes[speaker.ipAddress] = nil
                        Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: saved) }
                    }
                }

            PickerVolumeBar(volume: vol, accent: accent) { step in
                let newVol = min(100, max(0, vol + step))
                Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: newVol) }
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let newVol = min(100, vol + 2)
                Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: newVol) }
            } label: {
                Text("\(vol)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 22, height: 28, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SpeakerPickerCardLayout.horizontalPadding)
        .padding(.top, SpeakerPickerCardLayout.volumeTopPadding)
        .padding(.bottom, SpeakerPickerCardLayout.volumeBottomPadding)
    }

    // MARK: - Actions

    private func handleTap(_ speaker: SonosPlayer, inGroup: Bool, isCoord: Bool) async {
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

    private func selectGroup(_ group: SpeakerGroupStatus) async {
        processingTarget = .group(group.id)
        defer { processingTarget = nil }

        await manager.selectSpeaker(
            group.coordinator,
            userInitiatedLiveActivityResume: true
        )
        await manager.fetchMemberVolumes()
    }

    private func selectArea(_ area: SonosArea) async {
        processingTarget = .area(area.id)
        defer { processingTarget = nil }

        await manager.applyArea(area)
    }

    // MARK: - Everywhere

    private func toggleEverywhere() async {
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

private extension View {
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

private struct SpeakerPickerWaveform: View {
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

private struct PickerVolumeBar: View {
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
