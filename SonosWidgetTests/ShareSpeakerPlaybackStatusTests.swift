import XCTest
@testable import SonosWidget

final class ShareSpeakerPlaybackStatusTests: XCTestCase {
    func testPlaybackVisualIndicatorReplacesLoadingWithSuccessSymbol() {
        XCTAssertFalse(SharePlaybackVisualIndicator.speakerSelection.showsSpinner)
        XCTAssertFalse(SharePlaybackVisualIndicator.speakerSelection.showsWaveform)
        XCTAssertEqual(SharePlaybackVisualIndicator.speakerSelection.systemImageName, "hifispeaker.2.fill")

        XCTAssertTrue(SharePlaybackVisualIndicator.loading.showsSpinner)
        XCTAssertNil(SharePlaybackVisualIndicator.loading.systemImageName)
        XCTAssertFalse(SharePlaybackVisualIndicator.loading.showsWaveform)

        XCTAssertFalse(SharePlaybackVisualIndicator.playingWaveform.showsSpinner)
        XCTAssertTrue(SharePlaybackVisualIndicator.playingWaveform.showsWaveform)
        XCTAssertTrue(SharePlaybackVisualIndicator.playingWaveform.animatesWaveform)
        XCTAssertNil(SharePlaybackVisualIndicator.playingWaveform.systemImageName)

        XCTAssertFalse(SharePlaybackVisualIndicator.restingWaveform.showsSpinner)
        XCTAssertTrue(SharePlaybackVisualIndicator.restingWaveform.showsWaveform)
        XCTAssertFalse(SharePlaybackVisualIndicator.restingWaveform.animatesWaveform)
        XCTAssertNil(SharePlaybackVisualIndicator.restingWaveform.systemImageName)

        XCTAssertFalse(SharePlaybackVisualIndicator.success.showsSpinner)
        XCTAssertEqual(SharePlaybackVisualIndicator.success.systemImageName, "checkmark.circle.fill")
    }

    func testStatusIndicatorLayoutUsesStableSlotForSpinnerCheckAndEmptyStates() {
        XCTAssertEqual(ShareStatusIndicatorLayout.indicatorSlotSize.width, 24)
        XCTAssertEqual(ShareStatusIndicatorLayout.indicatorSlotSize.height, 24)
        XCTAssertEqual(ShareStatusIndicatorLayout.rowMinimumHeight, 28)
    }

    func testPlaybackWaveformLayoutUsesSubtleCompactMetrics() {
        XCTAssertEqual(SharePlaybackWaveformLayout.size.width, 24)
        XCTAssertEqual(SharePlaybackWaveformLayout.size.height, 24)
        XCTAssertEqual(SharePlaybackWaveformLayout.barWidth, 2)
        XCTAssertEqual(SharePlaybackWaveformLayout.barSpacing, 2)
        XCTAssertLessThanOrEqual(SharePlaybackWaveformLayout.activeHeights.max() ?? 0, 20)
    }

    func testShareSpeakerListExpandsToFitEverySpeakerCard() {
        XCTAssertEqual(ShareSpeakerListLayout.cardHeight, 82)
        XCTAssertEqual(ShareSpeakerListLayout.cardSpacing, 10)
        XCTAssertEqual(
            ShareSpeakerListLayout.listHeight(for: 4),
            ShareSpeakerListLayout.cardHeight * 4 + ShareSpeakerListLayout.cardSpacing * 3
        )
        XCTAssertEqual(
            ShareSpeakerListLayout.listHeight(for: 5),
            ShareSpeakerListLayout.cardHeight * 5 + ShareSpeakerListLayout.cardSpacing * 4
        )
        XCTAssertGreaterThan(
            ShareSpeakerListLayout.preferredContentHeight(for: 5),
            ShareSpeakerListLayout.preferredContentHeight(for: 4)
        )
    }

    func testArtworkLoadPolicyAllowsSlowerSonosArtworkWithRetry() {
        XCTAssertEqual(ShareSpeakerArtworkLoadPolicy.requestTimeoutMilliseconds, 2_500)
        XCTAssertEqual(ShareSpeakerArtworkLoadPolicy.maxAttempts, 2)
    }

    func testMapsSonosTransportStatesToShareLabels() {
        XCTAssertEqual(ShareSpeakerPlaybackStatus(sonosTransportState: "PLAYING")?.displayText, "Playing")
        XCTAssertEqual(ShareSpeakerPlaybackStatus(sonosTransportState: "PAUSED_PLAYBACK")?.displayText, "Paused")
        XCTAssertEqual(ShareSpeakerPlaybackStatus(sonosTransportState: "STOPPED")?.displayText, "Idle")
        XCTAssertEqual(ShareSpeakerPlaybackStatus(sonosTransportState: "NO_MEDIA_PRESENT")?.displayText, "Idle")
    }

    func testUnknownTransportStatesDoNotClaimAStatus() {
        XCTAssertNil(ShareSpeakerPlaybackStatus(sonosTransportState: "TRANSITIONING"))
        XCTAssertNil(ShareSpeakerPlaybackStatus(sonosTransportState: "SOMETHING_NEW"))
        XCTAssertNil(ShareSpeakerPlaybackStatus(sonosTransportState: ""))
    }

