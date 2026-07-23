import XCTest
@testable import SonosWidget

@MainActor
final class MusicAmbienceSettingsPresentationTests: XCTestCase {
    func testEnableControlReflectsRelayPausedStateWhenRelayOwnsRuntime() {
        XCTAssertFalse(HueAmbienceEnableControlPolicy.effectiveIsEnabled(
            localEnabled: true,
            relayAvailable: true,
            relayConfigured: true,
            relayRunning: false
        ))
        XCTAssertTrue(HueAmbienceEnableControlPolicy.effectiveIsEnabled(
            localEnabled: true,
            relayAvailable: true,
            relayConfigured: true,
            relayRunning: true
        ))
    }

    func testEnableControlFallsBackToLocalSettingWithoutActiveRelayRuntime() {
        XCTAssertTrue(HueAmbienceEnableControlPolicy.effectiveIsEnabled(
            localEnabled: true,
            relayAvailable: false,
            relayConfigured: true,
            relayRunning: false
        ))
        XCTAssertTrue(HueAmbienceEnableControlPolicy.usesRelayRuntime(
            relayAvailable: true,
            relayConfigured: true
        ))
        XCTAssertFalse(HueAmbienceEnableControlPolicy.effectiveIsEnabled(
            localEnabled: true,
            relayAvailable: true,
            relayConfigured: true,
            relayRunning: false
        ))
    }

    func testAmbienceSettingsSectionTitleUsesAmbienceLabel() {
        XCTAssertEqual(HueAmbienceStatusPresentation.ambienceSectionTitle, "Ambience")
    }

    func testStatusChipsUseCompactTopLevelLabels() {
        let chips = HueAmbienceStatusPresentation.statusChips(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Living Hue"),
            lightingStatus: .syncing("Syncing 2 Hue areas"),
            relayActiveGroups: [],
            playbackSnapshot: HueAmbiencePlaybackSnapshot(
                selectedSonosID: "living",
                selectedSonosName: "Living Room",
                groupMemberIDs: ["living", "kitchen"],
                groupMemberNamesByID: ["living": "Living Room", "kitchen": "Kitchen"],
                trackTitle: "Song",
                artist: "Artist",
                albumArtURL: "art",
                isPlaying: true,
                albumArtImage: nil
            ),
            mappings: [
                HueSonosMapping(sonosID: "living", sonosName: "Living Room", preferredTarget: .room("room-1")),
                HueSonosMapping(sonosID: "kitchen", sonosName: "Kitchen", preferredTarget: .room("room-2")),
            ],
            groupStrategy: .allMappedRooms
        )

        XCTAssertEqual(chips.map(\.title), ["Bridge", "Lighting", "Syncing"])
        XCTAssertEqual(chips.map(\.value), ["Connected", "Changing", "Living Room + Kitchen"])
        XCTAssertEqual(chips.map(\.tone), [.ready, .ready, .ready])
        XCTAssertEqual(chips.compactMap(\.detail), [])
    }

    func testStatusChipsPreferRelayActiveGroupsOverSelectedPlaybackSnapshot() {
        let chips = HueAmbienceStatusPresentation.statusChips(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Living Hue"),
            lightingStatus: .syncing("Syncing 2 Hue areas"),
            relayActiveGroups: [
                HueAmbienceActiveSyncGroup(
                    groupId: "192.168.50.25",
                    speakerName: "Playroom",
                    activeTargetIds: ["room-1"]
                ),
                HueAmbienceActiveSyncGroup(
                    groupId: "192.168.50.99",
                    speakerName: "Home Theater",
                    activeTargetIds: ["room-2"]
                ),
            ],
            playbackSnapshot: HueAmbiencePlaybackSnapshot(
                selectedSonosID: "playroom",
                selectedSonosName: "Playroom",
                groupMemberIDs: ["playroom"],
                groupMemberNamesByID: ["playroom": "Playroom"],
                trackTitle: "Song",
                artist: "Artist",
                albumArtURL: "art",
                isPlaying: true,
                albumArtImage: nil
            ),
            mappings: [],
            groupStrategy: .allMappedRooms
        )

        XCTAssertEqual(chips.last?.title, "Syncing")
        XCTAssertEqual(chips.last?.value, "Playroom + Home Theater")
        XCTAssertEqual(chips.last?.tone, .ready)
    }

