import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit

@MainActor
func openLocalMusicAppleMusicURL(_ url: URL, context: String) {
    AppleMusicExternalLinkOpener.open(url, context: context)
}

enum LocalMusicDetailSpacing {
    static let descriptionDividerGap: CGFloat = 14
    static let compactTrackRowVerticalPadding: CGFloat = 8
    static let trackListTopPadding: CGFloat = 0
    static let descriptionSectionBottomPadding = descriptionDividerGap - compactTrackRowVerticalPadding
}

struct LocalMusicContainerDetailMenuContent: View {
    let actions: [LocalMusicContainerDetailMenuAction]
    let perform: (LocalMusicContainerDetailMenuAction) -> Void

    var body: some View {
        ForEach(actions) { action in
            Button {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }

            if action == .openAppleMusic, actions.count > 1 {
                Divider()
            }
        }
    }
}

@MainActor
func performLocalMusicContainerMenuAction(
    _ action: LocalMusicContainerDetailMenuAction,
    playable: LocalServiceAppleMusicPlayable?,
    context: LocalMusicContainerSonosActionContext,
    store: LocalLibraryStore,
    manager: SonosManager,
    searchManager: SearchManager,
    openAppleMusic: () -> Void
) {
    switch action {
    case .openAppleMusic:
        openAppleMusic()
    case .playNext:
        performLocalMusicContainerQueueAction(
            .playNext,
            playable: playable,
            context: context,
            store: store,
            manager: manager,
            searchManager: searchManager
        )
    case .addToQueue:
        performLocalMusicContainerQueueAction(
            .addToQueue,
            playable: playable,
            context: context,
            store: store,
            manager: manager,
            searchManager: searchManager
        )
    case .addToSonosFavorites:
        Task { @MainActor in
            await store.addSonosFavorite(
                playable: playable,
                displayID: context.favoriteDisplayID,
                fallbackKind: context.fallbackKind,
                fallbackTitle: context.fallbackTitle,
                fallbackArtist: context.fallbackArtist,
                fallbackAlbum: context.fallbackAlbum,
                manager: manager,
                searchManager: searchManager)
        }
    }
}

@MainActor
private func performLocalMusicContainerQueueAction(
    _ action: MusicResourceMenuAction,
    playable: LocalServiceAppleMusicPlayable?,
    context: LocalMusicContainerSonosActionContext,
    store: LocalLibraryStore,
    manager: SonosManager,
    searchManager: SearchManager
) {
    Task { @MainActor in
        await store.performSonosQueueAction(
            action,
            playable: playable,
            displayID: context.queueDisplayID(for: action),
            fallbackKind: context.fallbackKind,
            fallbackTitle: context.fallbackTitle,
            fallbackArtist: context.fallbackArtist,
            fallbackAlbum: context.fallbackAlbum,
            manager: manager,
            searchManager: searchManager)
    }
}

@ViewBuilder
func editorialDescriptionSection(text: String?, title: String) -> some View {
    if let text {
        VStack(alignment: .leading, spacing: LocalMusicDetailSpacing.descriptionDividerGap) {
            ExpandableText(
                text: text,
                title: title,
                collapsedLineLimit: ExpandableDescriptionPolicy.appleMusicCollapsedLineLimit,
                font: .subheadline,
                uiTextStyle: .subheadline,
                textColor: .white.opacity(0.68),
                toggleColor: .white.opacity(0.94),
                multilineTextAlignment: .leading
            )

            Divider()
                .overlay(.white.opacity(0.16))
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, LocalMusicDetailSpacing.descriptionSectionBottomPadding)
    }
}

struct LocalMusicDetailActionButton: View {
    let action: LocalMusicDetailAction
    let tint: Color?
    let isActive: Bool
    let isDisabled: Bool
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 7) {
                if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: action.systemImage)
                        .font(.subheadline.weight(.semibold))
                }

                if !action.isCompact {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: action.isCompact ? nil : .infinity)
            .frame(width: action.isCompact ? 48 : nil)
            .padding(.vertical, 10)
            .background(tint ?? .white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel(action.title)
    }
}

struct LocalMusicArtistAlbumSection: Identifiable {
    let title: String
    let songs: [Song]

    var id: String { title }