    func testFallbackDetailTextAvoidsFakeReadyStatus() {
        XCTAssertEqual(ShareSpeakerPlaybackStatus.fallbackDetailText(visibleMemberCount: 1), "Tap to play")
        XCTAssertEqual(ShareSpeakerPlaybackStatus.fallbackDetailText(visibleMemberCount: 2), "2 speakers")
    }

    func testNowPlayingParsesEscapedSonosMetadata() {
        let xml = """
        <u:GetPositionInfoResponse>
        <TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;Assassin&lt;/dc:title&gt;&lt;dc:creator&gt;John Mayer&lt;/dc:creator&gt;&lt;upnp:albumArtURI&gt;https://example.com/cover.jpg&lt;/upnp:albumArtURI&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
        </u:GetPositionInfoResponse>
        """

        let nowPlaying = ShareSpeakerNowPlaying(positionInfoXML: xml)

        XCTAssertEqual(nowPlaying?.displayText, "Assassin - John Mayer")
        XCTAssertEqual(nowPlaying?.albumArtURLString, "https://example.com/cover.jpg")
    }

    func testNowPlayingParsesEqualsDelimitedRadioStreamContent() {
        let xml = """
        <u:GetPositionInfoResponse>
        <TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;Apple Music Chill&lt;/dc:title&gt;&lt;dc:creator&gt;Unknown&lt;/dc:creator&gt;&lt;r:streamContent&gt;TYPE=SNG|TITLE=Free|ARTIST=Ryan Ellis|ALBUM=Real Love&lt;/r:streamContent&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
        </u:GetPositionInfoResponse>
        """

        let nowPlaying = ShareSpeakerNowPlaying(positionInfoXML: xml)

        XCTAssertEqual(nowPlaying?.displayText, "Free - Ryan Ellis")
    }

    func testNowPlayingResolvesRelativeAlbumArtAgainstSpeakerIP() {
        let xml = """
        <u:GetPositionInfoResponse>
        <TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;Move&lt;/dc:title&gt;&lt;upnp:artist&gt;Drake&lt;/upnp:artist&gt;&lt;upnp:albumArtURI&gt;/getaa?u=x-sonos-http%3atrack%253a123&amp;amp;v=1&lt;/upnp:albumArtURI&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
        </u:GetPositionInfoResponse>
        """

        let nowPlaying = ShareSpeakerNowPlaying(
            positionInfoXML: xml,
            speakerIP: "192.168.1.24"
        )

        XCTAssertEqual(
            nowPlaying?.albumArtURLString,
            "http://192.168.1.24:1400/getaa?u=x-sonos-http:track%3a123&v=1"
        )
    }

    func testNowPlayingDropsEmptyUnknownMetadata() {
        let xml = """
        <u:GetPositionInfoResponse>
        <TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;Unknown&lt;/dc:title&gt;&lt;dc:creator&gt;Unknown&lt;/dc:creator&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
        </u:GetPositionInfoResponse>
        """

        XCTAssertNil(ShareSpeakerNowPlaying(positionInfoXML: xml))
        XCTAssertNil(ShareSpeakerNowPlaying(title: "  ", artist: "John Mayer"))
    }

    func testNowPlayingFallsBackToTVAudioFromTrackURI() {
        let xml = """
        <u:GetPositionInfoResponse>
        <TrackURI>x-sonos-htastream:RINCON_ABC:spdif</TrackURI>
        <TrackMetaData>NOT_IMPLEMENTED</TrackMetaData>
        </u:GetPositionInfoResponse>
        """

        let nowPlaying = ShareSpeakerNowPlaying(positionInfoXML: xml)

        XCTAssertEqual(nowPlaying?.displayText, "TV Audio - HDMI")
    }

    func testNowPlayingFallsBackToLineInFromTrackURI() {
        let xml = """
        <u:GetPositionInfoResponse>
        <TrackURI>x-rincon-stream:RINCON_ABC01400</TrackURI>
        <TrackMetaData>NOT_IMPLEMENTED</TrackMetaData>
        </u:GetPositionInfoResponse>
        """

        let nowPlaying = ShareSpeakerNowPlaying(positionInfoXML: xml)

        XCTAssertEqual(nowPlaying?.displayText, "Line-In")
    }

    func testDetailTextPrefersUsefulNowPlayingForActiveSpeakers() {
        let nowPlaying = ShareSpeakerNowPlaying(title: "Assassin", artist: "John Mayer")

        XCTAssertEqual(
            ShareSpeakerPlaybackStatus.detailText(
                status: .playing,
                nowPlaying: nowPlaying,
                visibleMemberCount: 1
            ),
            "Assassin - John Mayer"
        )
        XCTAssertEqual(
            ShareSpeakerPlaybackStatus.detailText(
                status: .paused,
                nowPlaying: nowPlaying,
                visibleMemberCount: 1
            ),
            "Assassin - John Mayer"
        )
        XCTAssertEqual(
            ShareSpeakerPlaybackStatus.detailText(
                status: .paused,
                nowPlaying: nil,
                visibleMemberCount: 1
            ),
            "Paused"
        )
        XCTAssertEqual(
            ShareSpeakerPlaybackStatus.detailText(
                status: .idle,
                nowPlaying: nowPlaying,
                visibleMemberCount: 1
            ),
            "Idle"
        )
    }
}
