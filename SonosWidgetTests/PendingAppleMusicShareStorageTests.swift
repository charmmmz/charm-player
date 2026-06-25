import XCTest
@testable import SonosWidget

final class PendingAppleMusicShareStorageTests: XCTestCase {
    func testPendingAppleMusicShareRoundTripsThroughSharedStorage() {
        let previous = SharedStorage.pendingAppleMusicShare
        defer { SharedStorage.pendingAppleMusicShare = previous }

        let request = PendingAppleMusicShare(
            id: UUID(uuidString: "A4A248D7-221F-4DD4-8491-E7D3837B6E4B")!,
            urlString: "https://music.apple.com/us/song/nikes/1440857781",
            receivedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        SharedStorage.pendingAppleMusicShare = request

        XCTAssertEqual(SharedStorage.pendingAppleMusicShare, request)
    }

    func testNewPendingAppleMusicShareReplacesPreviousRequest() {
        let previous = SharedStorage.pendingAppleMusicShare
        defer { SharedStorage.pendingAppleMusicShare = previous }

        SharedStorage.pendingAppleMusicShare = PendingAppleMusicShare(
            id: UUID(uuidString: "A4A248D7-221F-4DD4-8491-E7D3837B6E4B")!,
            urlString: "https://music.apple.com/us/song/nikes/1440857781",
            receivedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let replacement = PendingAppleMusicShare(
            id: UUID(uuidString: "49963834-C520-4893-A77B-87BB1452796F")!,
            urlString: "https://music.apple.com/us/album/blonde/1440864059",
            receivedAt: Date(timeIntervalSince1970: 1_780_000_100)
        )

        SharedStorage.pendingAppleMusicShare = replacement

        XCTAssertEqual(SharedStorage.pendingAppleMusicShare, replacement)
    }

    func testClearsPendingAppleMusicShare() {
        let previous = SharedStorage.pendingAppleMusicShare
        defer { SharedStorage.pendingAppleMusicShare = previous }

        SharedStorage.pendingAppleMusicShare = PendingAppleMusicShare(
            id: UUID(uuidString: "A4A248D7-221F-4DD4-8491-E7D3837B6E4B")!,
            urlString: "https://music.apple.com/us/song/nikes/1440857781",
            receivedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        SharedStorage.clearPendingAppleMusicShare()

        XCTAssertNil(SharedStorage.pendingAppleMusicShare)
    }

    func testAppleMusicSonosServiceCredentialRoundTripsThroughSharedStorage() {
        let previous = SharedStorage.appleMusicSonosServiceCredential
        defer { SharedStorage.appleMusicSonosServiceCredential = previous }

        let credential = AppleMusicSonosServiceCredential(
            cloudServiceId: "52231",
            localServiceId: 204,
            accountId: "2",
            username: "X_#Svc52231-2-Token",
            displayName: "Apple Music")

        SharedStorage.appleMusicSonosServiceCredential = credential

        XCTAssertEqual(SharedStorage.appleMusicSonosServiceCredential, credential)
    }

    func testSpeakerIDRoundTripsThroughSharedStorage() {
        let previous = SharedStorage.speakerID
        defer { SharedStorage.speakerID = previous }

        SharedStorage.speakerID = "RINCON_12345678901400"

        XCTAssertEqual(SharedStorage.speakerID, "RINCON_12345678901400")
    }

    func testDiscoveredRelayURLRoundTripsThroughSharedStorage() {
        let previous = SharedStorage.discoveredRelayURLString
        defer { SharedStorage.discoveredRelayURLString = previous }

        SharedStorage.discoveredRelayURLString = "http://192.168.50.20:8787"

        XCTAssertEqual(SharedStorage.discoveredRelayURLString, "http://192.168.50.20:8787")

        SharedStorage.discoveredRelayURLString = nil

        XCTAssertNil(SharedStorage.discoveredRelayURLString)
    }

    func testRouteRecognizesAppleMusicShareURL() {
        let route = AppRoute.route(for: URL(string: "sonoswidget://share/apple-music")!)

        XCTAssertEqual(route, .appleMusicShare)
    }

    func testRouteIgnoresOAuthCallbackURL() {
        let route = AppRoute.route(for: URL(string: "sonoswidget://callback?code=abc&state=xyz")!)

        XCTAssertNil(route)
    }

    func testRouteIgnoresNonAppScheme() {
        let route = AppRoute.route(for: URL(string: "https://music.apple.com/us/song/nikes/1440857781")!)

        XCTAssertNil(route)
    }
}
