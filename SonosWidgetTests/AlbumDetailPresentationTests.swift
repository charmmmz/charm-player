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

        XCTAssertEqual(metrics.circleDimension, 50)
        XCTAssertEqual(metrics.playHeight, 48)
        XCTAssertEqual(metrics.playWidth, 160)
        XCTAssertEqual(metrics.spacing, 16)
    }

    func testAlbumPrimaryActionBarCentersControlGroupOnRegularWidths() {
        let metrics = AlbumPrimaryActionBarMetrics(width: 393)

        XCTAssertEqual(metrics.contentWidth, 292)
        XCTAssertEqual(metrics.contentLeadingInset, 50.5)
        XCTAssertGreaterThan(metrics.contentLeadingInset, metrics.horizontalPadding)
    }

    func testAlbumPrimaryActionBarKeepsMinimumSideInsetOnCompactWidths() {
        let metrics = AlbumPrimaryActionBarMetrics(width: 260)

        XCTAssertEqual(metrics.contentLeadingInset, metrics.horizontalPadding)
    }

    func testEditorialDescriptionPrefersStandardText() {
        XCTAssertEqual(
            EditorialDescriptionPolicy.text(
                standard: "Full editorial copy",
                short: "Short copy",
                tagline: "Tagline"
            ),
            "Full editorial copy"
        )
    }

    func testEditorialDescriptionFallsBackToShortThenTagline() {
        XCTAssertEqual(
            EditorialDescriptionPolicy.text(
                standard: " ",
                short: "Short copy",
                tagline: "Tagline"
            ),
            "Short copy"
        )

        XCTAssertEqual(
            EditorialDescriptionPolicy.text(
                standard: nil,
                short: "",
                tagline: "Tagline"
            ),
            "Tagline"
        )
    }

    func testExpandableDescriptionUsesAppleMusicMoreLabel() {
        XCTAssertEqual(ExpandableDescriptionPolicy.moreLabel, "MORE")
    }

    func testExpandableDescriptionStripsSimpleItalicMarkupForPlainText() {
        XCTAssertEqual(
            ExpandableDescriptionTextFormatter.plainText(
                from: "The 2023's <i>NEVER ENOUGH</i> and <em>Son of Spergy</em> era"
            ),
            "The 2023's NEVER ENOUGH and Son of Spergy era"
        )
    }

    func testExpandableDescriptionSegmentsItalicMarkup() {
        XCTAssertEqual(
            ExpandableDescriptionTextFormatter.segments(
                from: "A <i>NEVER</i> B <em>ENOUGH</em>"
            ),
            [
                ExpandableDescriptionTextSegment(text: "A ", isItalic: false),
                ExpandableDescriptionTextSegment(text: "NEVER", isItalic: true),
                ExpandableDescriptionTextSegment(text: " B ", isItalic: false),
                ExpandableDescriptionTextSegment(text: "ENOUGH", isItalic: true)
            ]
        )
    }

    func testArtistTopSongsPreviewShowsAtMostFiveSongs() {
        XCTAssertEqual(LocalMusicArtistTopSongsPolicy.previewCount(totalCount: 3), 3)
        XCTAssertEqual(LocalMusicArtistTopSongsPolicy.previewCount(totalCount: 5), 5)
        XCTAssertEqual(LocalMusicArtistTopSongsPolicy.previewCount(totalCount: 12), 5)
    }

    func testArtistTopSongsOnlyShowsFullListLinkWhenThereAreMoreThanFiveSongs() {
        XCTAssertFalse(LocalMusicArtistTopSongsPolicy.shouldShowFullListLink(totalCount: 5))
        XCTAssertTrue(LocalMusicArtistTopSongsPolicy.shouldShowFullListLink(totalCount: 6))
    }
}
