import AVFoundation
import SwiftUI
import UIKit

extension NowPlayingOverlay {

    // MARK: - Progress

    /// Inner progress content — no outer padding, usable in both portrait and landscape info column.
    @ViewBuilder
    var progressContent: some View {
        if manager.trackInfo?.source == .tv {
            tvFormatPanel
        } else if manager.trackInfo?.isLiveStream == true {
            liveProgressContent
        } else {
            musicProgressContent
        }
    }

    /// Live broadcast indicator — replaces the seek bar for streams that
    /// have no fixed duration (Apple Music 1, TuneIn live stations,
    /// internet radio, line-in / AirPlay). Mimics Apple Music's player:
    /// thin rule on each side with a centered "LIVE" pill.
    var liveProgressContent: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(height: 3)
            Text("LIVE")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.78))
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(height: 3)
        }
        .frame(height: 18)
        .padding(.horizontal, 4)
    }

    /// TV input has no scrubbable timeline. The signal status now lives
    /// on the album-art bottom-left (next to where the music badge would
    /// be), so this row only needs to carry the audio format chip.
    /// The slot height is fixed so switching between signal/no-signal
    /// doesn't shift everything below it.
    @ViewBuilder
    var tvFormatPanel: some View {
        let format = manager.trackInfo?.tvFormat
        HStack {
            Spacer(minLength: 0)
            // For Atmos: `[badge] <variant>` (e.g. `[●] TrueHD`); we drop
            // channel layout because Atmos is object-based and the "2.0"
            // in "MAT 2.0" is a protocol version, not a channel count.
            //
            // For non-Atmos: codec + channel layout as separate slots
            // (e.g. `Multichannel PCM · 5.1`).
            if let format, format.hasSignal {
                HStack(spacing: 4) {
                    if format.isAtmos {
                        Image("BadgeDolbyAtmos")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(height: 11)
                            .accessibilityLabel("Dolby Atmos")
                        if let variant = format.atmosVariant {
                            Text(variant)
                                .font(.system(size: 9, weight: .semibold))
                        }
                    } else {
                        Text(format.codec)
                            .font(.system(size: 9, weight: .semibold))
                        if let layout = format.channelLayout {
                            Text("·")
                                .font(.system(size: 9))
                            Text(layout)
                                .font(.system(size: 9, weight: .medium).monospaced())
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.white.opacity(0.08), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    /// Two square-ish cards side-by-side, mirroring the Sonos S2 app's TV
    /// audio panel: large glyph in the top-left, title + state stacked
    /// flush-bottom-left. No accent borders or fills — the active state
    /// just brightens the glyph and state text. Tap = toggle (Night Sound)
    /// or open level picker (Speech Enhancement).
    var soundbarEQPanel: some View {
        HStack(spacing: 10) {
            nightSoundCard
            speechEnhancementCard
        }
    }

    var nightSoundCard: some View {
        let isOn = manager.nightMode
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await manager.toggleNightMode() }
        } label: {
            soundbarEQCard(
                iconName: isOn ? "moon.fill" : "moon",
                title: "Night Sound",
                stateText: isOn ? "On" : "Off",
                isOn: isOn
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Night Sound")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }

    var speechEnhancementCard: some View {
        let level = manager.speechEnhancement
        // SF Symbol with a slash overlay when Off matches the Sonos
        // reference's "person with x" silhouette closely enough; the
        // filled variant for On reads as "speech is being enhanced".
        let icon = level.isOn ? "waveform.badge.mic" : "waveform.slash"
        return Menu {
            Picker("Speech Enhancement", selection: Binding(
                get: { manager.speechEnhancement },
                set: { newLevel in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await manager.setSpeechEnhancement(newLevel) }
                }
            )) {
                ForEach(SpeechEnhancementLevel.allCases, id: \.self) { lvl in
                    Text(lvl.label).tag(lvl)
                }
            }
        } label: {
            soundbarEQCard(
                iconName: icon,
                title: "Speech Enhancement",
                stateText: level.label,
                isOn: level.isOn
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speech Enhancement")
        .accessibilityValue(level.label)
    }

    /// Shared chrome for both EQ cards. Icon top-left, title + state pinned
    /// bottom-left. Height is **locked** to 92pt — without a hard cap the
    /// inner `Spacer` competes with the outer page `Spacer`s and the cards
    /// balloon to fill any leftover vertical slack, breaking the layout.
    func soundbarEQCard(
        iconName: String,
        title: String,
        stateText: String,
        isOn: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.55))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isOn ? 1.0 : 0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(stateText)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(isOn ? 0.7 : 0.45))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Standard music timeline + audio-quality badge. Extracted so the TV-mode
    /// branch can swap in its own panel without touching the slider.
    var musicProgressContent: some View {
        VStack(spacing: 4) {
            ThumblessSlider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : manager.positionSeconds },
                    set: { scrubPosition = $0; isScrubbing = true }
                ),
                range: 0...max(manager.durationSeconds, 1),
                thumbDragOnly: true,
                onEditingChanged: { editing in
                    if !editing {
                        isScrubbing = false
                        Task { await manager.seekTo(scrubPosition) }
                    }
                }
            )

            HStack {
                Text(SonosTime.display(isScrubbing ? scrubPosition : manager.positionSeconds))
                    .monospacedDigit()

                Spacer()

                if let quality = manager.trackInfo?.audioQuality {
                    // Keep only descriptive text beside the compact technical
                    // token: Atmos text is already carried by its badge, and a
                    // generic "Audio" label may itself be the same bit-depth /
                    // sample-rate pair. Lossless/Hi-Res remain because their
                    // glyph-only badge does not repeat the wording.
                    let companion = quality.nowPlayingCompanionLabel
                    HStack(spacing: 4) {
                        if let badge = quality.badgeAssetImageName {
                            Image(badge)
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .frame(height: 11)
                                .accessibilityLabel(quality.label)
                        }
                        if let companion {
                            Text(companion)
                                .font(.system(size: 9, weight: .semibold))
                        }
                        if let sr = quality.sampleRate, let bd = quality.bitDepth {
                            // Only draw the separator if there's a preceding
                            // text token; otherwise the dot looks orphaned
                            // sitting alone next to the badge.
                            if companion != nil {
                                Text("·")
                                    .font(.system(size: 9))
                            }
                            Text("\(bd)/\(sr / 1000)kHz")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
                }

                Spacer()

                Text(SonosTime.display(manager.durationSeconds))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    var progressView: some View {
        progressContent.padding(.horizontal, 32)
    }

    // MARK: - Playback Controls

    @ViewBuilder
    var playbackControls: some View {
        if manager.trackInfo?.isLiveStream == true {
            liveBroadcastControls
        } else {
            standardPlaybackControls
        }
    }

    /// Live-stream variant: a single Stop/Play button. Skip / shuffle /
    /// repeat are intentionally hidden — the underlying transport doesn't
    /// honor them for live broadcasts and the official Apple Music UI
    /// presents the same pared-down layout.
    var liveBroadcastControls: some View {
        let compact = verticalSizeClass == .compact
        let stopSize: CGFloat = compact ? 30 : 40
        let playFrame: CGFloat = compact ? 44 : 60

        return HStack {
            Spacer()
            Button { Task { await manager.togglePlayPause() } } label: {
                Image(systemName: manager.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: stopSize))
                    .frame(width: playFrame, height: playFrame)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
    }

    var standardPlaybackControls: some View {
        let compact = verticalSizeClass == .compact
        let playSize: CGFloat   = compact ? 34 : 44
        let skipSize: CGFloat   = compact ? 20 : 26
        let modeSize: CGFloat   = compact ? 14 : 16
        let modeFrame: CGFloat  = compact ? 30 : 38
        let playFrame: CGFloat  = compact ? 44 : 60

        let queueActive = manager.isPlayingFromQueue

        return HStack(spacing: 0) {
            // Shuffle
            Button { Task { await manager.toggleShuffle() } } label: {
                let accent = manager.albumArtDominantColor ?? .white
                Image(systemName: "shuffle")
                    .font(.system(size: modeSize, weight: .semibold))
                    .foregroundStyle(manager.isShuffling && queueActive ? .white : .white.opacity(queueActive ? 0.45 : 0.2))
                    .frame(width: modeFrame, height: modeFrame)
                    .background(manager.isShuffling && queueActive ? accent.opacity(0.85) : Color.clear,
                                in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!queueActive)

            Spacer()

            // Previous
            Button { Task { await manager.previousTrack() } } label: {
                Image(systemName: "backward.fill").font(.system(size: skipSize))
                    .foregroundStyle(queueActive ? .white : .white.opacity(0.2))
            }
            .disabled(!queueActive)

            Spacer()

            // Play / Pause
            Button { Task { await manager.togglePlayPause() } } label: {
                Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: playSize))
                    .frame(width: playFrame, height: playFrame)
                    .contentTransition(.symbolEffect(.replace))
            }

            Spacer()

            // Next
            Button { Task { await manager.nextTrack() } } label: {
                Image(systemName: "forward.fill").font(.system(size: skipSize))
            }

            Spacer()

            // Repeat
            Button { Task { await manager.toggleRepeat() } } label: {
                let accent = manager.albumArtDominantColor ?? .white
                Image(systemName: manager.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: modeSize, weight: .semibold))
                    .foregroundStyle(manager.repeatMode != .off && queueActive ? .white : .white.opacity(queueActive ? 0.45 : 0.2))
                    .frame(width: modeFrame, height: modeFrame)
                    .background(manager.repeatMode != .off && queueActive ? accent.opacity(0.85) : Color.clear,
                                in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!queueActive)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
    }

    // MARK: - Volume

    var currentVolume: Int {
        isDraggingVolume ? Int(volumeSliderValue) : manager.volume
    }

    var volumeControl: some View {
        HStack(spacing: 10) {
            Image(systemName: currentVolume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    let newVol = max(0, currentVolume - 2)
                    Task { await manager.updateVolume(newVol) }
                }
                .onLongPressGesture {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if currentVolume > 0 {
                        premuteVolume = currentVolume
                        Task { await manager.updateVolume(0) }
                    } else if let saved = premuteVolume {
                        premuteVolume = nil
                        Task { await manager.updateVolume(saved) }
                    }
                }

            ThumblessSlider(
                value: Binding(
                    get: { isDraggingVolume ? volumeSliderValue : Double(manager.volume) },
                    set: { volumeSliderValue = $0; isDraggingVolume = true }
                ),
                range: 0...100,
                tintColor: .white.opacity(0.8),
                onStepTap: { step in
                    let newVol = min(100, max(0, currentVolume + step))
                    Task { await manager.updateVolume(newVol) }
                },
                onEditingChanged: { editing in
                    if !editing {
                        isDraggingVolume = false
                        Task { await manager.updateVolume(Int(volumeSliderValue)) }
                    }
                }
            )

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let newVol = min(100, currentVolume + 2)
                Task { await manager.updateVolume(newVol) }
            } label: {
                Text("\(currentVolume)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Bottom Actions

    var bottomButtonHeight: CGFloat { 38 }
    var bottomSideSlotWidth: CGFloat { bottomButtonHeight }

    func bottomActions(showQueue: Bool) -> some View {
        let slots = NowPlayingBottomActionPolicy.slots(showQueue: showQueue)

        return HStack(spacing: 8) {
            ForEach(slots) { slot in
                bottomActionSlot(slot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    func bottomActionSlot(_ slot: NowPlayingBottomActionSlot) -> some View {
        switch slot {
        case .emptyLeading:
            Color.clear
                .frame(width: bottomSideSlotWidth, height: bottomButtonHeight)
                .accessibilityHidden(true)
        case .queue:
            bottomQueueButton
                .frame(width: bottomSideSlotWidth, height: bottomButtonHeight)
        case .speaker:
            bottomSpeakerButton
        case .contextMenu:
            nowPlayingContextMenuButton
                .frame(width: bottomSideSlotWidth, height: bottomButtonHeight)
        }
    }

    var bottomSpeakerButton: some View {
        Button {
            manager.showingSpeakerPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: manager.isEverywhereActive ? "house.fill" : "hifispeaker.fill")
                    .font(.subheadline)
                if manager.isEverywhereActive {
                    Text("Everywhere")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                } else {
                    Text(manager.selectedSpeaker?.name ?? "Select Speaker")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if manager.currentGroupMembers.count > 1 {
                        Text("+ \(manager.currentGroupMembers.count - 1)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.2), in: Capsule())
                    }
                }
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(height: bottomButtonHeight)
            .padding(.horizontal, 16)
            .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    var bottomQueueButton: some View {
        Button {
            manager.showingQueue = true
            Task { await manager.loadQueue() }
        } label: {
            Image(systemName: "list.bullet")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: bottomButtonHeight, height: bottomButtonHeight)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Queue")
    }

    var nowPlayingContextMenuButton: some View {
        Menu {
            ForEach(nowPlayingContextMenuActions) { action in
                Button {
                    performNowPlayingContextMenuAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(!action.isEnabled)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: bottomButtonHeight, height: bottomButtonHeight)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    var nowPlayingContextMenuActions: [NowPlayingContextMenuAction] {
        NowPlayingContextMenuPolicy.actions(
            canAddSonosFavorite: currentTrackBrowseItemForSonosFavorite != nil
                && !isAddingCurrentTrackToSonosFavorites,
            canAddAppleMusicFavorite: currentAppleMusicTrackResource != nil
                && !isAddingCurrentTrackToAppleMusicFavorites,
            canOpenAppleMusicTrack: canOpenCurrentAppleMusicTrack && !isOpeningAppleMusicLink
        )
    }

    func performNowPlayingContextMenuAction(_ action: NowPlayingContextMenuAction) {
        switch action {
        case .addToSonosFavorites:
            addCurrentTrackToSonosFavorites()
        case .addToAppleMusicFavorites:
            addCurrentTrackToAppleMusicFavorites()
        case .openInAppleMusic:
            openCurrentAppleMusicTrack()
        }
    }

}
