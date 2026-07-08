import XCTest
import UIKit
@testable import SonosWidget

final class AlbumDetailPresentationTests: XCTestCase {
    func testResolvedAlbumIDReplacesRawTitleForPlaybackURI() {
        let item = BrowseItem(
            id: "NEVER ENOUGH",
            title: "NEVER ENOUGH",
            artist: "Daniel Caesar",
            album: "NEVER ENOUGH",
            albumArtURL: "https://example.com/cover.jpg",
            uri: "x-rincon-cpcontainer:1004206cNEVER ENOUGH?sid=204&flags=8300&sn=2",
            isContainer: true,
            serviceId: 204,
            cloudType: "ALBUM"
        )

        let resolved = AlbumPlaybackItemPolicy.playbackItem(
            from: item,
            resolvedAlbumID: "album:1681322859"
        )

        XCTAssertEqual(resolved.id, "album:1681322859")
        XCTAssertEqual(
            resolved.uri,
            "x-rincon-cpcontainer:1004206calbum%3a1681322859?sid=204&flags=8300&sn=2"
        )
    }

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

    func testSongTrackMenuUsesSonosAndAppleMusicFavoritesTogether() {
        XCTAssertEqual(
            AlbumTrackMenuActionPolicy.songActions(
                isSonosFavoriteActive: true,
                isAppleMusicFavoriteActive: false,
                isQueueable: true
            ),
            [
                .playNow,
                .playNext,
                .addToQueue,
                .favorite(.sonos, isActive: true),
                .favorite(.appleMusic, isActive: false)
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

    func testAlbumHeaderArtistTypographyUsesReadableWhiteStyle() {
        XCTAssertEqual(MusicDetailHeaderTypography.sonosAlbumArtistStyle, .body)
        XCTAssertEqual(MusicDetailHeaderTypography.localAlbumArtistStyle, .title3)
        XCTAssertEqual(MusicDetailHeaderTypography.artistOpacity, 1)
    }

    func testAlbumHeaderAppleMusicLinkUsesTitleInsteadOfArtwork() {
        XCTAssertTrue(
            AlbumHeaderAppleMusicLinkPolicy.shouldLinkTitle(canResolveAppleMusicURL: true)
        )
        XCTAssertFalse(
            AlbumHeaderAppleMusicLinkPolicy.shouldLinkArtwork(canResolveAppleMusicURL: true)
        )
    }

    func testAlbumHeaderAppleMusicLinkKeepsUnavailableTitleStatic() {
        XCTAssertFalse(
            AlbumHeaderAppleMusicLinkPolicy.shouldLinkTitle(canResolveAppleMusicURL: false)
        )
        XCTAssertFalse(
            AlbumHeaderAppleMusicLinkPolicy.shouldLinkArtwork(canResolveAppleMusicURL: false)
        )
    }

    func testAlbumHeaderAnimatedArtworkUsesPlayableRelayURLWhenOnlySquareArtworkIsAvailable() {
        let info = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: nil,
            appleMusicURLString: "https://music.apple.com/us/album/american-idiot/1161539183",
            artist: "Green Day",
            album: "American Idiot",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            AlbumAnimatedArtworkPresentation.headerURL(
                info: info,
                isEnabled: true
            )?.absoluteString,
            "https://video.example.com/square.m3u8"
        )
    }

    func testAlbumHeaderAnimatedArtworkIsHiddenWhenTallFullScreenArtworkIsAvailable() {
        let info = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: "https://video.example.com/tall.m3u8",
            appleMusicURLString: "https://music.apple.com/us/album/american-idiot/1161539183",
            artist: "Green Day",
            album: "American Idiot",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNil(AlbumAnimatedArtworkPresentation.headerURL(info: info, isEnabled: true))
    }

    func testAlbumHeaderAnimatedArtworkUsesStaticCoverUntilImmersiveBackgroundIsReady() {
        let info = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: "https://video.example.com/tall.m3u8",
            appleMusicURLString: "https://music.apple.com/us/album/american-idiot/1161539183",
            artist: "Green Day",
            album: "American Idiot",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNil(
            AlbumAnimatedArtworkPresentation.headerURL(
                info: info,
                isEnabled: true,
                isImmersiveLayoutActive: false
            )
        )
        XCTAssertNil(
            AlbumAnimatedArtworkPresentation.headerURL(
                info: info,
                isEnabled: true,
                isImmersiveLayoutActive: true
            )
        )
    }

    func testAlbumAnimatedArtworkReadyStateSurvivesEquivalentRenderableInfo() {
        let current = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: "https://video.example.com/tall.m3u8",
            appleMusicURLString: "https://music.apple.com/us/album/after-hours/1499378108",
            artist: "The Weeknd",
            album: "After Hours",
            source: .cache,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )
        let refreshed = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: "https://video.example.com/tall.m3u8",
            appleMusicURLString: "https://music.apple.com/us/album/after-hours/1499378108?ls=1",
            artist: "The Weeknd",
            album: "After Hours",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertFalse(
            AlbumAnimatedArtworkPresentation.shouldResetReadyState(
                current: current,
                next: refreshed
            )
        )
    }

    func testAlbumHeaderAnimatedArtworkFallsBackToStaticCoverWhenUnavailable() {
        let info = AnimatedArtworkInfo(
            squareURLString: nil,
            tallURLString: nil,
            appleMusicURLString: "https://music.apple.com/us/album/american-idiot/1161539183",
            artist: "Green Day",
            album: "American Idiot",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNil(AlbumAnimatedArtworkPresentation.headerURL(info: info, isEnabled: true))
        XCTAssertNil(AlbumAnimatedArtworkPresentation.headerURL(info: info, isEnabled: false))
    }

    func testAlbumFullScreenAnimatedArtworkPrefersTallArtworkWhenAvailable() {
        let info = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: "https://video.example.com/tall.m3u8",
            appleMusicURLString: "https://music.apple.com/us/album/never-enough-bonus-version/1681198089",
            artist: "Daniel Caesar",
            album: "NEVER ENOUGH (Bonus Version)",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            AlbumAnimatedArtworkPresentation.fullScreenBackgroundURL(
                info: info,
                isEnabled: true
            )?.absoluteString,
            "https://video.example.com/tall.m3u8"
        )
    }

    func testAlbumFullScreenAnimatedArtworkFallsBackToStaticBackgroundWhenUnavailable() {
        let info = AnimatedArtworkInfo(
            squareURLString: nil,
            tallURLString: nil,
            appleMusicURLString: "https://music.apple.com/us/album/never-enough-bonus-version/1681198089",
            artist: "Daniel Caesar",
            album: "NEVER ENOUGH (Bonus Version)",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNil(AlbumAnimatedArtworkPresentation.fullScreenBackgroundURL(info: info, isEnabled: true))
        XCTAssertNil(AlbumAnimatedArtworkPresentation.fullScreenBackgroundURL(info: info, isEnabled: false))
    }

    func testAlbumFullScreenAnimatedArtworkRequiresTallArtwork() {
        let info = AnimatedArtworkInfo(
            squareURLString: "https://video.example.com/square.m3u8",
            tallURLString: nil,
            appleMusicURLString: "https://music.apple.com/us/album/american-idiot/1161539183",
            artist: "Green Day",
            album: "American Idiot",
            source: .url,
            resolvedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNil(AlbumAnimatedArtworkPresentation.fullScreenBackgroundURL(info: info, isEnabled: true))
    }

    func testAlbumImmersiveLayoutWaitsForBackgroundVideoReady() throws {
        let tallURL = try XCTUnwrap(URL(string: "https://video.example.com/tall.m3u8"))
        let otherURL = try XCTUnwrap(URL(string: "https://video.example.com/other.m3u8"))

        XCTAssertFalse(
            AlbumAnimatedArtworkPresentation.shouldUseImmersiveLayout(
                backgroundURL: tallURL,
                readyURL: nil
            )
        )
        XCTAssertFalse(
            AlbumAnimatedArtworkPresentation.shouldUseImmersiveLayout(
                backgroundURL: tallURL,
                readyURL: otherURL
            )
        )
        XCTAssertTrue(
            AlbumAnimatedArtworkPresentation.shouldUseImmersiveLayout(
                backgroundURL: tallURL,
                readyURL: tallURL
            )
        )
        XCTAssertFalse(
            AlbumAnimatedArtworkPresentation.shouldUseImmersiveLayout(
                backgroundURL: nil,
                readyURL: tallURL
            )
        )
    }

    func testAlbumImmersiveAnimatedArtworkSpacerAnchorsTitleNearViewportMiddle() {
        XCTAssertEqual(
            AlbumAnimatedArtworkPresentation.immersiveHeaderSpacerHeight(
                containerWidth: 390,
                viewportHeight: 852,
                videoAspectRatio: 0.75
            ),
            300,
            accuracy: 0.5
        )
    }

    func testAlbumImmersiveContentBackdropSoftlyOverlapsHeaderContent() {
        XCTAssertEqual(
            AlbumAnimatedArtworkPresentation.contentBackdropTopPadding(isImmersive: true),
            -144
        )
        XCTAssertEqual(
            AlbumAnimatedArtworkPresentation.contentBackdropTopPadding(isImmersive: false),
            0
        )
        XCTAssertEqual(
            AlbumAnimatedArtworkPresentation.contentBackdropTopOpacity(isImmersive: true),
            0
        )
        XCTAssertEqual(
            AlbumAnimatedArtworkPresentation.contentBackdropStrongFadeLocation(isImmersive: true),
            0.58
        )
    }

    func testAlbumImmersiveContentBackdropCoversLoadingGap() {
        XCTAssertEqual(
            AlbumAnimatedArtworkPresentation.contentBackdropMinimumHeight(
                isImmersive: true,
                viewportHeight: 852
            ),
            852
        )
        XCTAssertEqual(
            AlbumAnimatedArtworkPresentation.contentBackdropMinimumHeight(
                isImmersive: false,
                viewportHeight: 852
            ),
            0
        )
    }

    func testAlbumAnimatedArtworkPausesBehindNowPlayingOverlay() {
        XCTAssertTrue(
            AlbumAnimatedArtworkPresentation.shouldPlayVideo(
                isEnabled: true,
                isBackgroundPlaybackSuspended: false
            )
        )
        XCTAssertFalse(
            AlbumAnimatedArtworkPresentation.shouldPlayVideo(
                isEnabled: true,
                isBackgroundPlaybackSuspended: true
            )
        )
        XCTAssertFalse(
            AlbumAnimatedArtworkPresentation.shouldPlayVideo(
                isEnabled: false,
                isBackgroundPlaybackSuspended: false
            )
        )
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

    func testExpandableDescriptionMoreOverlayReservesTrailingLastLineSpace() {
        XCTAssertEqual(
            ExpandableDescriptionPolicy.moreOverlayReservedWidth(labelWidth: 38),
            84
        )
        XCTAssertEqual(
            ExpandableDescriptionPolicy.inlineMoreReservedWidth(labelWidth: 38),
            84
        )
    }

    func testExpandableDescriptionMoreOverlayDoesNotMaskCollapsedTextLayer() {
        XCTAssertFalse(ExpandableDescriptionPolicy.usesCollapsedTextLayerMask)
    }

    func testExpandableDescriptionUsesTwoCollapsedLinesForAppleMusicStyle() {
        XCTAssertEqual(ExpandableDescriptionPolicy.appleMusicCollapsedLineLimit, 2)
    }

    func testExpandableDescriptionTruncatorAppendsInlineMoreForLongText() {
        let text = """
        For those who grew up during the streaming era, it may be impossible to grasp just how monumental the announcement of this album seemed at the time.
        """
        let result = ExpandableDescriptionTruncator.collapsedText(
            from: text,
            font: .systemFont(ofSize: 15),
            textColor: .secondaryLabel,
            moreColor: .label,
            width: 230,
            lineLimit: 2
        )

        XCTAssertTrue(result.isTruncated)
        XCTAssertTrue(result.attributedText.string.hasSuffix(" MORE"))
        XCTAssertLessThan(result.attributedText.string.count, text.count)
    }

    func testExpandableDescriptionTruncatorLeavesShortTextUnchanged() {
        let text = "A concise editorial note."
        let result = ExpandableDescriptionTruncator.collapsedText(
            from: text,
            font: .systemFont(ofSize: 15),
            textColor: .secondaryLabel,
            moreColor: .label,
            width: 230,
            lineLimit: 2
        )

        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.attributedText.string, text)
    }

    func testExpandableDescriptionTruncatorFadesTextBeforeInlineMore() {
        let text = """
        For those who grew up during the streaming era, it may be impossible to grasp just how monumental the announcement of this album seemed at the time.
        """
        let result = ExpandableDescriptionTruncator.collapsedText(
            from: text,
            font: .systemFont(ofSize: 15),
            textColor: UIColor(white: 1, alpha: 0.68),
            moreColor: UIColor(white: 1, alpha: 1),
            width: 230,
            lineLimit: 2
        )
        let moreRange = (result.attributedText.string as NSString)
            .range(of: " \(ExpandableDescriptionPolicy.moreLabel)")

        XCTAssertTrue(result.isTruncated)
        XCTAssertNotEqual(moreRange.location, NSNotFound)

        let firstFadedCharacter = max(0, moreRange.location - 5)
        let lastFadedCharacter = moreRange.location - 1
        let firstAlpha = foregroundAlpha(in: result.attributedText, at: firstFadedCharacter)
        let lastAlpha = foregroundAlpha(in: result.attributedText, at: lastFadedCharacter)

        XCTAssertGreaterThan(firstAlpha, lastAlpha)
        XCTAssertLessThan(lastAlpha, 0.34)
    }

    func testExpandableDescriptionTruncatorKeepsInlineMoreOpaque() {
        let text = """
        For those who grew up during the streaming era, it may be impossible to grasp just how monumental the announcement of this album seemed at the time.
        """
        let result = ExpandableDescriptionTruncator.collapsedText(
            from: text,
            font: .systemFont(ofSize: 15),
            textColor: UIColor(white: 1, alpha: 0.68),
            moreColor: UIColor(white: 1, alpha: 1),
            width: 230,
            lineLimit: 2
        )
        let moreRange = (result.attributedText.string as NSString)
            .range(of: " \(ExpandableDescriptionPolicy.moreLabel)")

        XCTAssertTrue(result.isTruncated)
        XCTAssertNotEqual(moreRange.location, NSNotFound)
        XCTAssertEqual(foregroundAlpha(in: result.attributedText, at: moreRange.location + 1), 1, accuracy: 0.001)
    }

    func testExpandableDescriptionStripsSimpleItalicMarkupForPlainText() {
        XCTAssertEqual(
            ExpandableDescriptionTextFormatter.plainText(
                from: "The 2023's <i>NEVER ENOUGH</i> and <em>Son of Spergy</em> era"
            ),
            "The 2023's NEVER ENOUGH and Son of Spergy era"
        )
    }

    func testExpandableDescriptionStripsCommonHTMLMarkupForPlainText() {
        XCTAssertEqual(
            ExpandableDescriptionTextFormatter.plainText(
                from: "<p><b>100 Best Albums</b> &amp; <strong>Essentials</strong></p><p>Line<br/>Next&nbsp;Part</p>"
            ),
            "100 Best Albums & Essentials\n\nLine\nNext Part"
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

    func testExpandableDescriptionTruncatorAppliesBoldMarkup() {
        let result = ExpandableDescriptionTruncator.collapsedText(
            from: "A <b>bold</b> and <strong>strong</strong> note",
            font: .systemFont(ofSize: 15),
            textColor: .secondaryLabel,
            moreColor: .label,
            width: 0,
            lineLimit: 2
        )
        let boldRange = (result.attributedText.string as NSString).range(of: "bold")
        let strongRange = (result.attributedText.string as NSString).range(of: "strong")

        XCTAssertEqual(result.attributedText.string, "A bold and strong note")
        XCTAssertTrue(isBoldFont(in: result.attributedText, at: boldRange.location))
        XCTAssertTrue(isBoldFont(in: result.attributedText, at: strongRange.location))
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

    private func foregroundAlpha(in attributedText: NSAttributedString, at location: Int) -> CGFloat {
        guard location >= 0, location < attributedText.length,
              let color = attributedText.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor else {
            return -1
        }
        return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor.alpha
    }

    private func isBoldFont(in attributedText: NSAttributedString, at location: Int) -> Bool {
        guard location >= 0, location < attributedText.length,
              let font = attributedText.attribute(.font, at: location, effectiveRange: nil) as? UIFont else {
            return false
        }
        return font.fontDescriptor.symbolicTraits.contains(.traitBold)
    }
}
