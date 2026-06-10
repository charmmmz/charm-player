import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct SonosLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SonosActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            // The `dynamicIsland` closure is a function builder body — adding
            // any `let` before the `DynamicIsland(...)` expression turns it
            // into a multi-statement closure that needs an explicit return.
            let islandSource = context.state.playbackSource
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ArtView(data: context.state.albumArtThumbnail, size: 50, source: islandSource)
                        .padding(.leading, 2)
                        .padding(.trailing, 6)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                DynamicIslandExpandedRegion(.center) {
                    let accent = themeColor(from: context.state.dominantColorHex)
                    let extra = context.state.groupMemberCount > 1
                        ? " + \(context.state.groupMemberCount - 1)" : ""
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.trackTitle)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text("\(context.state.isTVSource ? "LIVE ON" : "ON") \(context.attributes.speakerName.uppercased())\(extra)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(accent.opacity(0.8))
                                .lineLimit(1)
                            if context.state.isPlaying {
                                AnimatedWaveform(accent: accent, barCount: 3, height: 7)
                            }
                        }
                        .padding(.top, 1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    let source = context.state.playbackSourceRaw
                        .flatMap(PlaybackSource.init(rawValue:)) ?? .unknown
                    VStack(alignment: .trailing, spacing: 4) {
                        if source != .unknown {
                            SourceBadgeView(source: source,
                                            tintColor: themeColor(from: context.state.dominantColorHex),
                                            compact: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    let accent = themeColor(from: context.state.dominantColorHex)
                    VStack(spacing: 8) {
                        LiveProgressView(state: context.state)
                        if context.state.isTVSource {
                            TVSoundbarControlsView(
                                state: context.state,
                                accent: accent,
                                compact: false)
                        } else {
                            HStack(spacing: 40) {
                                if context.state.isLiveStream {
                                    Button(intent: PlayPauseIntent()) {
                                        Image(systemName: context.state.isPlaying ? "stop.fill" : "play.fill")
                                            .font(.title2)
                                            .foregroundStyle(accent)
                                    }.buttonStyle(.plain)
                                } else {
                                    Button(intent: PreviousTrackIntent()) {
                                        Image(systemName: "backward.fill")
                                            .font(.callout)
                                            .foregroundStyle(.white.opacity(0.85))
                                    }.buttonStyle(.plain)

                                    Button(intent: PlayPauseIntent()) {
                                        Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.title2)
                                            .foregroundStyle(accent)
                                    }.buttonStyle(.plain)

                                    Button(intent: NextTrackIntent()) {
                                        Image(systemName: "forward.fill")
                                            .font(.callout)
                                            .foregroundStyle(.white.opacity(0.85))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                // Compact/minimal views are static-only per Apple docs — no animation supported.
                ArtView(data: context.state.albumArtThumbnail, size: 20, source: islandSource)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } compactTrailing: {
                // Compact/minimal regions are static-only — no animation supported by Apple.
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: context.state.isPlaying ? 12 : 10, weight: .medium))
                    .foregroundStyle(themeColor(from: context.state.dominantColorHex))
                    .padding(.trailing, 4)
            } minimal: {
                ArtView(data: context.state.albumArtThumbnail, size: 20, source: islandSource)
                    .clipShape(Circle())
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let context: ActivityViewContext<SonosActivityAttributes>

    @ViewBuilder
    var body: some View {
        switch context.state.resolvedLiveActivityPresentation {
        case .classic:
            ClassicLockScreenView(context: context)
        case .widgetCard:
            WidgetCardLockScreenView(context: context)
        case .widgetTVRemote:
            WidgetTVRemoteLockScreenView(context: context)
        }
    }
}

private struct ClassicLockScreenView: View {
    let context: ActivityViewContext<SonosActivityAttributes>

    var body: some View {
        let accent = themeColor(from: context.state.dominantColorHex)
        let extra = context.state.groupMemberCount > 1
            ? " + \(context.state.groupMemberCount - 1)" : ""
        let source = context.state.playbackSource

        VStack(spacing: 6) {
            // ── Single row: art | text | controls ──
            HStack(spacing: 12) {
                ArtView(data: context.state.albumArtThumbnail, size: 48, source: source)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.trackTitle)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(context.state.artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(context.state.isTVSource ? "LIVE ON" : "ON") \(context.attributes.speakerName.uppercased())\(extra)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(accent.opacity(0.8))
                            .lineLimit(1)
                        if context.state.isPlaying {
                            AnimatedWaveform(accent: accent, barCount: 4, height: 8)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: context.state.isTVSource ? 8 : 14) {
                    if context.state.isTVSource {
                        TVSoundbarControlsView(
                            state: context.state,
                            accent: accent,
                            compact: true)
                    } else if context.state.isLiveStream {
                        Button(intent: PlayPauseIntent()) {
                            Image(systemName: context.state.isPlaying ? "stop.fill" : "play.fill")
                                .font(.title3)
                                .foregroundStyle(accent)
                        }.buttonStyle(.plain)
                    } else {
                        Button(intent: PreviousTrackIntent()) {
                            Image(systemName: "backward.fill").font(.callout)
                        }.buttonStyle(.plain)

                        Button(intent: PlayPauseIntent()) {
                            Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .foregroundStyle(accent)
                        }.buttonStyle(.plain)

                        Button(intent: NextTrackIntent()) {
                            Image(systemName: "forward.fill").font(.callout)
                        }.buttonStyle(.plain)
                    }
                }
            }

            // ── Progress bar ──
            LiveProgressView(state: context.state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            ZStack {
                // Suppress the blurred-art backdrop on TV input — there's no
                // album art to blur, and a stale thumbnail from the prior
                // music session would otherwise tint the lock screen the
                // wrong color.
                if source != .tv,
                   let data = context.state.albumArtThumbnail,
                   let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 40)
                        .scaleEffect(1.5)
                        .clipped()
                }
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .activityBackgroundTint(.clear)
        .activitySystemActionForegroundColor(.white)
    }
}

private struct WidgetCardLockScreenView: View {
    let context: ActivityViewContext<SonosActivityAttributes>

    var body: some View {
        let state = context.state
        let accent = themeColor(from: state.dominantColorHex)
        let source = state.playbackSource
        let extra = state.groupMemberCount > 1
            ? " + \(state.groupMemberCount - 1)" : ""

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ArtView(data: state.albumArtThumbnail, size: 58, source: source)
                    .shadow(color: .black.opacity(0.35), radius: 7, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(state.isPlaying ? "NOW PLAYING" : "CONTINUE") ON \(context.attributes.speakerName.uppercased())\(extra)")
                            .font(LiveActivityWidgetMeta.font)
                            .tracking(LiveActivityWidgetMeta.tracking)
                            .foregroundStyle(LiveActivityWidgetMeta.textColor)
                            .lineLimit(1)
                        if state.isPlaying {
                            AnimatedWaveform(accent: accent, barCount: 3, height: 7)
                        }
                    }

                    QualityBadgeRow(quality: state.audioQualityLabel)

                    Text(state.trackTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(trackSubtitle(state))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if source != .unknown {
                    SourceBadgeView(source: source, tintColor: accent, compact: true)
                }
            }

            LiveProgressView(state: state)

            WidgetTransportControlsView(state: state, accent: accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background {
            WidgetLiveActivityBackdrop(state: state, accent: accent)
        }
        .activityBackgroundTint(.clear)
        .activitySystemActionForegroundColor(.white)
    }
}

private struct WidgetTVRemoteLockScreenView: View {
    let context: ActivityViewContext<SonosActivityAttributes>

    var body: some View {
        let state = context.state
        let accent = themeColor(from: state.dominantColorHex)
        let extra = state.groupMemberCount > 1
            ? " + \(state.groupMemberCount - 1)" : ""

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ArtView(data: state.albumArtThumbnail, size: 50, source: .tv)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("LIVE ON \(context.attributes.speakerName.uppercased())\(extra)")
                            .font(LiveActivityWidgetMeta.font)
                            .tracking(LiveActivityWidgetMeta.tracking)
                            .foregroundStyle(LiveActivityWidgetMeta.textColor)
                            .lineLimit(1)
                        if state.isPlaying {
                            AnimatedWaveform(accent: accent, barCount: 3, height: 7)
                        }
                    }

                    QualityBadgeRow(quality: state.audioQualityLabel)

                    Text(state.trackTitle)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(tvLiveSubtitle(state))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                SourceBadgeView(source: .tv, tintColor: accent, compact: true)
            }

            LiveProgressView(state: state)

            HStack(spacing: 10) {
                TVSoundbarControlsView(state: state, accent: accent, compact: false)
                Spacer(minLength: 0)
                LiveSourcePill(accent: accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background {
            WidgetLiveActivityBackdrop(state: state, accent: accent)
        }
        .activityBackgroundTint(.clear)
        .activitySystemActionForegroundColor(.white)
    }
}

private enum LiveActivityWidgetMeta {
    static let font = Font.system(size: 8, weight: .semibold, design: .rounded)
    static let tracking: CGFloat = 0.45
    static let textColor = Color.white.opacity(0.42)
    static let badgeTint = Color.white.opacity(0.48)
    static let qualityBadgeHeight: CGFloat = 9
}

private struct QualityBadgeRow: View {
    let quality: String?

    @ViewBuilder
    var body: some View {
        if let quality = quality?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quality.isEmpty {
            let badge = AudioQuality.badgeImageName(forQualityLabel: quality)
            let companion = AudioQuality.badgeCompanionLabel(forQualityLabel: quality)

            HStack(alignment: .center, spacing: 4) {
                Text("IN")
                    .font(LiveActivityWidgetMeta.font)
                    .tracking(LiveActivityWidgetMeta.tracking)
                    .foregroundStyle(LiveActivityWidgetMeta.textColor)

                if let badge {
                    Image(badge)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(LiveActivityWidgetMeta.badgeTint)
                        .scaledToFit()
                        .frame(height: LiveActivityWidgetMeta.qualityBadgeHeight)
                        .accessibilityHidden(true)
                }

                if let companion {
                    Text(companion.uppercased())
                        .font(LiveActivityWidgetMeta.font)
                        .tracking(LiveActivityWidgetMeta.tracking)
                        .foregroundStyle(LiveActivityWidgetMeta.textColor)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct WidgetTransportControlsView: View {
    let state: SonosActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        HStack(spacing: 16) {
            Button(intent: VolumeDownIntent()) {
                Image(systemName: "speaker.minus.fill")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.52))

            Spacer(minLength: 0)

            HStack(spacing: state.isLiveStream ? 0 : 22) {
                if state.isLiveStream {
                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: state.isPlaying ? "stop.fill" : "play.fill")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                } else {
                    Button(intent: PreviousTrackIntent()) {
                        Image(systemName: "backward.fill")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.plain)

                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)

                    Button(intent: NextTrackIntent()) {
                        Image(systemName: "forward.fill")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.white.opacity(0.88))
            .frame(minWidth: 92)

            Spacer(minLength: 0)

            Button(intent: VolumeUpIntent()) {
                Image(systemName: "speaker.plus.fill")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.52))
        }
        .frame(height: 26)
    }
}

private struct LiveSourcePill: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(1)
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            Capsule()
                .fill(.white.opacity(0.09))
        }
        .overlay {
            Capsule()
                .stroke(accent.opacity(0.42), lineWidth: 1)
        }
    }
}

private struct WidgetLiveActivityBackdrop: View {
    let state: SonosActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        ZStack {
            if state.playbackSource != .tv,
               let data = state.albumArtThumbnail,
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 42)
                    .scaleEffect(1.55)
                    .clipped()
            }

            LinearGradient(
                colors: [
                    accent.opacity(state.playbackSource == .tv ? 0.20 : 0.26),
                    .black.opacity(0.72),
                    .black.opacity(0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - TV Soundbar Controls

private struct TVSoundbarControlsView: View {
    let state: SonosActivityAttributes.ContentState
    let accent: Color
    var compact: Bool

    var body: some View {
        let nightOn = state.isSoundbarNightModeEnabled
        let speechLevel = state.soundbarSpeechEnhancementLevel

        HStack(spacing: compact ? 8 : 12) {
            Button(intent: ToggleNightModeIntent()) {
                TVSoundbarControlContent(
                    icon: nightOn ? "moon.fill" : "moon",
                    title: "Night",
                    value: nightOn ? "On" : "Off",
                    isOn: nightOn,
                    accent: accent,
                    compact: compact)
            }
            .buttonStyle(.plain)

            Button(intent: ToggleSpeechEnhancementIntent()) {
                TVSoundbarControlContent(
                    icon: speechLevel.isOn ? "text.bubble.fill" : "text.bubble",
                    title: compact ? "Voice" : "Speech",
                    value: speechLevel.isOn ? speechLevel.shortLabel : "Off",
                    isOn: speechLevel.isOn,
                    accent: accent,
                    compact: compact)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct TVSoundbarControlContent: View {
    let icon: String
    let title: String
    let value: String
    let isOn: Bool
    let accent: Color
    var compact: Bool

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 2) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                    Text(title)
                        .font(.system(size: 7.5, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(width: 38, height: 34)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                        Text(value)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
            }
        }
        .foregroundStyle(isOn ? accent : .white.opacity(0.78))
        .background {
            Capsule()
                .fill(isOn ? accent.opacity(0.20) : .white.opacity(0.09))
        }
        .overlay {
            Capsule()
                .stroke(isOn ? accent.opacity(0.55) : .white.opacity(0.14), lineWidth: 1)
        }
    }
}

// MARK: - Animated Waveform (lock screen + expanded DI only)
// Compact/minimal Dynamic Island does NOT support animation.
//
// SF Symbol system animations are driven by the OS renderer — the only reliable way
// to get continuous animation in a Live Activity extension process.

private struct AnimatedWaveform: View {
    let accent: Color
    var barCount: Int = 4
    var height: CGFloat = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = 0.25 + 0.75 * abs(sin(t * 5.0 + Double(i) * 1.3))
                    Capsule()
                        .frame(width: 2, height: height * h)
                }
            }
            .frame(height: height)
            .foregroundStyle(accent)
        }
    }
}

// MARK: - Real-time Progress

private struct LiveProgressView: View {
    let state: SonosActivityAttributes.ContentState

    var body: some View {
        let accent = themeColor(from: state.dominantColorHex)

        if state.isLiveSource {
            HStack(spacing: 6) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 3)
                Text("LIVE")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.78))
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 3)
            }
            .frame(height: 12)
        } else if state.isPlaying,
                  let start = state.startedAt,
                  let end = state.endsAt,
                  end > Date() {
            ProgressView(timerInterval: start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(accent)
        } else if state.durationSeconds > 0 {
            ProgressView(value: state.positionSeconds, total: state.durationSeconds)
                .progressViewStyle(.linear)
                .tint(accent)
        }
    }
}

// MARK: - Album Art

private struct ArtView: View {
    let data: Data?
    let size: CGFloat
    /// Optional source hint — when this is `.tv` we skip the "music.note"
    /// fallback even if `data` happens to be set (it shouldn't be, but the
    /// art clear can race against Live Activity push updates) and render a
    /// `tv` glyph instead so the lock screen / Dynamic Island stay accurate.
    var source: PlaybackSource = .unknown

    var body: some View {
        if source != .tv, let data, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        } else {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(Color.white.opacity(0.15))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: source == .tv ? "tv" : "music.note")
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - Helpers

private func trackSubtitle(_ state: SonosActivityAttributes.ContentState) -> String {
    let parts = [state.artist, state.album]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && $0 != "—" }
    return parts.isEmpty ? "Unknown" : parts.joined(separator: " · ")
}

private func tvLiveSubtitle(_ state: SonosActivityAttributes.ContentState) -> String {
    let subtitle = trackSubtitle(state)
    return subtitle == "Unknown" ? "Live audio" : subtitle
}

private func themeColor(from hex: String?) -> Color {
    hex.flatMap { Color(hex: $0) } ?? .white
}
