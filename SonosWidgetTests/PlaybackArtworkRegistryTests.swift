import XCTest
@testable import SonosWidget

final class PlaybackArtworkRegistryTests: XCTestCase {
    func testResolvesQueueSpeakerArtworkFromRegisteredTrackMetadata() {
        var registry = PlaybackArtworkRegistry()
        registry.register(items: [
            BrowseItem(
                id: "song:123",
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian",
                albumArtURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/400x400bb.jpg",
                isContainer: false,
                cloudType: "TRACK"
            )
        ])
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: " moon ",
            artist: "DANIEL CAESAR",
            album: "Freudian",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1&u=x-sonos-http:librarytrack%3ai.abc.mp4?sid=204&flags=8232&sn=2",
            uri: "x-sonos-http:librarytrack%3ai.abc.mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )

        let resolved = registry.resolvedQueueItem(queueItem)

        XCTAssertEqual(
            resolved.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/400x400bb.jpg"
        )
    }

    func testKeepsExistingPublicQueueArtwork() {
        var registry = PlaybackArtworkRegistry()
        registry.register(items: [
            BrowseItem(
                id: "song:123",
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian",
                albumArtURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/400x400bb.jpg",
                isContainer: false,
                cloudType: "TRACK"
            )
        ])
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "https://cdn.example.com/current.jpg",
            uri: nil,
            metaXML: nil
        )

        let resolved = registry.resolvedQueueItem(queueItem)

        XCTAssertEqual(resolved.albumArtURL, "https://cdn.example.com/current.jpg")
    }

    func testResolvesMusicKitArtworkURLBeforeRegistering() {
        var registry = PlaybackArtworkRegistry()
        registry.register(items: [
            BrowseItem(
                id: "song:123",
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian",
                albumArtURL: "musicKit://artwork/library/ABC/600x600?aat=https%3A%2F%2Fis1-ssl.mzstatic.com%2Fimage%2Fthumb%2FFeatures125%2Fv4%2Fcover%2F600x600bb.jpg&at=playlist&et=collection",
                isContainer: false,
                cloudType: "TRACK"
            )
        ])
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            uri: nil,
            metaXML: nil
        )

        let resolved = registry.resolvedQueueItem(queueItem)

        XCTAssertEqual(
            resolved.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Features125/v4/cover/600x600bb.jpg"
        )
    }

    func testConflictingTrackKeyDoesNotReplaceQueueArtwork() {
        var registry = PlaybackArtworkRegistry()
        registry.register(items: [
            BrowseItem(
                id: "song:1",
                title: "Intro",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://cdn.example.com/a.jpg",
                isContainer: false,
                cloudType: "TRACK"
            ),
            BrowseItem(
                id: "song:2",
                title: "Intro",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://cdn.example.com/b.jpg",
                isContainer: false,
                cloudType: "TRACK"
            )
        ])
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

    func testObjectIDKeyWinsOverTextKey() {
        var registry = PlaybackArtworkRegistry()
        registry.register(items: [
            BrowseItem(
                id: "song:123",
                title: "Song",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://cdn.example.com/id.jpg",
                uri: "x-sonos-http:song%3a123.mp4?sid=204&flags=8232&sn=2",
                isContainer: false,
                cloudType: "TRACK"
            ),
            BrowseItem(
                id: "song:999",
                title: "Song",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://cdn.example.com/text.jpg",
                isContainer: false,
                cloudType: "TRACK"
            )
        ])
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            uri: "x-sonos-http:song%3a123.mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )

        let resolved = registry.resolvedQueueItem(queueItem)

        XCTAssertEqual(resolved.albumArtURL, "https://cdn.example.com/id.jpg")
    }
}
