import SwiftUI

extension SpeakerPickerView {

    // MARK: - Group Row

    func groupRow(_ group: SpeakerGroupStatus) -> some View {
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

    func speakerRow(_ speaker: SonosPlayer, inGroup: Bool) -> some View {
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

    func speakerPickerSeparator(opacity: Double) -> some View {
        Rectangle()
            .fill(.white.opacity(opacity))
            .frame(height: SpeakerPickerCardLayout.separatorHeight)
            .accessibilityHidden(true)
    }

    func subtitle(for speaker: SonosPlayer, inGroup: Bool, isCoordinator: Bool) -> String {
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

    func pickerRowContent(
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

    func iconTile(_ systemName: String, artworkImage: UIImage? = nil, isActive: Bool) -> some View {
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
    func indicatorView(_ indicator: SpeakerPickerRowIndicator, isActive: Bool) -> some View {
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

    func volumeRow(speaker: SonosPlayer, vol: Int) -> some View {
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

}
