import XCTest
@testable import SonosWidget

final class SonosLocalControlAPITests: XCTestCase {
    func testPlayerInfoRequestUsesLocalControlEndpointAndApiKey() throws {
        let request = try SonosLocalControlAPI.playerInfoRequest(
            ip: "192.168.50.251",
            playerId: "RINCON_804AF2200FD601400")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://192.168.50.251:1443/api/v1/players/RINCON_804AF2200FD601400/info")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Sonos-Api-Key"),
            "12345678-abcd-1234-5678-123456789000")
    }

    func testPlaybackMetadataRequestEscapesLocalGroupIdAndUsesApiKey() throws {
        let request = try SonosLocalControlAPI.playbackMetadataRequest(
            ip: "192.168.50.251",
            groupId: "RINCON_804AF2200FD601400:529200070")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://192.168.50.251:1443/api/v1/groups/RINCON_804AF2200FD601400:529200070/playbackMetadata")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Sonos-Api-Key"),
            "12345678-abcd-1234-5678-123456789000")
    }

    func testAreasRequestUsesLocalHouseholdEndpointAndApiKey() throws {
        let request = try SonosLocalControlAPI.areasRequest(
            ip: "192.168.50.251",
            householdId: "Sonos_household.member")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://192.168.50.251:1443/api/v1/households/Sonos_household.member/areas")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Sonos-Api-Key"),
            "12345678-abcd-1234-5678-123456789000")
    }

    func testCreateGroupRequestIncludesAreaIdsForLocalSavedGroupApply() throws {
        let request = try SonosLocalControlAPI.createGroupRequest(
            ip: "192.168.50.251",
            householdId: "Sonos_household.member",
            playerIds: [
                "RINCON_74CA6064AF2E01400",
                "RINCON_804AF2200FD601400"
            ],
            areaIds: ["35dfa6d4-e96d-4f3b-841f-4b6ac404f8ee"],
            musicContextGroupId: "RINCON_804AF2200FD601400:529200070")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://192.168.50.251:1443/api/v1/households/Sonos_household.member/groups/createGroup")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(
            object?["playerIds"] as? [String],
            [
                "RINCON_74CA6064AF2E01400",
                "RINCON_804AF2200FD601400"
            ])
        XCTAssertEqual(
            object?["areaIds"] as? [String],
            ["35dfa6d4-e96d-4f3b-841f-4b6ac404f8ee"])
        XCTAssertEqual(
            object?["musicContextGroupId"] as? String,
            "RINCON_804AF2200FD601400:529200070")
    }

    func testDecodesPlayerInfoLocalGroupId() throws {
        let json = """
        {
          "_objectType": "discoveryInfo",
          "householdId": "Sonos_household.member",
          "playerId": "RINCON_804AF2200FD601400",
          "groupId": "RINCON_804AF2200FD601400:529200070",
          "restUrl": "https://192.168.50.251:1443/api"
        }
        """.data(using: .utf8)!

        let info = try SonosLocalControlAPI.decodePlayerInfo(json)

        XCTAssertEqual(info.householdId, "Sonos_household.member")
        XCTAssertEqual(info.playerId, "RINCON_804AF2200FD601400")
        XCTAssertEqual(info.groupId, "RINCON_804AF2200FD601400:529200070")
    }

    func testDecodesLocalAreasResponse() throws {
        let json = """
        {
          "_objectType": "areas",
          "areas": [
            {
              "_objectType": "area",
              "id": "35dfa6d4-e96d-4f3b-841f-4b6ac404f8ee",
              "name": "Rooms",
              "playerIds": [
                "RINCON_74CA6064AF2E01400",
                "RINCON_804AF2200FD601400"
              ]
            },
            {
              "_objectType": "area",
              "id": "7055133f-81e7-45e6-ba70-8803966c7185",
              "name": "Everywhere",
              "isReadOnly": true,
              "playerIds": [
                "RINCON_804AF2200FD601400",
                "RINCON_C43875026BE801400",
                "RINCON_74CA6064AF2E01400"
              ]
            }
          ],
          "version": "v9/example"
        }
        """.data(using: .utf8)!

        let response = try SonosLocalControlAPI.decodeAreas(json)

        XCTAssertEqual(response.version, "v9/example")
        XCTAssertEqual(response.areas.map(\.name), ["Rooms", "Everywhere"])
        XCTAssertEqual(response.areas.first?.isReadOnly, false)
        XCTAssertEqual(response.areas.last?.isReadOnly, true)
        XCTAssertEqual(
            response.areas.first?.playerIds,
            [
                "RINCON_74CA6064AF2E01400",
                "RINCON_804AF2200FD601400"
            ])
    }

    func testLocalPlaybackMetadataQualityMapsLosslessAndAtmosFlags() throws {
        let lossless = SonosCloudAPI.CloudTrackQuality(
            codec: nil,
            lossless: true,
            bitDepth: 16,
            sampleRate: 44_100,
            immersive: false)
        let atmos = SonosCloudAPI.CloudTrackQuality(
            codec: nil,
            lossless: false,
            bitDepth: 24,
            sampleRate: 48_000,
            immersive: true)

        XCTAssertEqual(AudioQuality.from(cloudQuality: lossless)?.label, "Lossless")
        XCTAssertEqual(AudioQuality.from(cloudQuality: lossless)?.badgeAssetImageName, "BadgeAppleLossless")
        XCTAssertEqual(AudioQuality.from(cloudQuality: atmos)?.label, "Dolby Atmos")
        XCTAssertEqual(AudioQuality.from(cloudQuality: atmos)?.badgeAssetImageName, "BadgeDolbyAtmos")
    }

    func testLocalPlaybackMetadataDoesNotGuessLosslessWhenFlagIsMissing() throws {
        let incomplete = SonosCloudAPI.CloudTrackQuality(
            codec: nil,
            lossless: nil,
            bitDepth: 16,
            sampleRate: 44_100,
            immersive: false)

        XCTAssertNil(AudioQuality.from(cloudQuality: incomplete))
    }

    func testLocalPlaybackMetadataKeepsLossySampleRateAsTextOnlyQuality() throws {
        let lossy = SonosCloudAPI.CloudTrackQuality(
            codec: nil,
            lossless: false,
            bitDepth: 16,
            sampleRate: 48_000,
            immersive: false)

        let quality = try XCTUnwrap(AudioQuality.from(cloudQuality: lossy))

        XCTAssertEqual(quality.label, "16-bit/48 kHz")
        XCTAssertNil(quality.badgeAssetImageName)
    }
}
