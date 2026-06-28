import XCTest
@testable import SonosWidget

final class SettingsHubDestinationTests: XCTestCase {
    func testPrimaryDestinationsKeepSettingsHubOrder() {
        XCTAssertEqual(SettingsHubDestination.primary, [
            .sonos,
            .externalConnection,
            .hueAmbience,
            .diagnostics,
        ])
    }

    func testPrimaryDestinationsDescribeConsolidatedGroups() {
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.title),
            ["Sonos", "External Connection", "Hue Ambience", "Diagnostics"]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.subtitle),
            [
                "Account, speakers, and music services",
                "Hue Bridge and Live Activity Relay",
                "Music lighting",
                "Logs and troubleshooting",
            ]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.systemImage),
            [
                "hifispeaker.2.fill",
                "externaldrive.connected.to.line.below",
                "sparkles",
                "doc.text.magnifyingglass",
            ]
        )
    }
}
