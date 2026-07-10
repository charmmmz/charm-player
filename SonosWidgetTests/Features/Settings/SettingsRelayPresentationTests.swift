import XCTest
@testable import SonosWidget

@MainActor
final class SettingsRelayPresentationTests: XCTestCase {
    func testLiveActivityPresentationDoesNotDescribeNASRelaySetup() {
        XCTAssertEqual(LiveActivitySettingsPresentation.sectionTitle, "Live Activity")
        XCTAssertFalse(LiveActivitySettingsPresentation.footer.contains("relay"))
        XCTAssertFalse(LiveActivitySettingsPresentation.footer.contains("Relay"))
    }

    func testLightingSetupRelayPresentationUsesNASRelaySectionTitle() {
        XCTAssertEqual(HueLightingRelayPresentation.sectionTitle, "NAS Relay")
        XCTAssertTrue(HueLightingRelayPresentation.footer.contains("NAS Relay"))
        XCTAssertFalse(HueLightingRelayPresentation.footer.contains("Update Lighting Setup"))
        XCTAssertFalse(HueLightingRelayPresentation.footer.localizedCaseInsensitiveContains("update lighting setup"))
    }

    func testLightingSetupRelayPresentationUsesUserFacingLabels() {
        let rows = HueLightingRelayPresentation.statusRows(
            relayStatus: .connected(groupCount: 2),
            syncStatus: .synced(Date(timeIntervalSince1970: 1_700_000_000)),
            hasBridge: true,
            assignmentCount: 2
        )

        XCTAssertEqual(rows.map(\.title), ["Connection", "Lighting Setup"])
        XCTAssertEqual(rows.map(\.value), ["Connected", "Updated"])
        XCTAssertEqual(rows.map(\.tone), [.ready, .ready])
        XCTAssertEqual(rows.compactMap(\.detail), [])
    }

    func testLightingSetupRelayAutoSyncRequiresConnectedRelayAndReadyHueSetup() {
        XCTAssertFalse(
            HueLightingRelayAutoSyncPolicy.shouldSyncAfterConnection(
                relayStatus: .disabled,
                hasBridge: true,
                assignmentCount: 1,
                syncStatus: .idle
            )
        )
        XCTAssertFalse(
            HueLightingRelayAutoSyncPolicy.shouldSyncAfterConnection(
                relayStatus: .connected(groupCount: 1),
                hasBridge: false,
                assignmentCount: 1,
                syncStatus: .idle
            )
        )
        XCTAssertFalse(
            HueLightingRelayAutoSyncPolicy.shouldSyncAfterConnection(
                relayStatus: .connected(groupCount: 1),
                hasBridge: true,
                assignmentCount: 0,
                syncStatus: .idle
            )
        )
        XCTAssertFalse(
            HueLightingRelayAutoSyncPolicy.shouldSyncAfterConnection(
                relayStatus: .connected(groupCount: 1),
                hasBridge: true,
                assignmentCount: 1,
                syncStatus: .syncing
            )
        )
        XCTAssertTrue(
            HueLightingRelayAutoSyncPolicy.shouldSyncAfterConnection(
                relayStatus: .connected(groupCount: 1),
                hasBridge: true,
                assignmentCount: 1,
                syncStatus: .idle
            )
        )
    }

    func testLightingSetupRelayPresentationOnlySurfacesProblemDetails() {
        let rows = HueLightingRelayPresentation.statusRows(
            relayStatus: .unreachable(reason: "Connection refused"),
            syncStatus: .failed("Bridge key expired"),
            hasBridge: true,
            assignmentCount: 1
        )

        XCTAssertEqual(rows.map(\.value), ["Offline", "Could Not Update"])
        XCTAssertEqual(rows.map(\.tone), [.critical, .critical])
        XCTAssertEqual(rows.compactMap(\.detail), ["Connection refused", "Bridge key expired"])
    }
}