    func testRelayDelegatedLightingShowsReadyWhenRelayHasNoActiveGroups() {
        let chips = HueAmbienceStatusPresentation.statusChips(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Living Hue"),
            lightingStatus: .syncing("NAS Relay controlling Hue Ambience"),
            relayActiveGroups: [],
            playbackSnapshot: nil,
            mappings: [],
            groupStrategy: .allMappedRooms
        )

        let lightingChip = chips.first { $0.title == "Lighting" }
        XCTAssertEqual(lightingChip?.value, "Ready")
        XCTAssertEqual(lightingChip?.tone, .ready)
    }

    func testStatusChipsOnlySurfaceProblemDetails() {
        let chips = HueAmbienceStatusPresentation.statusChips(
            bridge: nil,
            lightingStatus: .error("Hue API timeout"),
            relayActiveGroups: [],
            playbackSnapshot: nil,
            mappings: [],
            groupStrategy: .allMappedRooms
        )

        XCTAssertEqual(chips.map(\.value), ["Not Paired", "Needs Attention", "No Active Group"])
        XCTAssertEqual(chips.map(\.tone), [.neutral, .critical, .neutral])
        XCTAssertEqual(chips.compactMap(\.detail), ["Hue API timeout"])
    }

    func testStatusChipsShowUnassignedActiveGroup() {
        let chips = HueAmbienceStatusPresentation.statusChips(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Living Hue"),
            lightingStatus: .paused("No Hue area mapped"),
            relayActiveGroups: [],
            playbackSnapshot: HueAmbiencePlaybackSnapshot(
                selectedSonosID: "office",
                selectedSonosName: "Office",
                groupMemberIDs: ["office"],
                groupMemberNamesByID: ["office": "Office"],
                trackTitle: "Song",
                artist: "Artist",
                albumArtURL: "art",
                isPlaying: true,
                albumArtImage: nil
            ),
            mappings: [
                HueSonosMapping(sonosID: "living", sonosName: "Living Room", preferredTarget: .room("room-1")),
            ],
            groupStrategy: .allMappedRooms
        )

        XCTAssertEqual(chips.last?.title, "Syncing")
        XCTAssertEqual(chips.last?.value, "Not Assigned")
        XCTAssertEqual(chips.last?.tone, .neutral)
    }

    func testSetupActionTitleIsSingleSourceForBridgeManagement() {
        XCTAssertEqual(
            HueAmbienceStatusPresentation.setupActionTitle(bridge: nil),
            "Set Up Hue Bridge"
        )
        XCTAssertEqual(
            HueAmbienceStatusPresentation.setupActionTitle(
                bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Living Hue")
            ),
            "Manage Hue Bridge"
        )
    }

    func testSetupUpdateActionIsSingleOwnerForLightingSetupPush() {
        XCTAssertEqual(HueAmbienceSetupPresentation.updateLightsActionTitle, "Update Lights")
    }

    func testAssignmentPresentationShowsAreaAndLightCounts() {
        let area = HueAreaResource(
            id: "room-1",
            name: "Living Room",
            kind: .room,
            childLightIDs: ["light-1", "light-2", "light-3"]
        )
        let lights = [
            HueLightResource(
                id: "light-1",
                name: "Main",
                ownerID: "room-1",
                supportsColor: true,
                supportsGradient: false,
                supportsEntertainment: false,
                function: .decorative
            ),
            HueLightResource(
                id: "light-2",
                name: "Corner",
                ownerID: "room-1",
                supportsColor: true,
                supportsGradient: false,
                supportsEntertainment: false,
                function: .decorative
            ),
            HueLightResource(
                id: "light-3",
                name: "Desk",
                ownerID: "room-1",
                supportsColor: true,
                supportsGradient: false,
                supportsEntertainment: false,
                function: .functional
            ),
        ]
        let mapping = HueSonosMapping(
            sonosID: "speaker-1",
            sonosName: "Living Room",
            preferredTarget: .room("room-1"),
            excludedLightIDs: ["light-2"],
            capability: .basic
        )

        XCTAssertEqual(
            HueAssignmentPresentation.subtitle(mapping: mapping, area: area),
            "Living Room"
        )
        XCTAssertEqual(
            HueAssignmentPresentation.lightSummary(mapping: mapping, area: area, lights: lights),
            "Lights Used: 1 of 3"
        )
    }
}
