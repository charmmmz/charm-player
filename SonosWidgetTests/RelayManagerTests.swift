import XCTest
@testable import SonosWidget

@MainActor
final class RelayManagerTests: XCTestCase {
    func testLiveActivityRegistrationEncodesStylePreference() throws {
        let body = RelayClient.ActivityRegistrationBody(
            groupId: "192.168.50.25",
            token: "push-token",
            clientId: "client-1",
            activityId: "activity-1",
            speakerName: "Playroom",
            liveActivityStyleRaw: "widget"
        )

        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["groupId"] as? String, "192.168.50.25")
        XCTAssertEqual(json["token"] as? String, "push-token")
        XCTAssertEqual(json["clientId"] as? String, "client-1")
        XCTAssertEqual(json["activityId"] as? String, "activity-1")
        XCTAssertEqual(json["liveActivityStyleRaw"] as? String, "widget")
        let attributes = try XCTUnwrap(json["attributes"] as? [String: String])
        XCTAssertEqual(attributes["speakerName"], "Playroom")
    }

    func testLiveActivityPreferencesRequestOnlyEncodesStyleContract() throws {
        let body = RelayClient.LiveActivityPreferencesBody(
            groupId: "192.168.50.25",
            liveActivityStyleRaw: "classic"
        )

        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        XCTAssertEqual(json, [
            "groupId": "192.168.50.25",
            "liveActivityStyleRaw": "classic"
        ])
    }

    func testLiveActivityCommandEncodesSoundbarFields() throws {
        let body = RelayClient.LiveActivityCommandBody(
            groupId: "192.168.50.25",
            token: "push-token",
            command: "setSoundbarSpeechEnhancement",
            volume: nil,
            nightMode: nil,
            speechEnhancementRawLevel: 2
        )

        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["groupId"] as? String, "192.168.50.25")
        XCTAssertEqual(json["token"] as? String, "push-token")
        XCTAssertEqual(json["command"] as? String, "setSoundbarSpeechEnhancement")
        XCTAssertEqual(json["speechEnhancementRawLevel"] as? Int, 2)
        XCTAssertNil(json["volume"])
        XCTAssertNil(json["nightMode"])
    }

    func testRelayPlaybackStateDecodesSoundbarFields() throws {
        let data = Data("""
        {
          "groupId": "192.168.50.25",
          "speakerName": "Playroom",
          "trackTitle": "TV",
          "artist": "Live audio",
          "album": "",
          "albumArtUri": null,
          "isPlaying": true,
          "playbackSourceRaw": "tv",
          "soundbarNightMode": true,
          "soundbarSpeechEnhancementRawLevel": 3,
          "audioQualityLabel": "Dolby Atmos · MAT",
          "positionSeconds": 0,
          "durationSeconds": 0,
          "groupMemberCount": 1
        }
        """.utf8)

        let state = try JSONDecoder().decode(RelayClient.RelayPlaybackState.self, from: data)

        XCTAssertEqual(state.soundbarNightMode, true)
        XCTAssertEqual(state.soundbarSpeechEnhancementRawLevel, 3)
    }

    func testPlaybackStateURLUsesRelayBaseURLAndCoordinatorGroup() throws {
        let url = try XCTUnwrap(
            RelayClient.playbackStateURL(
                baseURL: URL(string: "http://192.168.50.2:8787")!,
                groupId: " 192.168.50.25 "
            )
        )

        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "192.168.50.2")
        XCTAssertEqual(url.port, 8787)
        XCTAssertEqual(url.path, "/api/playback-state")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "groupId" })?.value,
            "192.168.50.25"
        )
    }

    func testPlaybackStateResponseDecodesCachedRelayState() throws {
        let data = Data("""
        {
          "ok": true,
          "source": "cached",
          "state": {
            "groupId": "192.168.50.25",
            "speakerName": "Playroom",
            "trackTitle": "Song A",
            "artist": "Artist A",
            "album": "Album A",
            "albumArtUri": "http://192.168.50.25:1400/getaa?u=x",
            "isPlaying": true,
            "playbackSourceRaw": "appleMusic",
            "audioQualityLabel": "Lossless",
            "soundbarNightMode": null,
            "soundbarSpeechEnhancementRawLevel": null,
            "positionSeconds": 42,
            "durationSeconds": 240,
            "groupMemberCount": 2
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(RelayClient.PlaybackStateResponse.self, from: data)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.source, "cached")
        XCTAssertEqual(response.state?.trackTitle, "Song A")
        XCTAssertEqual(response.state?.albumArtUri, "http://192.168.50.25:1400/getaa?u=x")
        XCTAssertEqual(response.state?.groupMemberCount, 2)
    }

    func testLiveActivityCommandRouteUsesRegisteredRelayTokenAndCoordinatorGroup() throws {
        let route = try XCTUnwrap(
            RelayClient.liveActivityCommandRoute(
                relayURLString: " http://192.168.50.2:8787 ",
                relayPushToken: " push-token ",
                coordinatorIP: "192.168.50.25",
                fallbackGroupId: "192.168.50.26"
            )
        )

        XCTAssertEqual(route.baseURL.absoluteString, "http://192.168.50.2:8787")
        XCTAssertEqual(route.groupId, "192.168.50.25")
        XCTAssertEqual(route.token, "push-token")
    }

    func testLiveActivityCommandRouteRequiresURLAndToken() {
        XCTAssertNil(
            RelayClient.liveActivityCommandRoute(
                relayURLString: nil,
                relayPushToken: "push-token",
                coordinatorIP: "192.168.50.25",
                fallbackGroupId: "192.168.50.26"
            )
        )
        XCTAssertNil(
            RelayClient.liveActivityCommandRoute(
                relayURLString: "http://192.168.50.2:8787",
                relayPushToken: " ",
                coordinatorIP: "192.168.50.25",
                fallbackGroupId: "192.168.50.26"
            )
        )
    }

    func testArtworkProxyURLUsesRelayBaseURLAndEncodesSourceArtworkURL() throws {
        let url = try XCTUnwrap(
            RelayClient.artworkProxyURL(
                baseURL: URL(string: "http://192.168.50.2:8787")!,
                sourceURLString: " http://192.168.50.25:1400/getaa?s=1&u=x y "
            )
        )

        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "192.168.50.2")
        XCTAssertEqual(url.port, 8787)
        XCTAssertEqual(url.path, "/api/artwork")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "url" })?.value,
            "http://192.168.50.25:1400/getaa?s=1&u=x y"
        )
    }

    func testArtworkProxyURLRejectsMissingOrUnsupportedSourceArtworkURL() {
        let baseURL = URL(string: "http://192.168.50.2:8787")!

        XCTAssertNil(RelayClient.artworkProxyURL(baseURL: baseURL, sourceURLString: " "))
        XCTAssertNil(RelayClient.artworkProxyURL(baseURL: baseURL, sourceURLString: "file:///tmp/cover.jpg"))
    }

    func testHealthResponseDecodesUnknownHueAmbienceRenderModeAsNil() throws {
        let data = Data("""
        {
          "ok": true,
          "groups": [],
          "hueAmbience": {
            "configured": true,
            "enabled": true,
            "runtimeActive": true,
            "renderMode": "trueStreaming",
            "activeTargetIds": ["area-1", "light-2"],
            "entertainmentTargetActive": true,
            "entertainmentMetadataComplete": true,
            "lastFrameAt": "2026-05-12T00:00:00.000Z",
            "lastError": null
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(RelayClient.HealthResponse.self, from: data)

        XCTAssertNil(response.hueAmbience?.renderMode)
        XCTAssertEqual(response.hueAmbience?.activeTargetIds, ["area-1", "light-2"])
    }

    func testHealthResponseDecodesEntertainmentAndCS2LightingStatus() throws {
        let data = Data("""
        {
          "ok": true,
          "groups": [],
          "hueAmbience": {
            "configured": true,
            "enabled": true
          },
          "hueEntertainment": {
            "configured": true,
            "bridgeReachable": true,
            "streaming": "occupied",
            "activeStreamer": "Hue Sync",
            "activeAreaId": "ent-1",
            "lastError": null
          },
          "cs2Lighting": {
            "enabled": true,
            "active": false,
            "mode": "competitive",
            "transport": "clipFallback",
            "fallbackReason": "entertainment_occupied",
            "areaId": "ent-game",
            "areaName": "PC"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(RelayClient.HealthResponse.self, from: data)

        XCTAssertEqual(response.hueEntertainment?.streaming, .occupied)
        XCTAssertEqual(response.hueEntertainment?.activeStreamer, "Hue Sync")
        XCTAssertEqual(response.hueEntertainment?.activeAreaId, "ent-1")
        XCTAssertEqual(response.cs2Lighting?.enabled, true)
        XCTAssertEqual(response.cs2Lighting?.active, false)
        XCTAssertEqual(response.cs2Lighting?.mode, .competitive)
        XCTAssertEqual(response.cs2Lighting?.transport, .clipFallback)
        XCTAssertEqual(response.cs2Lighting?.fallbackReason, "entertainment_occupied")
        XCTAssertEqual(response.cs2Lighting?.areaId, "ent-game")
        XCTAssertEqual(response.cs2Lighting?.areaName, "PC")
    }

    func testHealthResponseDecodesRelayDiscoveryAndAPNsStatus() throws {
        let data = Data("""
        {
          "ok": true,
          "groups": [],
          "sonos": {
            "discoveryMode": "auto",
            "discoveryStatus": "ready",
            "discoveryError": null
          },
          "apns": {
            "mode": "ready",
            "environment": "production",
            "bundleId": "com.charm.SonosWidget",
            "keyIdConfigured": true,
            "teamIdConfigured": true,
            "keyFilePresent": true,
            "missing": []
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(RelayClient.HealthResponse.self, from: data)

        XCTAssertEqual(response.sonos?.discoveryMode, .auto)
        XCTAssertEqual(response.sonos?.discoveryStatus, .ready)
        XCTAssertNil(response.sonos?.discoveryError)
        XCTAssertEqual(response.apns?.mode, .ready)
        XCTAssertEqual(response.apns?.environment, .production)
        XCTAssertEqual(response.apns?.bundleId, "com.charm.SonosWidget")
        XCTAssertEqual(response.apns?.missing, [])
    }

    func testHueAmbienceStatusResponseDecodesUnknownRenderModeAsNil() throws {
        let data = Data("""
        {
          "ok": true,
          "status": {
            "configured": true,
            "enabled": true,
            "bridge": {
              "id": "bridge-1",
              "ipAddress": "192.168.1.2",
              "name": "Hue Bridge"
            },
            "mappings": 1,
            "lights": 2,
            "areas": 1,
            "cs2LightingEnabled": true,
            "cs2EntertainmentAreaId": "ent-game",
            "runtimeActive": true,
            "activeGroupId": "group-1",
            "renderMode": "trueStreaming",
            "activeTargetIds": ["area-1"],
            "entertainmentTargetActive": true,
            "entertainmentMetadataComplete": true,
            "lastFrameAt": "2026-05-12T00:00:00.000Z",
            "lastError": null
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(RelayClient.HueAmbienceStatusResponse.self, from: data)

        XCTAssertNil(response.status.renderMode)
        XCTAssertEqual(response.status.cs2LightingEnabled, true)
        XCTAssertEqual(response.status.cs2EntertainmentAreaId, "ent-game")
    }

    func testDisabledHueAmbienceConfigStillReportsSynced() async {
        let relay = RelayManager.shared
        await prepareUnavailableRelay(relay)
        defer { resetRelay(relay) }

        relay.updateHueAmbienceRuntimeStatus(
            configured: true,
            enabled: false,
            lastError: "stale runtime failure"
        )

        XCTAssertTrue(relay.isHueAmbienceRelayConfigured)
        XCTAssertFalse(relay.isHueAmbienceRelayEnabled)
        guard case .synced = relay.hueAmbienceSyncStatus else {
            return XCTFail("Disabled Hue config should still be marked as synced to NAS")
        }
        XCTAssertEqual(
            relay.hueAmbienceRuntimeStatus,
            .ready("Album ambience disabled")
        )
        XCTAssertEqual(
            relay.hueAmbienceRuntimeDetail,
            "Enable album ambience or CS2 sync to let NAS control your lights."
        )
        XCTAssertFalse(relay.shouldDeferLocalHueAmbience)
    }

    func testStreamingReadyRuntimeReportsClipFallbackDetail() async {
        let relay = RelayManager.shared
        await prepareUnavailableRelay(relay)
        defer { resetRelay(relay) }

        relay.updateHueAmbienceRuntimeStatus(
            configured: true,
            renderMode: .streamingReady,
            runtimeActive: true,
            activeTargetIds: ["light-1"],
            lastFrameAt: "2026-05-12T00:00:00.000Z"
        )

        XCTAssertTrue(relay.isHueAmbienceRelayConfigured)
        XCTAssertTrue(relay.isHueAmbienceRelayEnabled)
        XCTAssertEqual(
            relay.hueAmbienceRuntimeStatus,
            .fallback("Streaming-ready via CLIP fallback")
        )
        XCTAssertEqual(
            relay.hueAmbienceRuntimeDetail,
            "NAS controls Hue Ambience while it is reachable."
        )
        XCTAssertFalse(relay.shouldDeferLocalHueAmbience)
    }

    private func prepareUnavailableRelay(_ relay: RelayManager) async {
        relay.setURL("http://127.0.0.1:1")
        relay.stopPeriodicProbe()
        await relay.probeNow()
        relay.stopPeriodicProbe()
    }

    private func resetRelay(_ relay: RelayManager) {
        relay.setURL("")
        relay.stopPeriodicProbe()
    }
}
