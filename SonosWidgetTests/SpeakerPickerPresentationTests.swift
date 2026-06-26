import XCTest
import UIKit
@testable import SonosWidget

final class SpeakerPickerPresentationTests: XCTestCase {
    func testSpeakerPickerCardLayoutMatchesShareSheetDensity() {
        XCTAssertEqual(SpeakerPickerCardLayout.cornerRadius, 8)
        XCTAssertEqual(SpeakerPickerCardLayout.iconSize, 40)
        XCTAssertEqual(SpeakerPickerCardLayout.minimumRowHeight, 76)
        XCTAssertEqual(SpeakerPickerCardLayout.indicatorSlotSize.width, 34)
        XCTAssertEqual(SpeakerPickerCardLayout.indicatorSlotSize.height, 42)
    }

    func testSpeakerPickerPillsUseTextOnlyLabels() {
        XCTAssertFalse(SpeakerPickerPillLayout.showsLeadingIcon)
    }

    func testSpeakerPickerHeaderControlMatchesLiveStreamPresentation() {
        let liveRadio = TrackInfo(
            title: "Apple Music Chill",
            artist: "Apple Music",
            album: "",
            duration: nil,
            source: .radio
        )
        let track = TrackInfo(
            title: "Flora",
            artist: "HNNY",
            album: "Close - EP",
            duration: "0:03:42",
            source: .appleMusic
        )

        XCTAssertEqual(
            SpeakerPickerPlaybackPresentation.headerControlSystemImage(
                trackInfo: liveRadio,
                isPlaying: true
            ),
            "stop.fill"
        )
        XCTAssertEqual(
            SpeakerPickerPlaybackPresentation.headerControlSystemImage(
                trackInfo: liveRadio,
                isPlaying: false
            ),
            "play.fill"
        )
        XCTAssertEqual(
            SpeakerPickerPlaybackPresentation.headerControlSystemImage(
                trackInfo: track,
                isPlaying: true
            ),
            "pause.fill"
        )
        XCTAssertEqual(
            SpeakerPickerPlaybackPresentation.headerControlAccessibilityLabel(
                trackInfo: liveRadio,
                isPlaying: true
            ),
            "Stop Live Stream"
        )
    }

    func testSpeakerPickerSheetContentFrameUsesContainerSize() {
        let container = CGSize(width: 393, height: 720)

        XCTAssertEqual(
            SpeakerPickerSheetLayout.contentFrameSize(containerSize: container),
            container
        )
    }

    func testSpeakerPickerBackgroundCoversPresentationChrome() {
        XCTAssertEqual(
            SpeakerPickerSheetLayout.backgroundCoverage,
            .presentationChrome
        )
    }

    func testSpeakerPickerSubtitleDisplaysCurrentGroupTrack() {
        let speaker = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.1.20",
            isCoordinator: true,
            groupId: "playroom-group"
        )
        let status = SpeakerGroupStatus(
            id: "playroom-group",
            coordinator: speaker,
            members: [speaker],
            trackInfo: TrackInfo(title: "In Between", artist: "LINKIN PARK", album: "From Zero"),
            transportState: .playing
        )

