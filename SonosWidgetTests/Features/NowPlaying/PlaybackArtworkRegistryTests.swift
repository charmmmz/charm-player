import XCTest
@testable import SonosWidget

@MainActor
final class PlaybackArtworkRegistryTests: XCTestCase {
    func testReplacesQueueGetaaWithBrowsePublicCDNByObjectID() {
        let registry = PlaybackArtworkRegistry()
        registry.register(
            BrowseItem(
                id: "song:1440857781",
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian",
                albumArtURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg",
                uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
                isContainer: false,
                cloudType: "TRACK"
            )
        )
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1&u=x-sonos-http%3asong%253a1440857781.mp4%3fsid%3d204%26sn%3d2",
            uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )

        let resolved = registry.resolvedQueueItem(queueItem)

        XCTAssertEqual(
            resolved.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/240x240bb.jpg"
        )
    }

    func testAppleMusicArtworkSizeVariantsDoNotMakeRegistryEntryAmbiguous() {
        let registry = PlaybackArtworkRegistry()
        registry.register(
            BrowseItem(
                id: "song:1440857781",
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian",
                albumArtURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg",
                uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
                isContainer: false,
                cloudType: "TRACK"
            )
        )
        registry.register(
            BrowseItem(
                id: "song:1440857781",
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian",
                albumArtURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/1200x1200bb.jpg",
                uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
                isContainer: false,
                cloudType: "TRACK"
            )
        )
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1&u=x-sonos-http%3asong%253a1440857781.mp4%3fsid%3d204%26sn%3d2",
            uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )

        let resolved = registry.resolvedQueueItem(queueItem)

        XCTAssertEqual(
            resolved.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/240x240bb.jpg"
        )
    }

    func testKeepsQueueGetaaWhenBrowseArtworkIsAmbiguousForSameTrackKey() {
        let registry = PlaybackArtworkRegistry()
        registry.register(
            BrowseItem(
                id: "song:1",
                title: "Intro",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://cdn.example.com/a.jpg",
                isContainer: false,
                cloudType: "TRACK"
            )
        )
        registry.register(
            BrowseItem(
                id: "song:2",
                title: "Intro",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://cdn.example.com/b.jpg",
                isContainer: false,
                cloudType: "TRACK"
            )
        )
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Intro",
            artist: "Artist",
            album: "Album",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            uri: nil,
            metaXML: nil
        )

        let resolved = registry.resolvedQueueItem(queueItem)

        XCTAssertEqual(resolved.albumArtURL, "http://192.168.50.249:1400/getaa?s=1")
    }
}
