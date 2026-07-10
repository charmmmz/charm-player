import AVFoundation
import SwiftUI
import UIKit

struct PlayerView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager
    @Binding var pendingAppleMusicShare: PendingAppleMusicShare?
    @Binding var detailPath: [PlayerDetailRoute]
    @State private var newSpeakerIP = ""
    @State private var showManualEntry = false
    /// Tracked per-session so we only auto-connect on the *first* discovery
    /// result. After the auto-attempt, any speaker change is user-initiated.
    @State private var didAutoConnect = false

    var body: some View {
        Group {
            if manager.isConfigured {
                configuredView
            } else {
                NavigationStack {
                    setupView
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                Text("Sonos").fontWeight(.semibold)
                            }
                        }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            manager.loadSavedState()
            searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
            Task { await searchManager.probeLinkedServices() }
        }
    }

    // MARK: - Configured View

    private var configuredView: some View {
        NavigationStack(path: $detailPath) {
            speakersHomeView
                .background {
                    blurredArtBackground.ignoresSafeArea()
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationDestination(for: PlayerDetailRoute.self) { route in
                    playerDetailDestination(route)
                }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func playerDetailDestination(_ route: PlayerDetailRoute) -> some View {
        switch route.kind {
        case .artist:
            ArtistDetailView(
                artistItem: route.browseItem,
                searchManager: searchManager,
                manager: manager
            )
        case .album:
            AlbumDetailView(
                albumItem: route.browseItem,
                searchManager: searchManager,
                manager: manager
            )
        }
    }

    private var blurredArtBackground: some View {
        ZStack {
            Color.black
            if let image = manager.albumArtImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                    .id(albumArtTransitionID)
                    .transition(.opacity)
                Color.black.opacity(0.6)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: albumArtTransitionID)
    }

    private var albumArtTransitionID: String {
        manager.albumArtTransitionID()
    }

    // MARK: - Speakers Home View

    @State private var dropTargetGroupID: String?
    @State private var isSeparateZoneTargeted = false
    @State private var isTransferZoneTargeted = false
    @State private var isTransferringPlayback = false
    @State private var pendingSharePlaybackGroupID: String?
    @State private var pendingSharePulse = false
    @State private var hasActiveSpeakerGroupDragSource = false
    @State private var isSpeakerGroupDragPreviewVisible = false
    @State private var speakerGroupDragAutoResetTask: Task<Void, Never>?
    @State private var speakerCardSizes: [String: CGSize] = [:]
    @State private var homeToastMessage: String?

    private var isSpeakerGroupDragActive: Bool {
        HomeActionTrayPresentation.isVisible(
            hasActiveDragSource: hasActiveSpeakerGroupDragSource,
            isDragPreviewVisible: isSpeakerGroupDragPreviewVisible
        )
    }

    private var speakersHomeView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Surfaced when probe found no viable backend — user is
                // off-LAN and not signed in to Sonos Cloud (or cloud group
                // hasn't resolved). Tap-to-refresh runs another probe.
                if manager.isSpeakerUnreachable {
                    unreachableBanner
                }
                if pendingAppleMusicShare != nil {
                    pendingAppleMusicShareBanner
                }
                if manager.showsHomeSpeakerCardsBlockingLoader {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Loading speakers…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(manager.groupStatuses) { group in
                            let isDropTarget = dropTargetGroupID == group.id
                            let dropAccent = manager.groupAlbumColors[group.id]
                                ?? manager.albumArtDominantColor
                                ?? .accentColor

                            speakerGroupCard(group)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: SpeakerCardSizePreferenceKey.self,
                                            value: [group.id: proxy.size]
                                        )
                                    }
                                }
                                // Drag source: carry the group ID as a String.
                                .onDrag {
                                    beginSpeakerGroupDrag()
                                    return NSItemProvider(object: group.id as NSString)
                                } preview: {
                                    dragPreview(group)
                                }
                                // Drop center to group, or top/bottom edges to reorder.
                                .dropDestination(for: String.self) { items, location in
                                    guard let sourceID = items.first,
                                          sourceID != group.id else { return false }
                                    handleSpeakerCardDrop(
                                        sourceID: sourceID,
                                        targetGroup: group,
                                        location: location
                                    )
                                    endSpeakerGroupDrag()
                                    return true
                                } isTargeted: { targeted in
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        dropTargetGroupID = targeted ? group.id : nil
                                    }
                                }
                                // Highlight drop target with an animated border.
                                .overlay {
                                    if isDropTarget {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 14)
                                                .strokeBorder(dropAccent.opacity(0.8), lineWidth: 2)

                                            VStack {
                                                Capsule()
                                                    .fill(dropAccent.opacity(0.85))
                                                    .frame(width: 56, height: 3)
                                                Spacer()
                                                Capsule()
                                                    .fill(dropAccent.opacity(0.85))
                                                    .frame(width: 56, height: 3)
                                            }
                                            .padding(.vertical, 8)
                                        }
                                        .transition(.opacity)
                                    }
                                }
                                .overlay {
                                    pendingAppleMusicShareHighlight(for: group)
                                }
                                .scaleEffect(
                                    isDropTarget || pendingSharePlaybackGroupID == group.id ? 1.02 : 1.0
                                )
                                .animation(.spring(response: 0.25, dampingFraction: 0.7),
                                           value: isDropTarget)
                                .animation(.spring(response: 0.25, dampingFraction: 0.7),
                                           value: pendingSharePlaybackGroupID)
                        }
                    }
                    .padding(.horizontal)
                    .onPreferenceChange(SpeakerCardSizePreferenceKey.self) { sizes in
                        speakerCardSizes = sizes
                    }
                }

                Spacer(minLength: 20)
            }
            // Home tab has no navigation title, so without a top inset the
            // first speaker card hugs the status bar and leaves the lower
            // half of the screen visually empty. A 48pt pad breathes the
            // group cards away from the notch while still letting taller
            // lists flow off the bottom normally.
            .padding(.top, 48)
        }
        // Single source of truth for the "we're driving via Sonos Cloud"
        // affordance. Floats at the top-left inside the breathing space
        // above the first speaker card, so it doesn't push the cards
        // down. Not scroll-linked by design — the connection state is
        // relevant regardless of where you've scrolled to.
        .overlay(alignment: .topLeading) {
            if manager.transportBackend == .cloud {
                remoteModePill
                    .padding(.leading, 16)
                    .padding(.top, 16)
            }
        }
        .overlay(alignment: .bottom) {
            if HomeActionTrayPresentation.isVisible(isSpeakerGroupDragActive: isSpeakerGroupDragActive) {
                homeActionZone
                    .padding(.horizontal, 20)
                    .padding(.bottom, homeActionBottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isSpeakerGroupDragActive)
        .toast($homeToastMessage)
        .onAppear {
            manager.refreshHomeSpeakerCardsOnAppear()
            updatePendingSharePulse()
        }
        .onChange(of: pendingAppleMusicShare?.id) { _, _ in
            updatePendingSharePulse()
        }
    }

    private var remoteModePill: some View {
        Label("Remote", systemImage: "cloud.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.12), in: Capsule())
            .accessibilityLabel("Controlling via Sonos Cloud")
    }

    private var unreachableBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speaker unreachable")
                    .font(.subheadline.weight(.semibold))
                Text("Pull down to retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { _ = await manager.probeBackend() }
            } label: {
                if manager.isProbing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var pendingAppleMusicShareBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.pink)

            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Music ready")
                    .font(.subheadline.weight(.semibold))
                Text("Choose a speaker to start playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if pendingSharePlaybackGroupID != nil {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                SharedStorage.clearPendingAppleMusicShare()
                pendingAppleMusicShare = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Apple Music share")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.pink.opacity(pendingSharePulse ? 0.42 : 0.18), lineWidth: 1)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func pendingAppleMusicShareHighlight(for group: SpeakerGroupStatus) -> some View {
        if pendingAppleMusicShare != nil {
            let accent = manager.groupAlbumColors[group.id]
                ?? manager.albumArtDominantColor
                ?? .pink
            let isStarting = pendingSharePlaybackGroupID == group.id

            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(accent.opacity(pendingSharePulse || isStarting ? 0.72 : 0.34),
                              lineWidth: isStarting ? 2 : 1.25)
                .shadow(color: accent.opacity(pendingSharePulse || isStarting ? 0.42 : 0.18),
                        radius: isStarting ? 16 : 10)
                .allowsHitTesting(false)
        }
    }

    private func updatePendingSharePulse() {
        guard pendingAppleMusicShare != nil else {
            pendingSharePulse = false
            return
        }

        pendingSharePulse = false
        DispatchQueue.main.async {
            guard pendingAppleMusicShare != nil else { return }
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                pendingSharePulse = true
            }
        }
    }

    private var homeActionZone: some View {
        HStack(spacing: HomeActionTrayPresentation.actionSpacing) {
            transferZone
                .dropDestination(for: String.self) { items, _ in
                    guard let groupID = items.first else { return false }
                    handoffPlayback(toGroupID: groupID)
                    endSpeakerGroupDrag()
                    return true
                } isTargeted: { targeted in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        isTransferZoneTargeted = targeted
                    }
                }
            ungroupZone
                .dropDestination(for: String.self) { items, _ in
                    guard let groupID = items.first else { return false }
                    Task { await manager.separateGroup(groupID: groupID) }
                    endSpeakerGroupDrag()
                    return true
                } isTargeted: { targeted in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        isSeparateZoneTargeted = targeted
                    }
                }
        }
        .padding(.horizontal, HomeActionTrayPresentation.horizontalPadding)
        .padding(.vertical, HomeActionTrayPresentation.verticalPadding)
    }

    private var homeActionBottomPadding: CGFloat {
        MiniPlayerLayoutMetrics.homeActionBottomPadding(
            isMiniPlayerVisible: manager.isConfigured && !manager.showFullPlayer,
            usesSystemAccessory: usesSystemMiniPlayerAccessory
        )
    }

    private var usesSystemMiniPlayerAccessory: Bool {
        if #available(iOS 26.0, *) {
            true
        } else {
            false
        }
    }

    private var transferZone: some View {
        Button {
            handoffPlayback()
        } label: {
            homeDropTarget(
                title: "Handoff",
                systemImage: "arrow.left.arrow.right",
                tint: .blue,
                isTargeted: isTransferZoneTargeted,
                isBusy: isTransferringPlayback
            )
        }
        .buttonStyle(.plain)
        .disabled(isTransferringPlayback || !manager.isConfigured)
        .accessibilityLabel("Handoff playback")
    }

    private var ungroupZone: some View {
        homeDropTarget(
            title: "Ungroup",
            systemImage: "minus",
            tint: .red,
            isTargeted: isSeparateZoneTargeted
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ungroup speaker")
    }

    private func homeDropTarget(
        title: String,
        systemImage: String,
        tint: Color,
        isTargeted: Bool,
        isBusy: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isTargeted ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(isTargeted || isBusy ? .white : .white.opacity(0.62))
        .frame(minWidth: HomeActionTrayPresentation.targetMinWidth)
        .frame(height: HomeActionTrayPresentation.targetHeight)
        .background {
            Capsule()
                .fill((isTargeted || isBusy) ? tint.opacity(0.26) : Color.white.opacity(0.06))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    (isTargeted || isBusy) ? tint.opacity(0.72) : Color.white.opacity(0.1),
                    lineWidth: (isTargeted || isBusy) ? 1.5 : 1
                )
        }
        .scaleEffect(isTargeted ? 1.03 : 1)
        .contentShape(Capsule())
    }

    private func beginSpeakerGroupDrag() {
        scheduleSpeakerGroupDragAutoReset()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            hasActiveSpeakerGroupDragSource = true
        }
    }

    private func setSpeakerGroupDragPreviewVisible(_ visible: Bool) {
        if visible {
            scheduleSpeakerGroupDragAutoReset()
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            isSpeakerGroupDragPreviewVisible = visible
        }
    }

    private func endSpeakerGroupDrag() {
        speakerGroupDragAutoResetTask?.cancel()
        speakerGroupDragAutoResetTask = nil

        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            hasActiveSpeakerGroupDragSource = false
            isSpeakerGroupDragPreviewVisible = false
            isSeparateZoneTargeted = false
            isTransferZoneTargeted = false
            dropTargetGroupID = nil
        }
    }

    private func scheduleSpeakerGroupDragAutoReset() {
        speakerGroupDragAutoResetTask?.cancel()
        speakerGroupDragAutoResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            endSpeakerGroupDrag()
        }
    }

    @ViewBuilder
    private func dragPreview(_ group: SpeakerGroupStatus) -> some View {
        let visibleMembers = group.members
            .filter { !$0.isInvisible }
            .sorted { a, _ in a.id == group.coordinator.id }
        let accent = manager.groupAlbumColors[group.id] ?? .secondary

        HStack(spacing: 10) {
            if let img = manager.groupAlbumImages[group.id] {
                Image(uiImage: img)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.15))
                    .frame(width: 36, height: 36)
                    .overlay { Image(systemName: "hifispeaker.fill").font(.caption).foregroundStyle(.secondary) }
            }
            Text(visibleMembers.map(\.name).joined(separator: " + "))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            setSpeakerGroupDragPreviewVisible(true)
        }
        .onDisappear {
            setSpeakerGroupDragPreviewVisible(false)
        }
    }

    private func transferAppleMusicToSonos() {
        guard !isTransferringPlayback else { return }
        isTransferringPlayback = true

        Task {
            do {
                let track = try await AppleMusicHandoffManager.shared.currentAppleMusicTrack()
                let result = try await searchManager.transferAppleMusicTrack(track, manager: manager)
                AppleMusicHandoffManager.shared.pausePhonePlayback()
                var messages = [forwardHandoffSuccessMessage(for: result)]
                if result.skippedUnsupportedItemCount > 0 {
                    messages.append("Skipped \(result.skippedUnsupportedItemCount) unavailable album tracks")
                }
                if let warning = result.warningMessage {
                    manager.errorMessage = warning
                    messages.append(warning)
                }
                $homeToastMessage.showToast(messages.joined(separator: ". "))
            } catch {
                manager.errorMessage = error.localizedDescription
                $homeToastMessage.showToast(error.localizedDescription)
            }
            isTransferringPlayback = false
        }
    }

    private func forwardHandoffSuccessMessage(for result: HandoffResult) -> String {
        if result.usedAlbumQueue {
            return "Transferred album to \(result.targetName)"
        }
        if result.warningMessage != nil {
            return "Transferred current song"
        }
        return "Transferred to \(result.targetName)"
    }

    private func handoffPlayback() {
        switch HandoffDirectionResolver.direction(forSonosState: manager.transportState) {
        case .sonosToPhone:
            transferSonosToIPhone()
        case .phoneToSonos:
            transferAppleMusicToSonos()
        }
    }

    private func handoffPlayback(toGroupID groupID: String) {
        guard let group = manager.groupStatuses.first(where: { $0.id == groupID }) else {
            handoffPlayback()
            return
        }

        Task { @MainActor in
            await manager.selectSpeaker(
                group.coordinator,
                userInitiatedLiveActivityResume: true
            )
            handoffPlayback()
        }
    }

    private func transferSonosToIPhone() {
        guard !isTransferringPlayback else { return }
        isTransferringPlayback = true

        Task {
            do {
                let result = try await searchManager.transferSonosAppleMusicToPhone(manager: manager)
                var messages = [reverseHandoffSuccessMessage(for: result)]
                if result.skippedUnsupportedItemCount > 0 {
                    messages.append("Skipped \(result.skippedUnsupportedItemCount) unsupported queue items")
                }
                if let warning = result.warningMessage {
                    manager.errorMessage = warning
                    messages.append(warning)
                }
                $homeToastMessage.showToast(messages.joined(separator: ". "))
            } catch {
                manager.errorMessage = error.localizedDescription
                $homeToastMessage.showToast(error.localizedDescription)
            }
            isTransferringPlayback = false
        }
    }

    private func reverseHandoffSuccessMessage(for result: ReverseHandoffResult) -> String {
        if result.transferredTrackCount > 1 {
            return "Transferred \(result.transferredTrackCount) songs to iPhone"
        }
        return "Transferred to iPhone"
    }

    private func handleSpeakerCardDrop(
        sourceID: String,
        targetGroup: SpeakerGroupStatus,
        location: CGPoint
    ) {
        let targetHeight = speakerCardSizes[targetGroup.id]?.height ?? 0
        switch SonosManager.speakerGroupDropIntent(locationY: location.y, targetHeight: targetHeight) {
        case .reorderBefore:
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                manager.reorderSpeakerGroup(
                    sourceID: sourceID,
                    relativeTo: targetGroup.id,
                    placement: .before
                )
            }
        case .merge:
            Task {
                await manager.mergeGroups(sourceGroupID: sourceID, intoGroupID: targetGroup.id)
            }
        case .reorderAfter:
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                manager.reorderSpeakerGroup(
                    sourceID: sourceID,
                    relativeTo: targetGroup.id,
                    placement: .after
                )
            }
        }
    }

    private func handleSpeakerGroupCardTap(_ group: SpeakerGroupStatus) {
        guard pendingAppleMusicShare != nil else {
            Task {
                await manager.selectSpeaker(
                    group.coordinator,
                    userInitiatedLiveActivityResume: true)
            }
            return
        }

        startPendingAppleMusicShare(on: group)
    }

    private func isCurrentGroup(_ group: SpeakerGroupStatus) -> Bool {
        group.coordinator.id == manager.selectedSpeaker?.id
            || group.coordinator.groupId == manager.selectedSpeaker?.groupId
    }

    private func startPendingAppleMusicShare(on group: SpeakerGroupStatus) {
        guard pendingSharePlaybackGroupID == nil,
              let share = pendingAppleMusicShare else { return }

        pendingSharePlaybackGroupID = group.id

        Task {
            do {
                await manager.selectSpeaker(
                    group.coordinator,
                    userInitiatedLiveActivityResume: true)
                let playable = try await AppleMusicSharePlayableResolver.shared.resolve(share)
                let didStart = await searchManager.playLocalAppleMusic(playable, manager: manager)
                guard didStart else {
                    throw AppleMusicSharePlaybackError.playbackFailed(searchManager.errorMessage)
                }

                SharedStorage.clearPendingAppleMusicShare()
                pendingAppleMusicShare = nil
                $homeToastMessage.showToast("Playing on \(speakerGroupDisplayName(group))")
            } catch {
                manager.errorMessage = error.localizedDescription
                $homeToastMessage.showToast(error.localizedDescription)
            }

            pendingSharePlaybackGroupID = nil
        }
    }

    private func speakerGroupDisplayName(_ group: SpeakerGroupStatus) -> String {
        let names = group.members
            .filter { !$0.isInvisible }
            .sorted { a, _ in a.id == group.coordinator.id }
            .map(\.name)
        return names.isEmpty ? group.coordinator.name : names.joined(separator: " + ")
    }

    private func speakerGroupCard(_ group: SpeakerGroupStatus) -> some View {
        SpeakerGroupCardView(
            group: group,
            manager: manager,
            onSelectGroup: { handleSpeakerGroupCardTap($0) })
    }

    // MARK: - Setup (Auto-Discovery)

    private var setupView: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.bottom, 16)

            Text("Connect to Sonos")
                .font(.title2.bold())
                .padding(.bottom, 6)

            if manager.discovery.isScanning && manager.discovery.discoveredSpeakers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching your network…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)
            } else if manager.discovery.discoveredSpeakers.isEmpty {
                Text("No Sonos speakers found on this network.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                Button { manager.discovery.startScan() } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 20)
            } else {
                // Speakers found → we auto-connect to the first coordinator
                // so the user lands on the player straight away. All other
                // speakers still show up via topology once we're in. Tapping
                // a specific row below still works as an explicit override.
                HStack(spacing: 8) {
                    if manager.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text(autoConnectMessage)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.bottom, 16)
            }

            if !manager.discovery.discoveredSpeakers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(manager.discovery.discoveredSpeakers.enumerated()), id: \.element.id) { idx, speaker in
                        Button {
                            Task { await manager.connectFromDiscovery(speaker) }
                        } label: {
                            HStack {
                                Image(systemName: "hifispeaker.fill")
                                    .foregroundStyle(.tint).frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(speaker.name).fontWeight(.medium)
                                    Text(speaker.ipAddress).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if manager.isLoading && manager.selectedSpeaker?.id == speaker.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 12).padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        if idx < manager.discovery.discoveredSpeakers.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                if manager.discovery.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Still scanning…").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }

            Spacer()

            Button { showManualEntry.toggle() } label: {
                Text("Enter IP address manually").font(.footnote)
            }.padding(.bottom, 4)

            if showManualEntry {
                HStack(spacing: 8) {
                    TextField("192.168.1.100", text: $newSpeakerIP)
                        .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                    Button("Connect") { Task { await manager.addSpeaker(ip: newSpeakerIP) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(newSpeakerIP.isEmpty || manager.isLoading)
                }
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let error = manager.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal).padding(.top, 8)
            }

            Spacer().frame(height: 32)
        }
        .animation(.easeInOut(duration: 0.25), value: manager.discovery.discoveredSpeakers.count)
        .animation(.easeInOut(duration: 0.25), value: showManualEntry)
        .onChange(of: manager.discovery.discoveredSpeakers.count) { _, _ in
            attemptAutoConnect()
        }
        .onAppear { attemptAutoConnect() }
    }

    /// Picks the first coordinator from discovery and connects immediately.
    /// Safe to call repeatedly — the `didAutoConnect` latch + `isLoading` /
    /// `isConfigured` guards stop duplicate attempts.
    private func attemptAutoConnect() {
        guard !didAutoConnect,
              !manager.isConfigured,
              !manager.isLoading,
              let preferred = manager.discovery.discoveredSpeakers.first(where: \.isCoordinator)
                  ?? manager.discovery.discoveredSpeakers.first
        else { return }
        didAutoConnect = true
        Task { await manager.connectFromDiscovery(preferred) }
    }

    private var autoConnectMessage: String {
        let speakers = manager.discovery.discoveredSpeakers
        let target = speakers.first(where: \.isCoordinator) ?? speakers.first
        if manager.isLoading, let name = target?.name {
            return "Connecting to \(name)…"
        }
        let n = speakers.count
        return n == 1 ? "Found 1 speaker" : "Found \(n) speakers"
    }

}
