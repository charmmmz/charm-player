import XCTest
@testable import SonosWidget

final class PlayerDetailNavigationTests: XCTestCase {
    func testPlayerDetailRoutePreservesBrowseItemPayload() {
        let item = BrowseItem(
            id: "apple:album:123",
            title: "Album",
            artist: "Artist",
            album: "Album",
            albumArtURL: "https://example.com/thumb.jpg",
            detailArtworkURL: "https://example.com/detail.jpg",
            uri: "x-sonosapi-hls:album",
            metaXML: "<DIDL-Lite />",
            duration: 42,
            resMD: "<resMD />",
            isContainer: true,
            serviceId: 204,
            cloudType: "ALBUM",
            includeAlbumArtInCloudMetadata: false,
            cloudFavoriteId: "fav-1"
        )

        let route = PlayerDetailRoute.album(item)

        XCTAssertEqual(route.kind, .album)
        XCTAssertEqual(route.browseItem, item)
    }

    func testNowPlayingDetailNavigationCollapsesFullPlayerBeforePush() {
        XCTAssertEqual(
            PlayerDetailNavigationPolicy.transitionAfterNowPlayingDetailTap,
            PlayerDetailNavigationTransition(
                showFullPlayer: false,
                miniPlayerDragOffset: 0,
                selectsHomeTab: true
            )
        )
    }

    func testNowPlayingArtistTypographyMatchesAlbumHeaderArtist() {
        XCTAssertEqual(MusicDetailHeaderTypography.nowPlayingArtistStyle, .body)
        XCTAssertEqual(MusicDetailHeaderTypography.sonosAlbumArtistStyle, .body)
        XCTAssertEqual(MusicDetailHeaderTypography.localAlbumArtistStyle, .title3)
        XCTAssertEqual(MusicDetailHeaderTypography.artistOpacity, 1)
    }

    func testNowPlayingBackgroundUsesSharedArtworkBlurInsteadOfReflection() {
        XCTAssertTrue(NowPlayingBackgroundPresentation.usesSharedArtworkBackground)
        XCTAssertFalse(NowPlayingBackgroundPresentation.usesReflectedArtwork)
    }
}
