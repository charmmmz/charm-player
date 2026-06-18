import XCTest
@testable import SonosWidget

final class RelayDiscoveryTests: XCTestCase {
    func testManualRelayURLTakesPriorityOverDiscoveredURL() throws {
        let discovered = URL(string: "http://192.168.50.10:8787")!

        let preferred = try XCTUnwrap(
            RelayDiscovery.preferredRelayURL(
                manualURLString: " http://192.168.50.20:8787 ",
                discoveredURL: discovered
            )
        )

        XCTAssertEqual(preferred.absoluteString, "http://192.168.50.20:8787")
    }

    func testDiscoveredRelayURLIsUsedWhenManualURLIsBlank() throws {
        let discovered = URL(string: "http://192.168.50.10:8787")!

        let preferred = try XCTUnwrap(
            RelayDiscovery.preferredRelayURL(
                manualURLString: " ",
                discoveredURL: discovered
            )
        )

        XCTAssertEqual(preferred.absoluteString, "http://192.168.50.10:8787")
    }

    func testRelayURLBuildsHTTPURLFromBonjourHostAndPort() throws {
        let url = try XCTUnwrap(
            RelayDiscovery.relayURL(host: "192.168.50.10", port: 8787)
        )

        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "192.168.50.10")
        XCTAssertEqual(url.port, 8787)
    }

    func testRelayURLConvertsBonjourRootDotHostnameToLocalName() throws {
        let url = try XCTUnwrap(
            RelayDiscovery.relayURL(host: "IMPRESSIVE-NAS.", port: 8787)
        )

        XCTAssertEqual(url.absoluteString, "http://IMPRESSIVE-NAS.local:8787")
    }
}
