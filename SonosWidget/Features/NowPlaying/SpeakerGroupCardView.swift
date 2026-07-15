import AVFoundation
import SwiftUI
import UIKit

// MARK: - Speaker Group Card

struct SpeakerCardSizePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]

    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct SpeakerGroupCardView: View {
    let group: SpeakerGroupStatus
    @Bindable var manager: SonosManager
    let onSelectGroup: (SpeakerGroupStatus) -> Void

    @State private var premuteGroupVolume: Int?
    @State private var premuteMemberVolumes: [String: Int] = [:]
    @State private var showMemberVolumes = false

    private var expandButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                showMemberVolumes.toggle()
            }
            if showMemberVolumes {
                Task { await manager.fetchMemberVolumes() }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .rotationEffect(.degrees(showMemberVolumes ? 180 : 0))
                .frame(width: 20, height: 20)
                .background(.white.opacity(showMemberVolumes ? 0.2 : 0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: showMemberVolumes)
    }

    private var isCurrentGroup: Bool {
        group.coordinator.id == manager.selectedSpeaker?.id
            || group.coordinator.groupId == manager.selectedSpeaker?.groupId
    }
    private var isLiveStream: Bool {
        if isCurrentGroup, let trackInfo = manager.trackInfo {
            return trackInfo.isLiveStream
        }
        return group.trackInfo?.isLiveStream == true
    }
    private var accent: Color { manager.groupAlbumColors[group.id] ?? .secondary }
    private var artImage: UIImage? { manager.groupAlbumImages[group.id] }
    private var visibleMembers: [SonosPlayer] {
        group.members.filter { !$0.isInvisible }.sorted { a, _ in a.id == group.coordinator.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top row: art + track info + waveform ──
            Button {
                onSelectGroup(group)
            } label: {
                HStack(spacing: 12) {
                    if group.trackInfo?.source == .tv {
                        // TV input never has cover art — show a dedicated
                        // TV glyph instead of the generic speaker fallback
                        // so the row stays unambiguous when the user is on
                        // soundbar/HDMI input.
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.1))
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "tv")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                    } else if let img = artImage {
                        Image(uiImage: img)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.1))
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "hifispeaker.fill")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(visibleMembers.map(\.name).joined(separator: " + "))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        if let track = group.trackInfo, track.source == .tv {
                            // `getPositionInfo` already populates `artist`
                            // with the format string for TV input
                            // ("Dolby Atmos · MAT" / "Multichannel PCM · 5.1"
                            // / "No signal"), so we render the same
                            // "title — subtitle" pattern as music rows
                            // without any TV-specific branching.
                            Text("\(track.title) — \(track.artist)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let track = group.trackInfo, track.title != "Unknown" {
                            Text("\(track.title) — \(track.artist)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("Idle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    CircularProgressPlayButton(
                        isPlaying: group.transportState == .playing,
                        progress: {
                            guard PlaybackControlPresentation.showsProgressRing(isLiveStream: isLiveStream) else {
                                return 0
                            }
                            if isCurrentGroup, manager.durationSeconds > 0 {
                                return manager.positionSeconds / manager.durationSeconds
                            }
                            if let t = group.trackInfo, t.durationSeconds > 0 {
                                return t.positionSeconds / t.durationSeconds
                            }
                            return 0
                        }(),
                        accent: isCurrentGroup ? accent : .white.opacity(0.55),
                        size: 32,
                        ringWidth: 2.5,
                        isLiveStream: isLiveStream
                    ) {
                        Task {
                            await manager.togglePlayPauseForGroup(
                                groupID: group.id,
                                coordinatorIP: group.coordinator.ipAddress,
                                currentState: group.transportState
                            )
                        }
                    }
                }
                // Without this the outer Button only counts taps on the
                // rendered subviews (art / text / play button); the
                // `Spacer()` gap between title and the circular play
                // button silently swallows touches, so tapping the
                // empty middle of the card does nothing. Forcing a
                // rectangular hit-test region makes the whole row
                // switch speakers as expected.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // ── Volume section: master (collapsed) or per-member (expanded) ──
            if !showMemberVolumes {
                // Master / group volume row
                HStack(spacing: 10) {
                    Image(systemName: group.volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            let newVol = max(0, group.volume - 2)
                            Task {
                                await manager.setVolumeForGroup(
                                    groupID: group.id,
                                    coordinatorIP: group.coordinator.ipAddress,
                                    newVolume: newVol
                                )
                            }
                        }
                        .onLongPressGesture {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            if group.volume > 0 {
                                premuteGroupVolume = group.volume
                                Task {
                                    await manager.setVolumeForGroup(
                                        groupID: group.id,
                                        coordinatorIP: group.coordinator.ipAddress,
                                        newVolume: 0
                                    )
                                }
                            } else if let saved = premuteGroupVolume {
                                premuteGroupVolume = nil
                                Task {
                                    await manager.setVolumeForGroup(
                                        groupID: group.id,
                                        coordinatorIP: group.coordinator.ipAddress,
                                        newVolume: saved
                                    )
                                }
                            }
                        }

                    GroupVolumeBar(volume: group.volume) { step in
                        let newVol = min(100, max(0, group.volume + step))
                        Task {
                            await manager.setVolumeForGroup(
                                groupID: group.id,
                                coordinatorIP: group.coordinator.ipAddress,
                                newVolume: newVol
                            )
                        }
                    }

                    HStack(spacing: 4) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            let newVol = min(100, group.volume + 2)
                            Task {
                                await manager.setVolumeForGroup(
                                    groupID: group.id,
                                    coordinatorIP: group.coordinator.ipAddress,
                                    newVolume: newVol
                                )
                            }
                        } label: {
                            Text("\(group.volume)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 22, height: 28, alignment: .center)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if visibleMembers.count > 1 {
                            expandButton
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
                .padding(.bottom, 8)
                .transition(.opacity)
            } else {
                // Per-member volume rows (master hidden)
                VStack(spacing: 0) {
                    ForEach(visibleMembers) { member in
                        let vol = manager.memberVolumes[member.ipAddress] ?? 0
                        HStack(spacing: 8) {
                            Text(member.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .frame(width: 62, alignment: .leading)

                            Image(systemName: vol == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(width: 14)
                                .contentShape(Rectangle())
                                .onLongPressGesture {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    if vol > 0 {
                                        premuteMemberVolumes[member.ipAddress] = vol
                                        Task { await manager.setMemberVolume(ip: member.ipAddress, volume: 0) }
                                    } else if let saved = premuteMemberVolumes[member.ipAddress] {
                                        premuteMemberVolumes[member.ipAddress] = nil
                                        Task { await manager.setMemberVolume(ip: member.ipAddress, volume: saved) }
                                    }
                                }
                                .animation(.easeInOut, value: vol)

                            GroupVolumeBar(volume: vol) { step in
                                let nv = min(100, max(0, vol + step))
                                Task { await manager.setMemberVolume(ip: member.ipAddress, volume: nv) }
                            }

                            // Volume number (center-aligned) + collapse button on last row
                            HStack(spacing: 4) {
                                Text("\(vol)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.4))
                                    .frame(width: 22, alignment: .center)
                                // Collapse chevron on last member, invisible placeholder on others
                                if member.id == visibleMembers.last?.id {
                                    expandButton
                                } else {
                                    Color.clear.frame(width: 20, height: 20)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(isCurrentGroup ? accent.opacity(0.12) : Color.white.opacity(0.06))
        }
        .overlay {
            if isCurrentGroup {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(accent.opacity(0.3), lineWidth: 1)
            }
        }
        // Re-fetch member volumes whenever group master volume changes while panel is open
        .onChange(of: group.volume) { _, _ in
            guard showMemberVolumes else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                await manager.fetchMemberVolumes()
            }
        }
    }
}

// MARK: - Circular Progress Play Button

private struct CircularProgressPlayButton: View {
    var isPlaying: Bool
    var progress: Double       // 0 … 1
    var accent: Color
    var size: CGFloat
    var ringWidth: CGFloat = 3
    var isLiveStream: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if PlaybackControlPresentation.showsProgressRing(isLiveStream: isLiveStream) {
                    // Track ring
                    Circle()
                        .stroke(accent.opacity(0.22), lineWidth: ringWidth)
                    // Progress ring — animates linearly with each position tick
                    Circle()
                        .trim(from: 0, to: max(0, min(1, progress)))
                        .stroke(accent, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: progress)
                } else {
                    Circle()
                        .fill(accent.opacity(0.16))
                }
                // Icon
                Image(systemName: PlaybackControlPresentation.primarySystemImage(
                    isPlaying: isPlaying,
                    isLiveStream: isLiveStream
                ))
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PlaybackControlPresentation.primaryAccessibilityLabel(
            isPlaying: isPlaying,
            isLiveStream: isLiveStream
        ))
    }
}

// MARK: - Group Volume Bar (tap left = −2, tap right = +2)

private struct GroupVolumeBar: View {
    var volume: Int
    var onStep: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let progress = min(max(Double(volume) / 100.0, 0), 1)
            let thumbX = geo.size.width * progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .frame(height: 4)
                Capsule()
                    .fill(.white.opacity(0.55))
                    .frame(width: max(0, thumbX), height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // This is intentionally a tap-only ±2 control. A zero-distance
            // DragGesture claims vertical touches before the surrounding Home
            // ScrollView can scroll, even though horizontal drags were never
            // used to set a continuous group volume here.
            .gesture(
                SpatialTapGesture()
                    .onEnded { gesture in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onStep(gesture.location.x < thumbX ? -2 : 2)
                    }
            )
        }
        .frame(height: 28)
    }
}