    nonisolated static func sections(from songs: [Song]) -> [LocalMusicArtistAlbumSection] {
        let grouped = Dictionary(grouping: songs) { song in
            let title = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "Unknown Album" : title
        }

        return grouped
            .map { title, songs in
                LocalMusicArtistAlbumSection(
                    title: title,
                    songs: songs.sorted(by: songSort))
            }
            .sorted { lhs, rhs in
                if lhs.title == "Unknown Album" { return false }
                if rhs.title == "Unknown Album" { return true }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    nonisolated private static func songSort(_ lhs: Song, _ rhs: Song) -> Bool {
        switch (lhs.trackNumber, rhs.trackNumber) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

private struct LocalMusicArtistAlbumHeader: View {
    let section: LocalMusicArtistAlbumSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(section.songs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}

struct LocalMusicArtistLibraryAlbumCard: View {
    let album: Album
    let artworkURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            squareArtwork

            Text(album.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 4) {
                if !album.artistName.isEmpty {
                    Text(album.artistName)
                    Text("·")
                }
                Text("\(album.trackCount) songs")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var squareArtwork: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork = album.artwork {
                    LocalMusicArtworkView(artwork: artwork, contentMode: .fill)
                } else if let artworkURL {
                    RemoteArtworkImageView(url: artworkURL, contentMode: .fill) { _ in
                        fallbackArtwork
                    }
                } else {
                    fallbackArtwork
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var fallbackArtwork: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .overlay {
                Image(systemName: "opticaldisc")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
    }
}

struct LocalMusicArtistAlbumCard: View {
    let summary: LocalMusicArtistAlbumSummary
    let artworkURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            squareArtwork

            Text(summary.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 4) {
                if !summary.artistName.isEmpty {
                    Text(summary.artistName)
                }
                if !summary.artistName.isEmpty {
                    Text("·")
                }
                Text("\(summary.songCount) songs")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var squareArtwork: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artworkURL {
                    RemoteArtworkImageView(url: artworkURL, contentMode: .fill) { _ in
                        fallbackArtwork
                    }
                } else {
                    fallbackArtwork
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var fallbackArtwork: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .overlay {
                Image(systemName: "opticaldisc")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
    }
}

struct LocalMusicDetailArtwork: View {
    let artwork: Artwork?
    let artworkURL: URL?
    let fallbackSystemImage: String
    let diagnosticLabel: String?
    let size: CGFloat

    init(
        artwork: Artwork?,
        artworkURL: URL?,
        fallbackSystemImage: String,
        diagnosticLabel: String? = nil,
        size: CGFloat = 240
    ) {
        self.artwork = artwork
        self.artworkURL = artworkURL
        self.fallbackSystemImage = fallbackSystemImage
        self.diagnosticLabel = diagnosticLabel
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.08))

            fallbackIcon

            switch LocalMusicArtworkSource.preferred(artwork: artwork, remoteURL: artworkURL) {
            case .musicKit(let artwork):
                LocalMusicArtworkView(
                    artwork: artwork,
                    diagnosticLabel: diagnosticLabel,
                    contentMode: LocalMusicDetailArtworkPresentation.contentMode(
                        maximumWidth: artwork.maximumWidth,
                        maximumHeight: artwork.maximumHeight
                    )
                )
                    .frame(width: size, height: size)
            case .remote(let artworkURL):
                LocalMusicDetailRemoteArtworkView(
                    url: artworkURL,
                    diagnosticLabel: diagnosticLabel,
                    contentMode: LocalMusicDetailArtworkPresentation.contentMode(
                        maximumWidth: nil,
                        maximumHeight: nil
                    )
                )
                    .frame(width: size, height: size)
            case .placeholder:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSystemImage)
            .font(.system(size: 56))
            .foregroundStyle(.secondary)
    }

}

private struct LocalMusicDetailRemoteArtworkView: View {
    let url: URL
    let diagnosticLabel: String?
    let contentMode: LocalMusicArtworkURL.ContentMode

    init(
        url: URL,
        diagnosticLabel: String?,
        contentMode: LocalMusicArtworkURL.ContentMode = .fit
    ) {
        self.url = url
        self.diagnosticLabel = diagnosticLabel
        self.contentMode = contentMode
    }

    var body: some View {
        RemoteArtworkImageView(
            url: url,
            contentMode: contentMode,
            diagnosticLabel: diagnosticLabel,
            failureLogPrefix: "Detail remote artwork image failed"
        ) { _ in
            Color.clear
        }
    }
}

struct LocalMusicArtistArtwork: View {
    let artwork: Artwork?
    let artworkURL: URL?
    let size: CGFloat
    let shadow: Bool

    init(
        artwork: Artwork?,
        artworkURL: URL?,
        size: CGFloat = 200,
        shadow: Bool = true
    ) {
        self.artwork = artwork
        self.artworkURL = artworkURL
        self.size = size
        self.shadow = shadow
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))

            Image(systemName: "music.mic")
                .font(.system(size: max(18, size * 0.26)))
                .foregroundStyle(.secondary)

            switch LocalMusicArtworkSource.preferred(artwork: artwork, remoteURL: artworkURL) {
            case .musicKit(let artwork):
                LocalMusicArtworkView(artwork: artwork)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            case .remote(let artworkURL):
                remoteArtwork(url: artworkURL)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            case .placeholder:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(shadow ? 0.3 : 0), radius: shadow ? 16 : 0, y: shadow ? 8 : 0)
    }

    private func remoteArtwork(url: URL) -> some View {
        RemoteArtworkImageView(url: url, contentMode: .fill) { _ in
            Color.clear
        }
    }
}

struct LocalMusicTrackRow: View {
    let track: Track
    let index: Int
    let leadingPolicy: MusicResourceTrackLeadingPolicy
    let artwork: Artwork?
    let artworkURL: URL?
    let fallbackArtworkURL: URL?
    let numberStyle: LocalMusicTrackNumberStyle
    let isPlaying: Bool
    let contextMenuActions: [MusicResourceMenuAction]
    let menuAction: (MusicResourceMenuAction) -> Void
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                leadingArtworkOrNumber

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                trailingAccessory
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .contextMenu {
            MusicResourceContextMenu(actions: contextMenuActions, perform: menuAction)
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isPlaying {
            ProgressView()
                .controlSize(.small)
                .frame(width: 36, height: 32)
        } else {
            HStack(spacing: 8) {
                Text(durationText(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)

                if LocalMusicTrackRowMenuPolicy.showsVisibleMenuButton(
                    leadingPolicy: leadingPolicy,
                    isPlaying: isPlaying,
                    contextMenuActions: contextMenuActions
                ) {
                    Menu {
                        MusicResourceContextMenu(actions: contextMenuActions, perform: menuAction)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                }
            }
            .frame(minWidth: 84, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var leadingArtworkOrNumber: some View {
        switch LocalMusicArtworkSource.preferred(artwork: artwork, remoteURL: selectedArtworkURL) {
        case .musicKit(let artwork):
            LocalMusicArtworkView(artwork: artwork, contentMode: .fill)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .remote(let selectedArtworkURL):
            LocalMusicDetailRemoteArtworkView(url: selectedArtworkURL, diagnosticLabel: nil)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .placeholder:
            Text(trackNumber)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var selectedArtworkURL: URL? {
        leadingPolicy.selectedArtworkURL(
            primaryArtworkURL: artworkURL,
            fallbackArtworkURL: fallbackArtworkURL)
    }

    private var trackNumber: String {
        LocalMusicTrackNumberLabel.text(
            trackNumber: track.trackNumber,
            index: index,
            style: numberStyle)
    }
}

struct LocalMusicSongRow: View {
    let song: Song
    let index: Int
    var subtitle: String? = nil
    var artwork: Artwork? = nil
    var artworkURL: URL? = nil
    var showsArtwork = false
    let isPlaying: Bool
    let contextMenuActions: [MusicResourceMenuAction]
    let menuAction: (MusicResourceMenuAction) -> Void
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                leadingContent

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle ?? song.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isPlaying {
                    ProgressView()
                        .frame(width: 36)
                } else {
                    Text(durationText(song.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .contextMenu {
            MusicResourceContextMenu(actions: contextMenuActions, perform: menuAction)
        }
    }

    @ViewBuilder
    private var leadingContent: some View {
        if showsArtwork {
            switch LocalMusicArtworkSource.preferred(artwork: artwork, remoteURL: artworkURL) {
            case .musicKit(let artwork):
                LocalMusicArtworkView(artwork: artwork, contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            case .remote(let artworkURL):
                LocalMusicDetailRemoteArtworkView(url: artworkURL, diagnosticLabel: nil)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            case .placeholder:
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
            }
        } else {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

enum LocalMusicTrackNumberStyle {
    case albumTrackNumber
    case listPosition
}

enum LocalMusicTrackNumberLabel {
    static func text(
        trackNumber: Int?,
        index: Int,
        style: LocalMusicTrackNumberStyle
    ) -> String {
        switch style {
        case .albumTrackNumber:
            if let trackNumber {
                return "\(trackNumber)"
            }
            return "\(index + 1)"
        case .listPosition:
            return "\(index + 1)"
        }
    }
}

struct LocalMusicDetailStatusBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }
}

func durationText(_ duration: TimeInterval?) -> String {
    guard let duration else { return "--:--" }
    let seconds = max(0, Int(duration.rounded()))
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}
