import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit
struct LocalMusicAlbumDetailView: View {
    let album: Album
    let store: LocalLibraryStore
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager
    @Environment(\.isAnimatedArtworkPlaybackSuspended) var isAnimatedArtworkPlaybackSuspended

    @State var detailedAlbum: Album?
    @State var completeCatalogAlbum: Album?
    @State var isLoading = true
    @State var errorMessage: String?
    @State var coverImage: UIImage?
    @State var themeColor: Color?
    @State var actionInFlight: LocalMusicDetailAction?
    @State var isAppleMusicFavorited = false
    @State var isAppleMusicFavoriteBusy = false
    @State var appleMusicFavoritedTrackIDs: Set<String> = []
    @State var catalogAppleMusicURL: URL?
    @State var animatedArtworkInfo: AnimatedArtworkInfo?
    @State var animatedArtworkReadyURL: URL?
    @State var animatedArtworkBackgroundReadyURL: URL?

    var shouldPlayAnimatedArtworkVideo: Bool {
        AlbumAnimatedArtworkPresentation.shouldPlayVideo(
            isEnabled: AnimatedArtworkFeature.isEnabled,
            isBackgroundPlaybackSuspended: isAnimatedArtworkPlaybackSuspended
        )
    }

    var displayAlbum: Album { detailedAlbum ?? album }
    var coverURL: URL? {
        displayAlbum.artwork.flatMap {
            LocalMusicArtworkURL.imageDownloadURL(for: $0, shortSidePixels: 600)
        } ?? store.catalogArtworkURL(for: displayAlbum) ?? store.catalogArtworkURL(for: album)
    }
    var albumPlayable: LocalServiceAppleMusicPlayable? {
        LocalServiceAppleMusicPlayable.make(album: displayAlbum)?
            .withPreferredArtworkURLString(coverURL?.absoluteString)
    }
    var albumSonosActionContext: LocalMusicContainerSonosActionContext {
        LocalMusicContainerSonosActionContext.album(
            containerID: playbackAlbumID,
            title: displayAlbum.title,
            artist: displayAlbum.artistName
        )
    }
    var albumFavoriteResource: AppleMusicFavoriteResource? {
        AppleMusicFavoriteResource.fromLocalServicePlayable(albumPlayable)
    }
    var playbackAlbumID: String {
        LocalMusicAlbumDetailPresentation.playbackAlbumID(
            currentAlbumID: displayAlbum.id.rawValue,
            completeAlbumID: completeCatalogAlbum?.id.rawValue)
    }
    var currentTrackCount: Int {
        tracks.isEmpty ? displayAlbum.trackCount : tracks.count
    }
    var completeAlbumTrackCount: Int? {
        completeCatalogAlbum.flatMap { album in
            album.tracks.map { Array($0).count }
        } ?? completeCatalogAlbum?.trackCount
    }
    var shouldShowCompleteAlbumButton: Bool {
        LocalMusicAlbumDetailPresentation.shouldShowCompleteAlbumButton(
            currentAlbumID: displayAlbum.id.rawValue,
            currentTrackCount: currentTrackCount,
            completeAlbumID: completeCatalogAlbum?.id.rawValue,
            completeTrackCount: completeAlbumTrackCount)
    }
    var canResolveAppleMusicTitleLink: Bool {
        LocalMusicAlbumDetailPresentation.canResolveAppleMusicTitleLink(
            appleMusicURL: appleMusicURL,
            title: displayAlbum.title,
            artist: displayAlbum.artistName)
    }
    var appleMusicURL: URL? {
        LocalMusicAppleMusicURL.externalURL(
            existingURL: nil,
            catalogURL: catalogAppleMusicURL ?? completeCatalogAlbum?.url ?? displayAlbum.url,
            kind: .album,
            requiresCatalogURL: true)
    }
    var appleMusicURLLookupID: String {
        LocalMusicAlbumDetailPresentation.animatedArtworkLookupID(
            currentAlbumID: displayAlbum.id.rawValue,
            title: displayAlbum.title,
            artist: displayAlbum.artistName,
            completeCatalogAlbumID: completeCatalogAlbum?.id.rawValue)
    }
    var animatedArtworkHeaderURL: URL? {
        LocalMusicAlbumDetailPresentation.animatedArtworkHeaderURL(
            info: animatedArtworkInfo,
            isEnabled: AnimatedArtworkFeature.isEnabled,
            isImmersiveLayoutActive: usesImmersiveAnimatedArtwork
        )
    }
    var animatedArtworkBackgroundURL: URL? {
        LocalMusicAlbumDetailPresentation.animatedArtworkBackgroundURL(
            info: animatedArtworkInfo,
            isEnabled: AnimatedArtworkFeature.isEnabled
        )
    }
    var animatedArtworkBackgroundAspectRatio: CGFloat? {
        guard let value = animatedArtworkInfo?.tallAspectRatio else { return nil }
        return CGFloat(value)
    }
    var usesImmersiveAnimatedArtwork: Bool {
        AlbumAnimatedArtworkPresentation.shouldUseImmersiveLayout(
            backgroundURL: animatedArtworkBackgroundURL,
            readyURL: animatedArtworkBackgroundReadyURL
        )
    }
    var tracks: [Track] {
        guard let tracks = detailedAlbum?.tracks else { return [] }
        return Array(tracks)
    }

    init(
        album: Album,
        store: LocalLibraryStore,
        manager: SonosManager,
        searchManager: SearchManager,
        initialDetailedAlbum: Album? = nil
    ) {
        self.album = album
        self.store = store
        self.manager = manager
        self.searchManager = searchManager
        _detailedAlbum = State(initialValue: initialDetailedAlbum)
        _isLoading = State(initialValue: initialDetailedAlbum == nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                albumScrollableContent
            }
        }
        .background {
            detailBackground
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                albumMenu
            }
        }
        .task {
            await loadDetails()
            await loadCompleteCatalogAlbumIfNeeded()
        }
        .task(id: coverURL) { await loadCoverImage(from: coverURL) }
        .task(id: appleMusicURLLookupID) {
            catalogAppleMusicURL = nil
            await resolveAppleMusicURLIfNeeded()
            await refreshAnimatedArtworkUntilAvailable()
        }
        .task(id: albumFavoriteResource?.id ?? "") {
            await loadAppleMusicFavoriteState()
        }
        .task(id: tracks.map(\.id.rawValue).joined(separator: "|")) {
            await loadAppleMusicTrackFavoriteStates()
        }
    }

}
