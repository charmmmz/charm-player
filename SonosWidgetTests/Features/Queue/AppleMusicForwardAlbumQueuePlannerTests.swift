import XCTest
@testable import SonosWidget

final class AppleMusicForwardAlbumQueuePlannerTests: XCTestCase {
    func testPlanKeepsWholeAlbumOrderAndTargetsMatchedTrackNumber() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Before"),
            makeCandidate(id: "track-2", title: "Current"),
            makeCandidate(id: "track-3", title: "After")
        ]
        let source = makeSourceTrack(title: "Current")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: albumTracks[1].item,
            sourceTrack: source)

        XCTAssertEqual(plan?.items.map(\.title), ["Before", "Current", "After"])
        XCTAssertEqual(plan?.targetTrackNumber, 2)
        XCTAssertEqual(plan?.transferredTrackCount, 3)
        XCTAssertEqual(plan?.skippedUnsupportedItemCount, 0)
    }

    func testPlanMatchesTargetByStoreIDWhenObjectIDsDiffer() {
        let albumTracks = [
            makeCandidate(id: "album-1", title: "Before", storeID: "111"),
            makeCandidate(id: "album-2", title: "Current", storeID: "222"),
            makeCandidate(id: "album-3", title: "After", storeID: "333")
        ]
        let matched = makeItem(id: "search-result", title: "Current", storeID: "222")
        let source = makeSourceTrack(title: "Current")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: matched,
            sourceTrack: source)

        XCTAssertEqual(plan?.targetTrackNumber, 2)
        XCTAssertEqual(plan?.items.map(\.id), ["album-1", "album-2", "album-3"])
    }

    func testPlanFallsBackToUniqueMetadataMatch() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Intro", duration: 60),
            makeCandidate(id: "track-2", title: "Current", duration: 181),
            makeCandidate(id: "track-3", title: "Outro", duration: 200)
        ]
        let matched = makeItem(id: "search-result", title: "Current", storeID: nil, duration: 181)
        let source = makeSourceTrack(title: "Current", duration: 180)

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: matched,
            sourceTrack: source)

        XCTAssertEqual(plan?.targetTrackNumber, 2)
    }

    func testPlanRejectsAmbiguousMetadataMatch() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Interlude", duration: 90),
            makeCandidate(id: "track-2", title: "Interlude", duration: 92),
            makeCandidate(id: "track-3", title: "Outro", duration: 200)
        ]
        let matched = makeItem(id: "search-result", title: "Interlude", storeID: nil, duration: 91)
        let source = makeSourceTrack(title: "Interlude", duration: 91)

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: matched,
            sourceTrack: source)

        XCTAssertNil(plan)
    }

    func testPlanSkipsUnsupportedItemsAndAdjustsTargetTrackNumber() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Playable Before", storeID: "111"),
            makeCandidate(id: "track-2", title: "Unavailable Before", playable: false),
            makeCandidate(id: "track-3", title: "Current", storeID: "333"),
            makeCandidate(id: "track-4", title: "Unavailable After", playable: false),
            makeCandidate(id: "track-5", title: "Playable After", storeID: "555")
        ]
        let source = makeSourceTrack(title: "Current")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: albumTracks[2].item,
            sourceTrack: source)

        XCTAssertEqual(plan?.items.map(\.title), ["Playable Before", "Current", "Playable After"])
        XCTAssertEqual(plan?.targetTrackNumber, 2)
        XCTAssertEqual(plan?.skippedUnsupportedItemCount, 2)
    }

    func testPlanReturnsNilWhenMatchedTrackIsUnsupported() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Before", storeID: "111"),
            makeCandidate(id: "track-2", title: "Current", playable: false),
            makeCandidate(id: "track-3", title: "After", storeID: "333")
        ]
        let source = makeSourceTrack(title: "Current")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: albumTracks[1].item,
            sourceTrack: source)

        XCTAssertNil(plan)
    }

    func testPlanHonorsMaxItemsBeforePlanningTarget() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "One"),
            makeCandidate(id: "track-2", title: "Two"),
            makeCandidate(id: "track-3", title: "Three")
        ]
        let source = makeSourceTrack(title: "Three")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: albumTracks[2].item,
            sourceTrack: source,
            maxItems: 2)

        XCTAssertNil(plan)
    }

    func testSonosAlbumItemTrackTypeIsPlayableWhenResourceIsTrack() {
        XCTAssertTrue(
            AppleMusicForwardAlbumQueuePlanner.isSupportedAlbumTrackType(
                itemType: "TRACK",
                resourceType: nil))
        XCTAssertTrue(
            AppleMusicForwardAlbumQueuePlanner.isSupportedAlbumTrackType(
                itemType: "ITEM_TRACK",
                resourceType: "TRACK"))
        XCTAssertFalse(
            AppleMusicForwardAlbumQueuePlanner.isSupportedAlbumTrackType(
                itemType: "ITEM_TRACK",
                resourceType: "ALBUM"))
    }

    private func makeCandidate(
        id: String,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        storeID: String? = nil,
        duration: TimeInterval = 180,
        playable: Bool = true,
        ordinal: Int? = nil
    ) -> AppleMusicForwardAlbumTrackCandidate {
        AppleMusicForwardAlbumTrackCandidate(
            item: makeItem(
                id: id,
                title: title,
                artist: artist,
                album: album,
                storeID: storeID ?? id,
                duration: duration,
                playable: playable),
            ordinal: ordinal)
    }

    private func makeItem(
        id: String,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        storeID: String? = nil,
        duration: TimeInterval = 180,
        playable: Bool = true
    ) -> BrowseItem {
        let uri = playable
            ? "x-sonos-http:10032020\(storeID ?? id).mp4?sid=204&flags=8232&sn=2"
            : nil
        return BrowseItem(
            id: id,
            title: title,
            artist: artist,
            album: album,
            albumArtURL: nil,
            uri: uri,
            metaXML: nil,
            duration: duration,
            resMD: nil,
            isContainer: false,
            serviceId: playable ? 204 : nil,
            cloudType: playable ? "TRACK" : nil,
            cloudFavoriteId: nil)
    }

    private func makeSourceTrack(
        title: String,
        artist: String = "Artist",
        album: String? = "Album",
        duration: TimeInterval? = 180
    ) -> AppleMusicHandoffTrack {
        AppleMusicHandoffTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: 42,
            playbackStoreID: nil,
            persistentID: nil)
    }
}
