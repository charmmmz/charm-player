import AVFoundation
import SwiftUI

struct AlbumDetailView: View {
    let albumItem: BrowseItem
    let searchManager: SearchManager
    let manager: SonosManager
    @Environment(\.isAnimatedArtworkPlaybackSuspended) var isAnimatedArtworkPlaybackSuspended

    @State var response: SonosCloudAPI.AlbumBrowseResponse?
    @State var isLoading = true
    @State var errorText: String?
    @State var playingItemId: String?
    @State var toastMessage: String?
    @State var isFavorited = false
    @State var coverImage: UIImage?
    @State var themeColor: Color?
    @State var isOpeningAppleMusicLink = false
    @State var fallbackAppleMusicArtworkURL: URL?
    @State var animatedArtworkInfo: AnimatedArtworkInfo?
    @State var animatedArtworkReadyURL: URL?
    @State var animatedArtworkBackgroundReadyURL: URL?
    @State var resolvedAlbumID: String?

    var shouldPlayAnimatedArtworkVideo: Bool {
        AlbumAnimatedArtworkPresentation.shouldPlayVideo(
            isEnabled: AnimatedArtworkFeature.isEnabled,
            isBackgroundPlaybackSuspended: isAnimatedArtworkPlaybackSuspended
        )
    }

    var albumTitle: String { response?.title ?? albumItem.title }
    var artistName: String { response?.subtitle ?? albumItem.artist }
    /// Resolves the album cover from any non-empty image source. NetEase Cloud
    /// Music's browseAlbum often omits the album-level image but populates
    /// each track's `images.tile1x1`, so we fall through to the first track's
    /// art before giving up and showing the placeholder disc icon.
    var coverURL: String? {
        DetailArtworkURLSelection.firstAvailable(
            entryArtworkURL: albumItem.preferredDetailArtworkURL,
            responseArtworkURL: response?.images?.tile1x1,
            fallbackArtworkURL: response?.tracks?.items?.first?.images?.tile1x1
        )
    }
    var tracks: [SonosCloudAPI.AlbumTrackItem] {
        response?.tracks?.items ?? []
    }
    var playbackAlbumItem: BrowseItem {
        AlbumPlaybackItemPolicy.playbackItem(from: albumItem, resolvedAlbumID: resolvedAlbumID)
    }
    var appleMusicArtworkResource: AppleMusicFavoriteResource? {
        AppleMusicDetailArtworkLink.resource(
            from: albumItem,
            searchManager: searchManager,
            allowedTypes: [.albums]
        )
    }
    var canResolveAppleMusicAlbumURL: Bool {
        appleMusicArtworkResource != nil || fallbackAppleMusicArtworkURL != nil || canSearchAppleMusicAlbumURL
    }
    var canSearchAppleMusicAlbumURL: Bool {
        AppleMusicExternalLinkResolver.isAppleMusicItem(albumItem, searchManager: searchManager)
            && AppleMusicFavoriteResourceType(cloudType: albumItem.cloudType) == .albums
            && meaningfulAppleMusicSearchValue(albumTitle) != nil
            && meaningfulAppleMusicSearchValue(artistName) != nil
    }
    var appleMusicAlbumLinkLookupID: String {
        [
            albumItem.id,
            albumItem.uri ?? "",
            albumTitle,
            artistName,
            appleMusicArtworkResource?.id ?? ""
        ].joined(separator: "|")
    }
    var animatedArtworkHeaderURL: URL? {
        AlbumAnimatedArtworkPresentation.headerURL(
            info: animatedArtworkInfo,
            isEnabled: AnimatedArtworkFeature.isEnabled,
            isImmersiveLayoutActive: usesImmersiveAnimatedArtwork
        )
    }
    var animatedArtworkBackgroundURL: URL? {
        AlbumAnimatedArtworkPresentation.fullScreenBackgroundURL(
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

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                albumScrollableContent
            }
        }
        .background {
            albumBackground
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                albumMenu
            }
        }
        .task { await loadAlbum() }
        .task(id: coverURL) { await loadCoverImage() }
        .task(id: appleMusicAlbumLinkLookupID) {
            await refreshAppleMusicArtworkURL()
        }
        .task {
            // Sonos Favorites are only fetched by SearchView's task; if the
            // user opens this page before visiting Browse, `isFavorited`
            // would always return false. Trigger a one-shot load and resync.
            await searchManager.ensureBrowseContentLoaded(manager: manager)
            isFavorited = searchManager.isFavorited(albumItem)
        }
        .onAppear { isFavorited = searchManager.isFavorited(albumItem) }
        .toast($toastMessage)
    }

}
