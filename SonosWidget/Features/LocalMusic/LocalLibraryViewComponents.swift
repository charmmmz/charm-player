import MusicKit
import Observation
import SwiftUI

enum LocalServiceRowAccessory {
    case play
    case chevron
    case progress
}

extension LocalServiceRowAccessory {
    var musicResourceAccessory: MusicResourceAccessory {
        switch self {
        case .play:
            return .play
        case .chevron:
            return .chevron
        case .progress:
            return .progress
        }
    }
}

struct LocalLibraryAlphabetIndexBar: View {
    let titles: [String]
    let onSelect: (String) -> Void

    @State private var lastSelectedTitle: String?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 1) {
                ForEach(titles, id: \.self) { title in
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.pink)
                        .frame(width: 24, height: itemHeight(in: proxy.size.height))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            select(title)
                        }
                }
            }
            .frame(width: 28, height: proxy.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectTitle(at: value.location.y, height: proxy.size.height)
                    }
                    .onEnded { _ in
                        lastSelectedTitle = nil
                    }
            )
        }
        .frame(width: 28)
        .padding(.trailing, 2)
    }

    private func itemHeight(in height: CGFloat) -> CGFloat {
        guard !titles.isEmpty else { return 14 }
        return min(18, max(12, height / CGFloat(titles.count)))
    }

    private func selectTitle(at yPosition: CGFloat, height: CGFloat) {
        guard !titles.isEmpty else { return }
        let itemHeight = max(1, height / CGFloat(titles.count))
        let index = min(max(Int(yPosition / itemHeight), 0), titles.count - 1)
        select(titles[index])
    }

    private func select(_ title: String) {
        guard lastSelectedTitle != title else { return }
        lastSelectedTitle = title
        onSelect(title)
    }
}

enum LocalLibraryArtworkStyle {
    case square
    case artistAvatar
}

struct LocalServiceCardArtworkSize: Equatable {
    let width: CGFloat
    let height: CGFloat
}

enum LocalServiceCardArtworkMetrics {
    static func size(isStationLike: Bool) -> LocalServiceCardArtworkSize {
        LocalServiceCardArtworkSize(width: 138, height: 138)
    }

    static func contentMode(
        isStationLike: Bool,
        maximumWidth: Int? = nil,
        maximumHeight: Int? = nil
    ) -> LocalMusicArtworkURL.ContentMode {
        guard let maximumWidth,
              let maximumHeight,
              maximumWidth > 1,
              maximumHeight > 1 else {
            return .fit
        }

        let aspectRatio = Double(maximumWidth) / Double(maximumHeight)
        if aspectRatio > 1.2 {
            return .fill
        }

        return .fit
    }
}

enum LocalServiceLibraryItemKind: Equatable {
    case song
    case album
    case artist
    case playlist
    case station
}

enum LocalServiceLibraryPrimaryAction: Equatable {
    case play
    case navigate
}

enum LocalServiceLibraryInteraction {
    static func primaryAction(
        for kind: LocalServiceLibraryItemKind
    ) -> LocalServiceLibraryPrimaryAction {
        switch kind {
        case .song, .station:
            return .play
        case .album, .artist, .playlist:
            return .navigate
        }
    }
}

struct LocalServiceCardPresentation: Identifiable {
    let item: LocalServiceCardItem
    let playable: LocalServiceAppleMusicPlayable?

    var id: String { item.id }

    init(item: LocalServiceCardItem) {
        self.item = item
        self.playable = item.playable
    }
}

