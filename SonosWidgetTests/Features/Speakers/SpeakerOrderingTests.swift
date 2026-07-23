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

    func testHomeSpeakerRefreshPreservesLiveStreamWhenIncomingRefreshIsPlaceholder() {
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "playroom-group")
        let existing = [
            makeStatus(
                player: playroom,
                trackInfo: TrackInfo(
                    title: "Apple Music Chill",
                    artist: "Apple Music Radio",
                    album: "",
                    albumArtURL: "https://example.com/chill.jpg",
                    duration: "00:00:00",
                    position: "00:00:00",
                    source: .appleMusic
                ),
                transportState: .playing,
                volume: 12
            )
        ]
        let incoming = [
            makeStatus(
                player: playroom,
                trackInfo: nil,
                transportState: .stopped,
                volume: 14
            )
        ]

        let next = SonosManager.homeSpeakerStatusesAfterRefresh(
            existing: existing,
            incoming: incoming,
            preferredOrder: []
        )

        XCTAssertEqual(next.map(\.id), ["playroom-group"])
        XCTAssertEqual(next[0].trackInfo?.title, "Apple Music Chill")
        XCTAssertEqual(next[0].trackInfo?.albumArtURL, "https://example.com/chill.jpg")
        XCTAssertEqual(next[0].transportState, .playing)
        XCTAssertEqual(next[0].volume, 14)
    }

    func testHomeSpeakerRefreshDoesNotPreserveFixedDurationTrackWhenIncomingRefreshIsPlaceholder() {
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "playroom-group")
        let existing = [
            makeStatus(
                player: playroom,
                trackInfo: TrackInfo(
                    title: "Waltz, No. 2 (XO)",
                    artist: "Elliott Smith",
                    album: "XO",
                    albumArtURL: "https://example.com/xo.jpg",
                    duration: "00:04:40",
                    position: "00:01:00",
                    source: .appleMusic
                ),
                transportState: .playing,
                volume: 12
            )
        ]
        let incoming = [
            makeStatus(
                player: playroom,
                trackInfo: nil,
                transportState: .stopped,
                volume: 14
            )
        ]

        let next = SonosManager.homeSpeakerStatusesAfterRefresh(
            existing: existing,
            incoming: incoming,
            preferredOrder: []
        )

        XCTAssertNil(next[0].trackInfo)
        XCTAssertEqual(next[0].transportState, .stopped)
        XCTAssertEqual(next[0].volume, 14)
    }

    func testHomeSpeakerRefreshDropsInvisibleCoordinatorGroups() {
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "playroom-group")
        let subMini = makePlayer(
            id: "sub-mini",
            name: "Sub Mini",
            groupId: "sub-mini-group",
            isInvisible: true
        )

        let next = SonosManager.homeSpeakerStatusesAfterRefresh(
            existing: [],
            incoming: [
                makeStatus(player: subMini),
                makeStatus(player: playroom)
            ],
            preferredOrder: []
        )

        XCTAssertEqual(next.map(\.id), ["playroom-group"])
    }

    func testHomeSpeakerCoordinatorCandidatesExcludeInvisibleCoordinators() {
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "playroom-group")
        let subMini = makePlayer(
            id: "sub-mini",
            name: "Sub Mini",
            groupId: "sub-mini-group",
            isInvisible: true
        )
        let visibleMember = SonosPlayer(
            id: "member",
            name: "Member",
            ipAddress: "192.168.1.77",
            isCoordinator: false,
            groupId: "playroom-group"
        )

        let candidates = SonosManager.homeSpeakerCoordinatorCandidates(
            in: [subMini, visibleMember, playroom]
        )

        XCTAssertEqual(candidates.map(\.id), ["playroom"])
    }

    func testTopologyRefreshCandidatesPrioritizeSelectedSpeakerAndDeduplicateRoster() {
        let selected = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.50.249",
            isCoordinator: true,
            groupId: "playroom-group",
            coordinatorIP: "192.168.50.250"
        )
        let staleHomeTheater = SonosPlayer(
            id: "home-theater",
            name: "Home Theater",
            ipAddress: "192.168.50.238",
            isCoordinator: true,
            groupId: "home-theater-group"
        )
        let move = SonosPlayer(
            id: "move",
            name: "Move",
            ipAddress: "192.168.50.197",
            isCoordinator: true,
            groupId: "move-group"
        )

        let candidates = SonosManager.topologyRefreshCandidateIPs(
            selectedSpeaker: selected,
            allSpeakers: [staleHomeTheater, selected, move, staleHomeTheater]
        )

        XCTAssertEqual(
            candidates,
            ["192.168.50.250", "192.168.50.249", "192.168.50.238", "192.168.50.197"]
        )
    }

    func testSkeletonProjectionEndsInitialHomeSpeakerLoader() {
        let manager = SonosManager()
        manager.allSpeakers = [
            makePlayer(id: "playroom", name: "Playroom", groupId: "playroom-group")
        ]

        manager.projectSkeletonGroupStatusesFromSavedSpeakers()

        XCTAssertEqual(manager.groupStatuses.map(\.id), ["playroom-group"])
        XCTAssertTrue(manager.hasLoadedHomeSpeakerCards)
        XCTAssertFalse(manager.showsHomeSpeakerCardsBlockingLoader)
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

    func testCurrentGroupMembersResolveFromGroupStatusesWhenSelectedGroupIdIsMissing() {
        let manager = SonosManager()
        let selected = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.1.20",
            isCoordinator: true,
            groupId: nil
        )
        let move = SonosPlayer(
            id: "move",
            name: "Move",
            ipAddress: "192.168.1.21",
            isCoordinator: false,
            groupId: "rooms-live"
        )
        let hidden = SonosPlayer(
            id: "sub",
            name: "Sub",
            ipAddress: "192.168.1.22",
            isCoordinator: false,
            groupId: "rooms-live",
            isInvisible: true
        )
        let homeTheater = makePlayer(id: "home-theater", name: "Home Theater", groupId: "home-live")

        manager.selectedSpeaker = selected
        manager.allSpeakers = [selected, move, hidden, homeTheater]
        manager.groupStatuses = [
            SpeakerGroupStatus(
                id: "rooms-live",
                coordinator: selected,
                members: [selected, move, hidden],
                trackInfo: nil,
                transportState: .playing
            ),
            makeStatus(player: homeTheater)
        ]

        XCTAssertEqual(manager.currentGroupMembers.map(\.id), ["playroom", "move"])
    }

    func testSpeakerSelectionMatchRejectsStaleRefreshTarget() {
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "playroom-group")
        let move = makePlayer(id: "move", name: "Move", groupId: "move-group")

        XCTAssertFalse(
            SonosManager.speakerSelectionMatches(move, expectedSpeakerID: playroom.id)
        )
        XCTAssertTrue(
            SonosManager.speakerSelectionMatches(playroom, expectedSpeakerID: playroom.id)
        )
    }

    func testPartyModeJoinTargetsOnlyIncludeVisibleSpeakersOutsideCurrentGroup() {
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "home")
        let kitchen = makePlayer(id: "kitchen", name: "Kitchen", groupId: "kitchen")
        let bedroom = makePlayer(id: "bedroom", name: "Bedroom", groupId: "home")
        let bridge = makePlayer(id: "bridge", name: "Bridge", groupId: "bridge", isInvisible: true)

        let targets = SonosManager.partyModeJoinTargets(
            selectedSpeaker: playroom,
            allSpeakers: [playroom, kitchen, bedroom, bridge, kitchen]
        )

        XCTAssertEqual(targets, [kitchen])
    }

    func testPartyModeLeaveTargetsOnlyIncludeCurrentGroupNonCoordinatorMembers() {
        let playroom = makePlayer(id: "playroom", name: "Playroom", groupId: "home")
        let kitchen = makePlayer(id: "kitchen", name: "Kitchen", groupId: "home")
        let bedroom = makePlayer(id: "bedroom", name: "Bedroom", groupId: "bedroom")
        let bridge = makePlayer(id: "bridge", name: "Bridge", groupId: "home", isInvisible: true)

        let targets = SonosManager.partyModeLeaveTargets(
            selectedSpeaker: playroom,
            allSpeakers: [playroom, kitchen, bedroom, bridge, kitchen]
        )

        XCTAssertEqual(targets, [kitchen])
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

    private func makePlayer(
        id: String,
        name: String,
        groupId: String? = nil,
        isInvisible: Bool = false
    ) -> SonosPlayer {
        SonosPlayer(
            id: id,
            name: name,
            ipAddress: "192.168.1.\(abs(id.hashValue % 200) + 20)",
            isCoordinator: true,
            groupId: groupId ?? id,
            isInvisible: isInvisible
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