        XCTAssertEqual(
            SpeakerPickerPlaybackPresentation.subtitle(
                for: speaker,
                groupStatuses: [status],
                fallback: "Tap to add"
            ),
            "In Between - LINKIN PARK"
        )
    }

    func testSpeakerPickerArtworkUsesSharedGroupImageCache() {
        let speaker = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.1.20",
            isCoordinator: true,
            groupId: "playroom-group"
        )
        let status = SpeakerGroupStatus(
            id: "playroom-group",
            coordinator: speaker,
            members: [speaker],
            trackInfo: TrackInfo(
                title: "In Between",
                artist: "LINKIN PARK",
                album: "From Zero",
                albumArtURL: "https://example.com/art.jpg"
            ),
            transportState: .playing
        )
        let cachedImage = UIImage()

        XCTAssertTrue(
            SpeakerPickerPlaybackPresentation.artworkImage(
                for: speaker,
                groupStatuses: [status],
                groupImages: ["playroom-group": cachedImage],
                selectedSpeaker: nil,
                selectedAlbumArtImage: nil
            ) === cachedImage
        )
    }

    func testSpeakerPickerArtworkDoesNotReuseSelectedArtworkForDifferentUngroupedSpeaker() {
        let selected = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.1.20",
            isCoordinator: true,
            groupId: nil
        )
        let other = SonosPlayer(
            id: "move",
            name: "Move",
            ipAddress: "192.168.1.21",
            isCoordinator: true,
            groupId: nil
        )

        XCTAssertNil(
            SpeakerPickerPlaybackPresentation.artworkImage(
                for: other,
                groupStatuses: [],
                groupImages: [:],
                selectedSpeaker: selected,
                selectedAlbumArtImage: UIImage()
            )
        )
    }

    func testSpeakerPickerOrdersCurrentGroupCoordinatorBeforeMembers() {
        let coordinator = SonosPlayer(
            id: "home-theater",
            name: "Home Theater",
            ipAddress: "192.168.1.10",
            isCoordinator: true,
            groupId: "home-group"
        )
        let groupedMember = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.1.11",
            isCoordinator: false,
            groupId: "home-group"
        )
        let selectedMember = SonosPlayer(
            id: "bedroom",
            name: "Bedroom",
            ipAddress: "192.168.1.12",
            isCoordinator: false,
            groupId: "home-group"
        )
        let otherCoordinator = SonosPlayer(
            id: "move",
            name: "Move",
            ipAddress: "192.168.1.13",
            isCoordinator: true,
            groupId: "move-group"
        )
        let invisibleSatellite = SonosPlayer(
            id: "surround",
            name: "Surround",
            ipAddress: "192.168.1.14",
            isCoordinator: false,
            groupId: "home-group",
            isInvisible: true
        )

        let ordered = SpeakerPickerPlaybackPresentation.orderedSpeakers(
            [otherCoordinator, groupedMember, selectedMember, invisibleSatellite, coordinator],
            selectedSpeaker: selectedMember
        )

        XCTAssertEqual(
            ordered.map(\.id),
            ["home-theater", "bedroom", "playroom", "move"]
        )
    }

    func testSpeakerPickerOrdersCurrentMembersFromExplicitMembershipWhenSelectedGroupIdIsStale() {
        let playroom = SonosPlayer(
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
        let homeTheater = SonosPlayer(
            id: "home-theater",
            name: "Home Theater",
            ipAddress: "192.168.1.22",
            isCoordinator: true,
            groupId: "home-live"
        )

        let ordered = SpeakerPickerPlaybackPresentation.orderedSpeakers(
            [homeTheater, move, playroom],
            selectedSpeaker: playroom,
            currentGroupMembers: [playroom, move]
        )

        XCTAssertEqual(ordered.map(\.id), ["playroom", "move", "home-theater"])
    }

    func testSpeakerPickerTreatsExplicitCurrentMembersAsActiveWhenGroupIdIsStale() {
        let playroom = SonosPlayer(
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
        let homeTheater = SonosPlayer(
            id: "home-theater",
            name: "Home Theater",
            ipAddress: "192.168.1.22",
            isCoordinator: true,
            groupId: "home-live"
        )

        XCTAssertTrue(
            SpeakerPickerPlaybackPresentation.isSpeakerInCurrentGroup(
                playroom,
                currentGroupMembers: [playroom, move],
                selectedSpeaker: playroom
            )
        )
        XCTAssertTrue(
            SpeakerPickerPlaybackPresentation.isSpeakerInCurrentGroup(
                move,
                currentGroupMembers: [playroom, move],
                selectedSpeaker: playroom
            )
        )
        XCTAssertFalse(
            SpeakerPickerPlaybackPresentation.isSpeakerInCurrentGroup(
                homeTheater,
                currentGroupMembers: [playroom, move],
                selectedSpeaker: playroom
            )
        )
    }

    func testSpeakerPickerKeepsOtherGroupCoordinatorBeforeItsMembers() {
        let current = SonosPlayer(
            id: "home-theater",
            name: "Home Theater",
            ipAddress: "192.168.1.10",
            isCoordinator: true,
            groupId: "home-group"
        )
        let moveMember = SonosPlayer(
            id: "move-satellite",
            name: "Move Satellite",
            ipAddress: "192.168.1.11",
            isCoordinator: false,
            groupId: "move-group"
        )
        let moveCoordinator = SonosPlayer(
            id: "move",
            name: "Move",
            ipAddress: "192.168.1.12",
            isCoordinator: true,
            groupId: "move-group"
        )

        let ordered = SpeakerPickerPlaybackPresentation.orderedSpeakers(
            [moveMember, current, moveCoordinator],
            selectedSpeaker: current
        )

        XCTAssertEqual(
            ordered.map(\.id),
            ["home-theater", "move", "move-satellite"]
        )
    }

    func testSpeakerPickerIndicatorUsesStableStateSlot() {
        XCTAssertEqual(
            SpeakerPickerRowIndicator.make(isProcessing: true, isActive: false, isPlaying: false),
            .processing
        )
        XCTAssertEqual(
            SpeakerPickerRowIndicator.make(isProcessing: false, isActive: true, isPlaying: true),
            .playingWaveform
        )
        XCTAssertEqual(
            SpeakerPickerRowIndicator.make(isProcessing: false, isActive: true, isPlaying: false),
            .restingWaveform
        )
        XCTAssertEqual(
            SpeakerPickerRowIndicator.make(isProcessing: false, isActive: false, isPlaying: false),
            .add
        )

        XCTAssertTrue(SpeakerPickerRowIndicator.processing.showsSpinner)
        XCTAssertNil(SpeakerPickerRowIndicator.playingWaveform.systemImageName)
        XCTAssertEqual(SpeakerPickerRowIndicator.add.systemImageName, "plus.circle.fill")
    }

    func testSpeakerPickerSelectableGroupsOnlyIncludesMultiSpeakerGroups() {
        let playroom = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.1.20",
            isCoordinator: true,
            groupId: "rooms"
        )
        let move = SonosPlayer(
            id: "move",
            name: "Move",
            ipAddress: "192.168.1.21",
            isCoordinator: false,
            groupId: "rooms"
        )
        let kitchen = SonosPlayer(
            id: "kitchen",
            name: "Kitchen",
            ipAddress: "192.168.1.22",
            isCoordinator: true,
            groupId: "kitchen"
        )
        let hidden = SonosPlayer(
            id: "surround",
            name: "Surround",
            ipAddress: "192.168.1.23",
            isCoordinator: false,
            groupId: "kitchen",
            isInvisible: true
        )

        let groups = SpeakerPickerPlaybackPresentation.selectableGroups([
            SpeakerGroupStatus(
                id: "rooms",
                name: "Rooms",
                coordinator: playroom,
                members: [playroom, move],
                trackInfo: nil,
                transportState: .stopped
            ),
            SpeakerGroupStatus(
                id: "kitchen",
                name: "Kitchen",
                coordinator: kitchen,
                members: [kitchen, hidden],
                trackInfo: nil,
                transportState: .stopped
            )
        ])

        XCTAssertEqual(groups.map(\.id), ["rooms"])
    }

    func testSpeakerPickerSelectableGroupsExcludesUnnamedCurrentPlaybackGroup() {
        let playroom = SonosPlayer(
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
        let homeTheater = SonosPlayer(
            id: "home-theater",
            name: "Home Theater",
            ipAddress: "192.168.1.22",
            isCoordinator: true,
            groupId: "rooms"
        )

        let groups = SpeakerPickerPlaybackPresentation.selectableGroups(
            [
                SpeakerGroupStatus(
                    id: "rooms-live",
                    coordinator: playroom,
                    members: [playroom, move],
                    trackInfo: nil,
                    transportState: .playing
                ),
                SpeakerGroupStatus(
                    id: "rooms",
                    name: "Rooms",
                    coordinator: homeTheater,
                    members: [homeTheater, playroom],
                    trackInfo: nil,
                    transportState: .stopped
                )
            ],
            currentGroupMembers: [playroom, move]
        )

        XCTAssertEqual(groups.map(\.id), ["rooms"])
    }

    func testSpeakerPickerGroupDisplayNamePrefersCloudNameThenMemberNames() {
        let playroom = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.1.20",
            isCoordinator: true,
            groupId: "rooms"
        )
        let move = SonosPlayer(
            id: "move",
            name: "Move",
            ipAddress: "192.168.1.21",
            isCoordinator: false,
            groupId: "rooms"
        )

        let named = SpeakerGroupStatus(
            id: "rooms",
            name: "Rooms",
            coordinator: playroom,
            members: [playroom, move],
            trackInfo: nil,
            transportState: .stopped
        )
        let unnamed = SpeakerGroupStatus(
            id: "rooms",
            coordinator: playroom,
            members: [playroom, move],
            trackInfo: nil,
            transportState: .stopped
        )

        XCTAssertEqual(SpeakerPickerPlaybackPresentation.groupDisplayName(for: named), "Rooms")
        XCTAssertEqual(SpeakerPickerPlaybackPresentation.groupDisplayName(for: unnamed), "Playroom + Move")
    }

    func testSpeakerPickerSelectableAreasExcludesReadOnlyEverywhereAndEmptyAreas() {
        let areas = [
            SonosArea(
                id: "rooms",
                name: "Rooms",
                isReadOnly: false,
                playerIds: ["home-theater", "playroom"]
            ),
            SonosArea(
                id: "everywhere",
                name: "Everywhere",
                isReadOnly: true,
                playerIds: ["home-theater", "playroom", "move"]
            ),
            SonosArea(
                id: "empty",
                name: "Empty",
                isReadOnly: false,
                playerIds: []
            )
        ]

        let selectable = SpeakerPickerPlaybackPresentation.selectableAreas(areas)

        XCTAssertEqual(selectable.map(\.id), ["rooms"])
    }

    func testSpeakerPickerAreaSubtitleUsesKnownPlayerNames() {
        let homeTheater = SonosPlayer(
            id: "home-theater",
            name: "Home Theater",
            ipAddress: "192.168.1.10",
            isCoordinator: true,
            groupId: "home-group"
        )
        let playroom = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.1.20",
            isCoordinator: true,
            groupId: "playroom-group"
        )
        let area = SonosArea(
            id: "rooms",
            name: "Rooms",
            playerIds: ["home-theater", "playroom"]
        )

        XCTAssertEqual(
            SpeakerPickerPlaybackPresentation.areaSubtitle(
                for: area,
                allSpeakers: [playroom, homeTheater]
            ),
            "Home Theater + Playroom"
        )
    }

    func testSpeakerPickerAreaIsActiveWhenVisibleGroupMembersMatchAreaPlayers() {
        let homeTheater = SonosPlayer(
            id: "home-theater",
            name: "Home Theater",
            ipAddress: "192.168.1.10",
            isCoordinator: true,
            groupId: "rooms-live"
        )
        let playroom = SonosPlayer(
            id: "playroom",
            name: "Playroom",
            ipAddress: "192.168.1.20",
            isCoordinator: false,
            groupId: "rooms-live"
        )
        let move = SonosPlayer(
            id: "move",
            name: "Move",
            ipAddress: "192.168.1.21",
            isCoordinator: true,
            groupId: "move-live"
        )
        let area = SonosArea(
            id: "rooms",
            name: "Rooms",
            playerIds: ["home-theater", "playroom"]
        )

        XCTAssertTrue(
            SpeakerPickerPlaybackPresentation.isAreaActive(
                area,
                currentGroupMembers: [playroom, homeTheater]
            )
        )
        XCTAssertFalse(
            SpeakerPickerPlaybackPresentation.isAreaActive(
                area,
                currentGroupMembers: [homeTheater, move]
            )
        )
    }
}
