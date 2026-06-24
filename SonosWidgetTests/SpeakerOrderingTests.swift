import XCTest
import UIKit
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

    func testHomeSpeakerRefreshKeepsExistingCardsWhenIncomingRefreshIsEmpty() {
        let existing = [
            makeStatus(id: "living", name: "Living Room")
        ]

        let next = SonosManager.homeSpeakerStatusesAfterRefresh(
            existing: existing,
            incoming: [],
            preferredOrder: []
        )

        XCTAssertEqual(next.map(\.id), ["living"])
    }

    func testHomeSpeakerCardsBlockingLoaderOnlyShowsBeforeFirstLoad() {
        XCTAssertTrue(
            HomeSpeakerCardsRefreshPolicy.showsBlockingLoader(
                hasLoadedCards: false,
                groupStatusesIsEmpty: true
            )
        )
        XCTAssertFalse(
            HomeSpeakerCardsRefreshPolicy.showsBlockingLoader(
                hasLoadedCards: true,
                groupStatusesIsEmpty: true
            )
        )
        XCTAssertFalse(
            HomeSpeakerCardsRefreshPolicy.showsBlockingLoader(
                hasLoadedCards: false,
                groupStatusesIsEmpty: false
            )
        )
    }

    func testHomeSpeakerCardsRefreshOnAppearUsesSilentRefreshCadence() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            HomeSpeakerCardsRefreshPolicy.shouldRefreshOnAppear(
                lastRefreshAt: nil,
                isRefreshing: false,
                now: now,
                minimumInterval: 2
            )
        )
        XCTAssertFalse(
            HomeSpeakerCardsRefreshPolicy.shouldRefreshOnAppear(
                lastRefreshAt: now.addingTimeInterval(-10),
                isRefreshing: true,
                now: now,
                minimumInterval: 2
            )
        )
        XCTAssertFalse(
            HomeSpeakerCardsRefreshPolicy.shouldRefreshOnAppear(
                lastRefreshAt: now.addingTimeInterval(-1),
                isRefreshing: false,
                now: now,
                minimumInterval: 2
            )
        )
        XCTAssertTrue(
            HomeSpeakerCardsRefreshPolicy.shouldRefreshOnAppear(
                lastRefreshAt: now.addingTimeInterval(-3),
                isRefreshing: false,
                now: now,
                minimumInterval: 2
            )
        )
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

    func testSettingCurrentTransportStateImmediatelyUpdatesCurrentGroupStatus() {
        let manager = SonosManager()
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "playroom-group")
        let move = makePlayer(id: "move", name: "Move", groupId: "move-group")

        manager.selectedSpeaker = playroom
        manager.trackInfo = TrackInfo(title: "Extraordinary Girl", artist: "Green Day", album: "American Idiot")
        manager.volume = 4
        manager.groupStatuses = [
            makeStatus(player: move, transportState: .playing, volume: 14),
            makeStatus(player: playroom, transportState: .paused, volume: 2)
        ]

        manager.setCurrentTransportState(.playing)

        XCTAssertEqual(manager.transportState, .playing)
        XCTAssertEqual(manager.groupStatuses[0].transportState, .playing)
        XCTAssertEqual(manager.groupStatuses[0].volume, 14)
        XCTAssertEqual(manager.groupStatuses[1].transportState, .playing)
        XCTAssertEqual(manager.groupStatuses[1].trackInfo?.title, "Extraordinary Girl")
        XCTAssertEqual(manager.groupStatuses[1].volume, 4)
    }

    func testSettingCurrentGroupTransportStateImmediatelyUpdatesNowPlayingState() {
        let manager = SonosManager()
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "playroom-group")
        let move = makePlayer(id: "move", name: "Move", groupId: "move-group")

        manager.selectedSpeaker = playroom
        manager.transportState = .paused
        manager.groupStatuses = [
            makeStatus(player: move, transportState: .playing, volume: 14),
            makeStatus(player: playroom, transportState: .paused, volume: 2)
        ]

        manager.setGroupTransportState(.playing, forGroupID: "playroom-group")

        XCTAssertEqual(manager.transportState, .playing)
        XCTAssertEqual(manager.groupStatuses[0].transportState, .playing)
        XCTAssertEqual(manager.groupStatuses[1].transportState, .playing)
    }

    func testSpeakerSelectionArtworkRestoreUsesMatchingGroupImage() {
        let image = makeImage(color: .systemYellow)
        let track = TrackInfo(
            title: "Details In the Fabric",
            artist: "Jason Mraz",
            album: "We Sing. We Dance. We Steal Things.",
            albumArtURL: "https://example.com/details.jpg"
        )

        let restored = SonosManager.cachedArtworkForSpeakerSelection(
            groupID: "home-theater",
            trackInfo: track,
            groupImages: ["home-theater": image],
            groupLastArtURL: ["home-theater": "https://example.com/details.jpg"],
            imageForURL: { _ in nil }
        )

        XCTAssertEqual(restored?.urlString, "https://example.com/details.jpg")
        XCTAssertTrue(restored?.image === image)
    }

    func testSpeakerSelectionArtworkRestoreFallsBackToURLCacheWhenGroupImageIsStale() {
        let staleImage = makeImage(color: .systemGray)
        let cachedImage = makeImage(color: .systemGreen)
        let track = TrackInfo(
            title: "別殺我",
            artist: "Crowd Lu",
            album: "一百種生活",
            albumArtURL: "https://example.com/current.jpg"
        )

        let restored = SonosManager.cachedArtworkForSpeakerSelection(
            groupID: "playroom",
            trackInfo: track,
            groupImages: ["playroom": staleImage],
            groupLastArtURL: ["playroom": "https://example.com/old.jpg"],
            imageForURL: { urlString in
                urlString == "https://example.com/current.jpg" ? cachedImage : nil
            }
        )

        XCTAssertEqual(restored?.urlString, "https://example.com/current.jpg")
        XCTAssertTrue(restored?.image === cachedImage)
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

    private func makeImage(color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }
}