enum LocalServiceCardItem: Identifiable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case station(Station)
    case recentlyPlayed(RecentlyPlayedMusicItem)
    case recommendation(MusicPersonalRecommendation.Item)

    var id: String {
        switch self {
        case .song(let song): return "song-\(song.id.rawValue)"
        case .album(let album): return "album-\(album.id.rawValue)"
        case .artist(let artist): return "artist-\(artist.id.rawValue)"
        case .playlist(let playlist): return "playlist-\(playlist.id.rawValue)"
        case .station(let station): return "station-\(station.id.rawValue)"
        case .recentlyPlayed(let item): return "recent-\(item.id.rawValue)"
        case .recommendation(let item): return "recommendation-\(item.id.rawValue)"
        }
    }

    var playbackID: String {
        switch self {
        case .song(let song): return song.id.rawValue
        case .album(let album): return album.id.rawValue
        case .artist(let artist): return artist.id.rawValue
        case .playlist(let playlist): return playlist.id.rawValue
        case .station(let station): return station.id.rawValue
        case .recentlyPlayed(let item): return item.id.rawValue
        case .recommendation(let item): return item.id.rawValue
        }
    }

    var resourceKind: MusicResourceKind {
        switch self {
        case .song:
            return .song
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        case .station:
            return .station
        case .recentlyPlayed(let item):
            switch item {
            case .album: return .album
            case .playlist: return .playlist
            case .station: return .station
            @unknown default: return .unknown
            }
        case .recommendation(let item):
            switch item {
            case .album: return .album
            case .playlist: return .playlist
            case .station: return .station
            @unknown default: return .unknown
            }
        }
    }

    var playable: LocalServiceAppleMusicPlayable? {
        switch self {
        case .song(let song):
            return LocalServiceAppleMusicPlayable.make(song: song)
        case .album(let album):
            return LocalServiceAppleMusicPlayable.make(album: album)
        case .artist(let artist):
            return LocalServiceAppleMusicPlayable.make(artist: artist)
        case .playlist(let playlist):
            return LocalServiceAppleMusicPlayable.make(playlist: playlist)
        case .station(let station):
            return LocalServiceAppleMusicPlayable.make(station: station)
        case .recentlyPlayed(let item):
            return LocalServiceAppleMusicPlayable.make(recentlyPlayed: item)
        case .recommendation(let item):
            return LocalServiceAppleMusicPlayable.make(recommendation: item)
        }
    }

    var title: String {
        switch self {
        case .song(let song): return song.title
        case .album(let album): return album.title
        case .artist(let artist): return artist.name
        case .playlist(let playlist): return playlist.name
        case .station(let station): return station.name
        case .recentlyPlayed(let item): return item.title
        case .recommendation(let item): return item.title
        }
    }

    var subtitle: String {
        switch self {
        case .song(let song): return song.artistName
        case .album(let album): return album.artistName
        case .artist: return "Artist"
        case .playlist(let playlist): return playlist.curatorName ?? "Playlist"
        case .station: return "Station"
        case .recentlyPlayed(let item): return item.subtitle ?? recentlyPlayedFallbackTitle(item)
        case .recommendation(let item): return item.subtitle ?? recommendationFallbackTitle(item)
        }
    }

    var artwork: Artwork? {
        switch self {
        case .song(let song): return song.artwork
        case .album(let album): return album.artwork
        case .artist(let artist): return artist.artwork
        case .playlist(let playlist): return playlist.artwork
        case .station(let station): return station.artwork
        case .recentlyPlayed(let item): return item.artwork
        case .recommendation(let item): return item.artwork
        }
    }

    var fallbackSystemImage: String {
        switch self {
        case .song: return "music.note"
        case .album: return "square.stack"
        case .artist: return "music.mic"
        case .playlist: return "music.note.list"
        case .station: return "dot.radiowaves.left.and.right"
        case .recentlyPlayed(let item): return recentlyPlayedFallbackIcon(item)
        case .recommendation(let item): return recommendationFallbackIcon(item)
        }
    }

    var isStationLike: Bool {
        switch self {
        case .station:
            return true
        case .recentlyPlayed(let item):
            if case .station = item { return true }
            return false
        case .recommendation(let item):
            if case .station = item { return true }
            return false
        case .song, .album, .artist, .playlist:
            return false
        }
    }

    var cardArtworkSize: LocalServiceCardArtworkSize {
        LocalServiceCardArtworkMetrics.size(isStationLike: isStationLike)
    }

    func catalogArtworkURL(using store: LocalLibraryStore) -> URL? {
        switch self {
        case .song(let song):
            return store.catalogArtworkURL(for: song)
        case .album, .artist, .playlist, .station, .recentlyPlayed, .recommendation:
            switch self {
            case .album(let album):
                return store.catalogArtworkURL(for: album)
            case .artist(let artist):
                return store.catalogArtworkURL(for: artist)
            case .playlist(let playlist):
                return store.catalogArtworkURL(for: playlist)
            case .recentlyPlayed(let item):
                return store.catalogArtworkURL(for: item)
            case .recommendation(let item):
                return store.catalogArtworkURL(for: item)
            case .song, .station:
                return nil
            }
        }
    }

    var artworkDiagnosticLabel: String? {
        switch self {
        case .station(let station):
            return "station-card title='\(station.name)' id='\(station.id.rawValue)'"
        case .playlist(let playlist):
            return "playlist-card title='\(playlist.name)' id='\(playlist.id.rawValue)'"
        case .recentlyPlayed(let item):
            switch item {
            case .playlist:
                return "recent-playlist-card title='\(item.title)' id='\(item.id.rawValue)'"
            case .station:
                return "recent-station-card title='\(item.title)' id='\(item.id.rawValue)'"
            case .album:
                return nil
            @unknown default:
                return nil
            }
        case .recommendation(let item):
            switch item {
            case .playlist:
                return "recommendation-playlist-card title='\(item.title)' id='\(item.id.rawValue)'"
            case .station:
                return "recommendation-station-card title='\(item.title)' id='\(item.id.rawValue)'"
            case .album:
                return nil
            @unknown default:
                return nil
            }
        case .song, .album, .artist:
            return nil
        }
    }

    private func recentlyPlayedFallbackTitle(_ item: RecentlyPlayedMusicItem) -> String {
        switch item {
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .station: return "Station"
        @unknown default: return "Apple Music"
        }
    }

    private func recommendationFallbackTitle(_ item: MusicPersonalRecommendation.Item) -> String {
        switch item {
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .station: return "Station"
        @unknown default: return "Apple Music"
        }
    }

    private func recentlyPlayedFallbackIcon(_ item: RecentlyPlayedMusicItem) -> String {
        switch item {
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .station: return "dot.radiowaves.left.and.right"
        @unknown default: return "music.note"
        }
    }

    private func recommendationFallbackIcon(_ item: MusicPersonalRecommendation.Item) -> String {
        switch item {
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .station: return "dot.radiowaves.left.and.right"
        @unknown default: return "music.note"
        }
    }
}

