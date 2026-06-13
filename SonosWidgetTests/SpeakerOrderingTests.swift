import XCTest
@testable import SonosWidget

final class SpeakerOrderingTests: XCTestCase {
    override func tearDown() {
        SharedStorage.homeSpeakerGroupOrder = []
        super.tearDown()
    }

    func testCustomOrderIsAppliedAheadOfAlphabeticalFallback() {
        let statuses = [
            makeStatus(id: "kitchen", name: "Kitchen"),
            makeStatus(id: "living", name: "Living Room"),
            makeStatus(id: "bedroom", name: "Bedroom")
        ]

        let sorted = SonosManager.sortedSpeakerGroups(
            statuses,
            preferredOrder: ["living", "missing", "bedroom"]
        )

        XCTAssertEqual(sorted.map(\.id), ["living", "bedroom", "kitchen"])
    }

    func testMovingSpeakerGroupPersistsNewOrderAndReordersCurrentStatuses() {
        let manager = SonosManager()
        manager.groupStatuses = [
            makeStatus(id: "kitchen", name: "Kitchen"),
            makeStatus(id: "living", name: "Living Room"),
            makeStatus(id: "bedroom", name: "Bedroom")
        ]

        manager.moveSpeakerGroup(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(manager.groupStatuses.map(\.id), ["bedroom", "kitchen", "living"])
        XCTAssertEqual(SharedStorage.homeSpeakerGroupOrder, ["bedroom", "kitchen", "living"])
    }

    func testDropIntentUsesEdgesForReorderAndCenterForGrouping() {
        XCTAssertEqual(
            SonosManager.speakerGroupDropIntent(locationY: 8, targetHeight: 100),
            .reorderBefore
        )
        XCTAssertEqual(
            SonosManager.speakerGroupDropIntent(locationY: 50, targetHeight: 100),
            .merge
        )
        XCTAssertEqual(
            SonosManager.speakerGroupDropIntent(locationY: 92, targetHeight: 100),
            .reorderAfter
        )
    }

    func testReorderingRelativeToTargetPersistsNewOrder() {
        let manager = SonosManager()
        manager.groupStatuses = [
            makeStatus(id: "kitchen", name: "Kitchen"),
            makeStatus(id: "living", name: "Living Room"),
            makeStatus(id: "bedroom", name: "Bedroom")
        ]

        manager.reorderSpeakerGroup(
            sourceID: "bedroom",
            relativeTo: "kitchen",
            placement: .before
        )

        XCTAssertEqual(manager.groupStatuses.map(\.id), ["bedroom", "kitchen", "living"])
        XCTAssertEqual(SharedStorage.homeSpeakerGroupOrder, ["bedroom", "kitchen", "living"])
    }

    func testCurrentGroupStatusSyncsFromNowPlayingState() {
        let manager = SonosManager()
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "playroom-group")
        let move = makePlayer(id: "move", name: "Move", groupId: "move-group")

        manager.selectedSpeaker = playroom
        manager.trackInfo = TrackInfo(
            title: "Extraordinary Girl",
            artist: "Green Day",
            album: "American Idiot",
            albumArtURL: "https://example.com/new.jpg"
        )
        manager.transportState = .playing
        manager.volume = 4
        manager.groupStatuses = [
            makeStatus(
                player: move,
                trackInfo: TrackInfo(title: "Idle", artist: "", album: ""),
                transportState: .stopped,
                volume: 14
            ),
            makeStatus(
                player: playroom,
                trackInfo: TrackInfo(
                    title: "Give Me Novacaine",
                    artist: "Green Day",
                    album: "American Idiot",
                    albumArtURL: "https://example.com/old.jpg"
                ),
                transportState: .paused,
                volume: 2
            )
        ]

        manager.syncCurrentGroupStatusFromPlaybackState()

        XCTAssertEqual(manager.groupStatuses[0].trackInfo?.title, "Idle")
        XCTAssertEqual(manager.groupStatuses[0].transportState, .stopped)
        XCTAssertEqual(manager.groupStatuses[0].volume, 14)
        XCTAssertEqual(manager.groupStatuses[1].trackInfo?.title, "Extraordinary Girl")
        XCTAssertEqual(manager.groupStatuses[1].trackInfo?.albumArtURL, "https://example.com/new.jpg")
        XCTAssertEqual(manager.groupStatuses[1].transportState, .playing)
        XCTAssertEqual(manager.groupStatuses[1].volume, 4)
    }

    private func makePlayer(id: String, name: String, groupId: String? = nil) -> SonosPlayer {
        SonosPlayer(
            id: id,
            name: name,
            ipAddress: "192.168.1.\(abs(id.hashValue % 200) + 20)",
            isCoordinator: true,
            groupId: groupId ?? id
        )
    }

    private func makeStatus(id: String, name: String) -> SpeakerGroupStatus {
        makeStatus(player: makePlayer(id: id, name: name))
    }

    private func makeStatus(
        player: SonosPlayer,
        trackInfo: TrackInfo? = nil,
        transportState: TransportState = .stopped,
        volume: Int = 0
    ) -> SpeakerGroupStatus {
        return SpeakerGroupStatus(
            id: player.groupId ?? player.id,
            coordinator: player,
            members: [player],
            trackInfo: trackInfo,
            transportState: transportState,
            volume: volume
        )
    }
}
