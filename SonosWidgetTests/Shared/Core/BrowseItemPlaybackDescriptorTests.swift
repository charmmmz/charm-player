import XCTest
@testable import SonosWidget

final class BrowseItemPlaybackDescriptorTests: XCTestCase {
    func testPlaybackDescriptorTreatsNonEmptyURIAsQueueable() {
        let item = BrowseItem(
            id: "playlist:pl.new",
            title: "New Music",
            artist: "Apple Music",
            album: "",
            uri: "x-rincon-cpcontainer:1006206c playlist%3Apl.new?sid=204&sn=2",
            isContainer: true,
            serviceId: 204,
            cloudType: "PLAYLIST"
        )

        XCTAssertTrue(item.playbackDescriptor.isPlayable)
        XCTAssertTrue(item.playbackDescriptor.isQueueable)
        XCTAssertTrue(item.playbackDescriptor.hasActionSurface)
        XCTAssertEqual(item.playbackDescriptor.uri, item.uri)
    }

    func testPlaybackDescriptorBuildsQueuePayloadFromDirectURI() {
        let item = BrowseItem(
            id: "song:1440857781",
            title: "A Song",
            artist: "Artist",
            album: "Album",
            uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK"
        )

        let payload = item.playbackDescriptor.queuePayload(metadata: "<DIDL-Lite />")

        XCTAssertEqual(
            payload,
            SonosQueuedURI(
                uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
                metadata: "<DIDL-Lite />"
            )
        )
    }

    func testPlaybackDescriptorBuildsTransportPayloadFromFallbackURIWithoutQueueableURI() {
        let item = BrowseItem(
            id: "FV:2/51",
            title: "After Hours",
            artist: "",
            album: "",
            uri: nil,
            resMD: "<DIDL-Lite><item id=\"album:123\"></item></DIDL-Lite>",
            isContainer: true,
            cloudType: "ALBUM"
        )

        let payload = item.playbackDescriptor.transportPayload(
            metadata: "<DIDL-Lite />",
            fallbackURI: " x-rincon-cpcontainer:1004206c%20album%3A123?sid=204&flags=8300&sn=2 "
        )

        XCTAssertFalse(item.playbackDescriptor.isQueueable)
        XCTAssertEqual(
            payload,
            SonosQueuedURI(
                uri: "x-rincon-cpcontainer:1004206c%20album%3A123?sid=204&flags=8300&sn=2",
                metadata: "<DIDL-Lite />"
            )
        )
    }

    func testPlaybackDescriptorTreatsWhitespaceURIAsMissing() {
        let item = BrowseItem(
            id: "song:bad",
            title: "Bad URI",
            artist: "Artist",
            album: "",
            uri: "   ",
            isContainer: false,
            cloudType: "TRACK"
        )

        XCTAssertFalse(item.playbackDescriptor.isPlayable)
        XCTAssertFalse(item.playbackDescriptor.isQueueable)
        XCTAssertFalse(item.playbackDescriptor.hasActionSurface)
        XCTAssertNil(item.playbackDescriptor.uri)
    }

    func testPlaybackDescriptorKeepsFavoriteMetadataActionSurface() {
        let item = BrowseItem(
            id: "FV:2/51",
            title: "After Hours",
            artist: "",
            album: "",
            uri: nil,
            resMD: "<DIDL-Lite><item id=\"album:123\"></item></DIDL-Lite>",
            isContainer: true,
            cloudType: "ALBUM"
        )

        XCTAssertFalse(item.playbackDescriptor.isPlayable)
        XCTAssertFalse(item.playbackDescriptor.isQueueable)
        XCTAssertTrue(item.playbackDescriptor.hasActionSurface)
        XCTAssertEqual(item.playbackDescriptor.resourceMetadata, item.resMD)
    }
}
