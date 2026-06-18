import XCTest
@testable import SonosWidget

final class QueueReorderPolicyTests: XCTestCase {
    func testReorderNormalizesTrackNumbersAndKeepsItemIdentities() {
        let queue = [
            makeItem(id: "stable-a", trackNumber: 1, title: "A", uri: "x-sonos-http:a"),
            makeItem(id: "stable-b", trackNumber: 2, title: "B", uri: "x-sonos-http:b"),
            makeItem(id: "stable-c", trackNumber: 3, title: "C", uri: "x-sonos-http:c")
        ]

        let reordered = QueueReorderPolicy.reordered(
            queue,
            from: IndexSet(integer: 0),
            to: 3
        )

        XCTAssertEqual(reordered.map(\.id), ["stable-b", "stable-c", "stable-a"])
        XCTAssertEqual(reordered.map(\.trackNumber), [1, 2, 3])
    }

    func testConfirmedRemoteQueuePreservesExistingIDsForSameTracks() {
        let local = [
            makeItem(id: "local-b", trackNumber: 1, title: "B", uri: "x-sonos-http:b"),
            makeItem(id: "local-c", trackNumber: 2, title: "C", uri: "x-sonos-http:c"),
            makeItem(id: "local-a", trackNumber: 3, title: "A", uri: "x-sonos-http:a")
        ]
        let remote = [
            makeItem(id: "0", trackNumber: 1, title: "B", uri: "x-sonos-http:b"),
            makeItem(id: "1", trackNumber: 2, title: "C", uri: "x-sonos-http:c"),
            makeItem(id: "2", trackNumber: 3, title: "A", uri: "x-sonos-http:a")
        ]

        let merged = QueueReorderPolicy.confirmedQueue(remote, preservingIDsFrom: local)

        XCTAssertEqual(merged.map(\.id), ["local-b", "local-c", "local-a"])
        XCTAssertEqual(merged.map(\.trackNumber), [1, 2, 3])
    }

    func testConfirmedRemoteQueueGivesStableIDsToNewTracks() {
        let local = [
            makeItem(id: "local-a", trackNumber: 1, title: "A", uri: "x-sonos-http:a")
        ]
        let remote = [
            makeItem(id: "0", trackNumber: 1, title: "A", uri: "x-sonos-http:a"),
            makeItem(id: "1", trackNumber: 2, title: "B", uri: "x-sonos-http:b")
        ]

        let merged = QueueReorderPolicy.confirmedQueue(remote, preservingIDsFrom: local)

        XCTAssertEqual(merged[0].id, "local-a")
        XCTAssertEqual(
            merged[1].id,
            QueueReorderPolicy.stableID(for: remote[1], occurrence: 0)
        )
    }

    func testDuplicateTracksUseOccurrenceSpecificStableIDs() {
        let first = makeItem(id: "0", trackNumber: 1, title: "A", uri: "x-sonos-http:a")
        let second = makeItem(id: "1", trackNumber: 2, title: "A", uri: "x-sonos-http:a")

        let merged = QueueReorderPolicy.confirmedQueue([first, second], preservingIDsFrom: [])

        XCTAssertNotEqual(merged[0].id, merged[1].id)
        XCTAssertEqual(merged[0].id, QueueReorderPolicy.stableID(for: first, occurrence: 0))
        XCTAssertEqual(merged[1].id, QueueReorderPolicy.stableID(for: second, occurrence: 1))
    }

    private func makeItem(
        id: String,
        trackNumber: Int,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        albumArtURL: String? = "https://example.com/art.jpg",
        uri: String?
    ) -> QueueItem {
        QueueItem(
            id: id,
            objectID: "Q:0/\(trackNumber - 1)",
            trackNumber: trackNumber,
            title: title,
            artist: artist,
            album: album,
            albumArtURL: albumArtURL,
            uri: uri,
            metaXML: nil
        )
    }
}
