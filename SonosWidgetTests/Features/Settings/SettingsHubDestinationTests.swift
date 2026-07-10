import XCTest
@testable import SonosWidget

final class SettingsHubDestinationTests: XCTestCase {
    func testPrimaryDestinationsKeepSettingsHubOrder() {
        XCTAssertEqual(SettingsHubDestination.primary, [
            .sonos,
            .hueAmbience,
            .externalConnection,
            .diagnostics,
        ])
    }

    func testPrimaryDestinationsDescribeConsolidatedGroups() {
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.title),
            ["Sonos", "Hue Ambience", "Live Activity & Relay", "Diagnostics"]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.subtitle),
            [
                "Account, speakers, and music services",
                "Bridge, room assignments, and music lighting",
                "Lock Screen style and NAS relay",
                "Logs and troubleshooting",
            ]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.systemImage),
            [
                "hifispeaker.2.fill",
                "sparkles",
                "antenna.radiowaves.left.and.right",
                "doc.text.magnifyingglass",
            ]
        )
    }
}
