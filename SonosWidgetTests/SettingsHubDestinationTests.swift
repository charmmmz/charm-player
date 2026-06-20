import XCTest
@testable import SonosWidget

final class SettingsHubDestinationTests: XCTestCase {
    func testPrimaryDestinationsKeepSettingsHubOrder() {
        XCTAssertEqual(SettingsHubDestination.primary, [
            .sonos,
            .hueAmbience,
            .hubSetup,
            .diagnostics,
        ])
    }

    func testPrimaryDestinationsDescribeConsolidatedGroups() {
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.title),
            ["Sonos", "Hue Ambience", "Hub Setup", "Diagnostics"]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.subtitle),
            [
                "Account, speakers, and music services",
                "Music and game lighting",
                "Hue Bridge, NAS Relay, and NAS Agent",
                "Logs and troubleshooting",
            ]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.systemImage),
            [
                "hifispeaker.2.fill",
                "sparkles",
                "externaldrive.connected.to.line.below",
                "doc.text.magnifyingglass",
            ]
        )
    }
}