struct LocalLibraryArtworkTile: View {
    let artwork: Artwork?
    let artworkURL: URL?
    let fallbackSystemImage: String
    let diagnosticLabel: String?
    let artworkContentMode: LocalMusicArtworkURL.ContentMode

    init(
        artwork: Artwork?,
        artworkURL: URL?,
        fallbackSystemImage: String,
        diagnosticLabel: String?,
        artworkContentMode: LocalMusicArtworkURL.ContentMode = .fit
    ) {
        self.artwork = artwork
        self.artworkURL = artworkURL
        self.fallbackSystemImage = fallbackSystemImage
        self.diagnosticLabel = diagnosticLabel
        self.artworkContentMode = artworkContentMode
    }

    @State private var didLogMissingSources = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))

                fallbackIcon

                switch LocalMusicArtworkSource.preferred(artwork: artwork, remoteURL: artworkURL) {
                case .musicKit(let artwork):
                    LocalMusicArtworkView(
                        artwork: artwork,
                        diagnosticLabel: diagnosticLabel,
                        contentMode: artworkContentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                case .remote(let artworkURL):
                    RemoteArtworkImageView(
                        url: artworkURL,
                        contentMode: artworkContentMode,
                        diagnosticLabel: diagnosticLabel,
                        failureLogPrefix: "Remote artwork image failed"
                    ) { _ in
                        Color.clear
                    }
                case .placeholder:
                    EmptyView()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            logMissingSourcesIfNeeded()
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSystemImage)
            .font(.title3)
            .foregroundStyle(.secondary)
    }

    private func logMissingSourcesIfNeeded() {
        guard !didLogMissingSources,
              artwork == nil,
              artworkURL == nil,
              let diagnosticLabel else {
            return
        }
        didLogMissingSources = true
        SonosLog.debug(
            .localService,
            "Artwork tile placeholder no-sources \(diagnosticLabel)")
    }
}

@MainActor
@Observable
final class LocalLibraryPullRefreshController {
    private(set) var pullDistance = 0.0
    private(set) var isRefreshing = false

    @ObservationIgnored private var hasTriggeredInCurrentPull = false

    var indicatorOpacity: Double {
        LocalLibraryPullRefreshPolicy.indicatorOpacity(
            pullDistance: pullDistance,
            isRefreshing: isRefreshing)
    }

    func handle(
        distance: Double,
        isExternalRefreshActive: Bool,
        hasLoaded: Bool,
        onRefresh: @escaping @MainActor () async -> Void
    ) {
        if abs(distance - pullDistance) >= 1 || distance == 0 {
            pullDistance = distance
        }

        if LocalLibraryPullRefreshPolicy.shouldResetGesture(pullDistance: distance) {
            hasTriggeredInCurrentPull = false
        }

        guard LocalLibraryPullRefreshPolicy.shouldTrigger(
            pullDistance: distance,
            isRefreshing: isRefreshing || isExternalRefreshActive,
            hasLoaded: hasLoaded,
            hasTriggeredInCurrentPull: hasTriggeredInCurrentPull
        ) else {
            return
        }

        trigger(onRefresh: onRefresh)
    }

    private func trigger(onRefresh: @escaping @MainActor () async -> Void) {
        guard !isRefreshing else { return }
        isRefreshing = true
        hasTriggeredInCurrentPull = true

        Task { @MainActor [weak self] in
            await onRefresh()
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                isRefreshing = false
                pullDistance = 0
            }
        }
    }
}

struct LocalLibraryPullRefreshIndicator: View {
    let controller: LocalLibraryPullRefreshController

    var body: some View {
        let opacity = controller.indicatorOpacity

        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.regular)
            .tint(.white.opacity(0.74))
            .padding(10)
            .background(.black.opacity(0.18), in: Circle())
            .opacity(opacity)
            .scaleEffect(0.86 + (0.14 * opacity))
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.16), value: opacity)
            .padding(.top, 8)
    }
}

struct LocalLibraryPullDistancePreferenceKey: PreferenceKey {
    static var defaultValue = 0.0

    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = max(value, nextValue())
    }
}

#Preview {
    LocalLibraryView(manager: SonosManager(), searchManager: SearchManager())
}
