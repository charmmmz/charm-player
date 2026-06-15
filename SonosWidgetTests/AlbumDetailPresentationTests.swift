import XCTest
import UIKit
@testable import SonosWidget

final class AlbumDetailPresentationTests: XCTestCase {
    func testSonosAlbumPrimaryActionsUseSonosFavorite() {
        XCTAssertEqual(
            AlbumPrimaryActionPolicy.actions(favoriteKind: .sonos),
            [.shuffle, .play, .favorite(.sonos)]
        )
    }

    func testLocalMusicAlbumPrimaryActionsUseAppleMusicFavorite() {
        XCTAssertEqual(
            AlbumPrimaryActionPolicy.actions(favoriteKind: .appleMusic),
            [.shuffle, .play, .favorite(.appleMusic)]
        )
    }

    func testAlbumOverflowActionsExcludeFavorite() {
        XCTAssertEqual(
            AlbumOverflowActionPolicy.albumActions,
            [.playNext, .addToQueue]
        )
    }

    func testSonosAlbumTrackMenuUsesSonosFavorite() {
        XCTAssertEqual(
            AlbumTrackMenuActionPolicy.actions(
                favoriteKind: .sonos,
                isFavoriteActive: false,
                isQueueable: true
            ),
            [
                .playNow,
                .playNext,
                .addToQueue,
                .favorite(.sonos, isActive: false)
            ]
        )
    }

    func testLocalMusicAlbumTrackMenuUsesAppleMusicFavorite() {
        XCTAssertEqual(
            AlbumTrackMenuActionPolicy.actions(
                favoriteKind: .appleMusic,
                isFavoriteActive: true,
                isQueueable: true
            ),
            [
                .playNow,
                .playNext,
                .addToQueue,
                .favorite(.appleMusic, isActive: true)
            ]
        )
    }

    func testAlbumTrackSubtitleHidesMatchingAlbumArtist() {
        XCTAssertNil(
            AlbumTrackSubtitlePolicy.subtitle(
                trackArtist: "Radiohead",
                albumArtist: "Radiohead"
            )
        )
    }

    func testAlbumTrackSubtitleShowsDifferentTrackArtist() {
        XCTAssertEqual(
            AlbumTrackSubtitlePolicy.subtitle(
                trackArtist: "Kali Uchis",
                albumArtist: "Daniel Caesar"
            ),
            "Kali Uchis"
        )
    }

    func testVividThemeColorIsMutedAndDarkened() {
        let original = AlbumThemeColorComponents(hue: 0.0, saturation: 0.95, brightness: 0.92, alpha: 1.0)
        let muted = AlbumThemeColorPolicy.mutedComponents(from: original)

        XCTAssertLessThan(muted.saturation, original.saturation)
        XCTAssertLessThan(muted.brightness, original.brightness)
        XCTAssertEqual(muted.saturation, 0.48, accuracy: 0.001)
        XCTAssertEqual(muted.brightness, 0.48, accuracy: 0.001)
    }

    func testMutedThemeColorKeepsLowSaturationUsable() {
        let original = AlbumThemeColorComponents(hue: 0.58, saturation: 0.18, brightness: 0.32, alpha: 1.0)
        let muted = AlbumThemeColorPolicy.mutedComponents(from: original)

        XCTAssertEqual(muted.hue, original.hue, accuracy: 0.001)
        XCTAssertEqual(muted.saturation, 0.16, accuracy: 0.001)
        XCTAssertEqual(muted.brightness, 0.20, accuracy: 0.001)
    }

    func testAlbumPrimaryActionBarUsesAppleMusicSizedControls() {
        let metrics = AlbumPrimaryActionBarMetrics(width: 393)

        XCTAssertEqual(metrics.circleDimension, 56)
        XCTAssertEqual(metrics.playHeight, 54)
        XCTAssertEqual(metrics.playWidth, 177)
        XCTAssertEqual(metrics.spacing, 24)
    }
}
