import SwiftUI

extension SpeakerPickerView {

    // MARK: - Now Playing Header

    var nowPlayingHeader: some View {
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

    var nowPlayingArtwork: some View {
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

    var sourceIconName: String {
        switch manager.trackInfo?.source {
        case .tv:
            return "tv"
        case .appleMusic:
            return "apple.logo"
        default:
            return "music.note"
        }
    }

    var nowPlayingSubtitle: String {
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

    var selectedSpeakerTitle: String {
        guard !currentGroupMembers.isEmpty else {
            return manager.selectedSpeaker?.name ?? "Choose a speaker"
        }
        let names = currentGroupMembers.map(\.name)
        return names.joined(separator: " + ")
    }

    var currentGroupBadge: some View {
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

}
