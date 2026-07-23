import XCTest
@testable import SonosWidget

final class SonosEventSubscriptionTests: XCTestCase {
    func testSubscribeRequestMatchesUPnPEventHeaders() throws {
        let callbackURL = try XCTUnwrap(URL(string: "http://192.168.50.10:1401/sonos/events"))

        let request = try SonosEventSubscriptionClient.subscribeRequest(
            ip: "192.168.50.238",
            service: .avTransport,
            callbackURL: callbackURL,
            timeoutSeconds: 600)

        XCTAssertEqual(request.url?.absoluteString, "http://192.168.50.238:1400/MediaRenderer/AVTransport/Event")
        XCTAssertEqual(request.httpMethod, "SUBSCRIBE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CALLBACK"), "<http://192.168.50.10:1401/sonos/events>")
        XCTAssertEqual(request.value(forHTTPHeaderField: "NT"), "upnp:event")
        XCTAssertEqual(request.value(forHTTPHeaderField: "TIMEOUT"), "Second-600")
        XCTAssertNil(request.value(forHTTPHeaderField: "SID"))
    }

    func testRenewRequestUsesSIDWithoutCallbackOrNotificationType() throws {
        let request = try SonosEventSubscriptionClient.renewRequest(
            ip: "192.168.50.238",
            service: .renderingControl,
            sid: "uuid:subscription-123",
            timeoutSeconds: 300)

        XCTAssertEqual(request.url?.absoluteString, "http://192.168.50.238:1400/MediaRenderer/RenderingControl/Event")
        XCTAssertEqual(request.httpMethod, "SUBSCRIBE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "SID"), "uuid:subscription-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "TIMEOUT"), "Second-300")
        XCTAssertNil(request.value(forHTTPHeaderField: "CALLBACK"))
        XCTAssertNil(request.value(forHTTPHeaderField: "NT"))
    }

    func testUnsubscribeRequestUsesSIDOnly() throws {
        let request = try SonosEventSubscriptionClient.unsubscribeRequest(
            ip: "fe80::1234%en0",
            service: .zoneGroupTopology,
            sid: "uuid:subscription-456")

        XCTAssertEqual(request.url?.absoluteString, "http://[fe80::1234]:1400/ZoneGroupTopology/Event")
        XCTAssertEqual(request.httpMethod, "UNSUBSCRIBE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "SID"), "uuid:subscription-456")
        XCTAssertNil(request.value(forHTTPHeaderField: "CALLBACK"))
        XCTAssertNil(request.value(forHTTPHeaderField: "NT"))
        XCTAssertNil(request.value(forHTTPHeaderField: "TIMEOUT"))
    }

    func testParsesSubscriptionResponseHeaders() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.50.238:1400/MediaRenderer/AVTransport/Event"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "SID": "uuid:subscription-789",
                "TIMEOUT": "Second-1800"
            ]))

        let subscription = try SonosEventSubscriptionClient.subscription(from: response, service: .avTransport)

        XCTAssertEqual(subscription.service, .avTransport)
        XCTAssertEqual(subscription.sid, "uuid:subscription-789")
        XCTAssertEqual(subscription.timeoutSeconds, 1_800)
        XCTAssertEqual(subscription.renewalDelaySeconds, 1_440)
    }

    func testParsesInfiniteTimeoutAsNil() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.50.238:1400/MediaRenderer/AVTransport/Event"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "sid": "uuid:subscription-789",
                "timeout": "Second-infinite"
            ]))

        let subscription = try SonosEventSubscriptionClient.subscription(from: response, service: .avTransport)

        XCTAssertEqual(subscription.sid, "uuid:subscription-789")
        XCTAssertNil(subscription.timeoutSeconds)
        XCTAssertEqual(subscription.renewalDelaySeconds, 3_000)
    }

    func testRejectsSubscriptionResponseWithoutSID() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.50.238:1400/MediaRenderer/AVTransport/Event"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["TIMEOUT": "Second-1800"]))

        XCTAssertThrowsError(
            try SonosEventSubscriptionClient.subscription(from: response, service: .avTransport)
        ) { error in
            XCTAssertEqual(error as? SonosEventSubscriptionError, .missingSID)
        }
    }

    func testParsesUPnPNotifyRequest() throws {
        let body = """
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0"><e:property><LastChange>&lt;Event xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/AVT/&quot;&gt;&lt;/Event&gt;</LastChange></e:property></e:propertyset>
        """
        let request = [
            "NOTIFY /sonos/events HTTP/1.1",
            "HOST: 192.168.50.10:1401",
            "CONTENT-TYPE: text/xml; charset=\"utf-8\"",
            "NT: upnp:event",
            "NTS: upnp:propchange",
            "SID: uuid:subscription-789",
            "SEQ: 12",
            "CONTENT-LENGTH: \(body.utf8.count)",
            "",
            body
        ].joined(separator: "\r\n")

        let notification = try SonosEventHTTPParser.notification(from: Data(request.utf8))

        XCTAssertEqual(notification.sid, "uuid:subscription-789")
        XCTAssertEqual(notification.sequence, 12)
        XCTAssertEqual(notification.body, body)
        XCTAssertEqual(notification.headers["nt"], "upnp:event")
        XCTAssertEqual(notification.headers["nts"], "upnp:propchange")
    }

    func testRejectsIncompleteNotifyRequest() throws {
        let body = "<e:propertyset></e:propertyset>"
        let request = [
            "NOTIFY /sonos/events HTTP/1.1",
            "SID: uuid:subscription-789",
            "CONTENT-LENGTH: \(body.utf8.count + 1)",
            "",
            body
        ].joined(separator: "\r\n")

        XCTAssertFalse(SonosEventHTTPParser.isCompleteRequest(Data(request.utf8)))
        XCTAssertThrowsError(try SonosEventHTTPParser.notification(from: Data(request.utf8))) { error in
            XCTAssertEqual(error as? SonosEventHTTPParserError, .incompleteBody)
        }
    }

    func testSubscriptionRegistryMatchesNotifySID() throws {
        let notification = SonosEventNotification(
            sid: "uuid:subscription-789",
            sequence: 0,
            headers: [:],
            body: "")
        var registry = SonosEventSubscriptionRegistry()

        registry.replace(SonosEventSubscription(
            service: .avTransport,
            sid: "uuid:subscription-789",
            timeoutSeconds: 600))

        XCTAssertEqual(registry.service(for: notification), .avTransport)
    }

    func testRenderingControlClassifierOnlyEscalatesSoundbarEQEvents() {
        XCTAssertFalse(SonosManager.renderingControlEventContainsSoundbarEQ(
            "&lt;Volume channel=&quot;Master&quot; val=&quot;32&quot;/&gt;"
        ))
        XCTAssertTrue(SonosManager.renderingControlEventContainsSoundbarEQ(
            "&lt;NightMode val=&quot;1&quot;/&gt;"
        ))
        XCTAssertTrue(SonosManager.renderingControlEventContainsSoundbarEQ(
            "&lt;DialogLevel val=&quot;3&quot;/&gt;"
        ))
        XCTAssertTrue(SonosManager.renderingControlEventContainsSoundbarEQ(
            "&lt;SpeechEnhanceEnabled val=&quot;1&quot;/&gt;"
        ))
    }

    func testEventListenerCallbackURLUsesNonZeroPort() throws {
        let listener = SonosEventListener(localAddressProvider: { "127.0.0.1" }) { _ in }
        let callbackURL = try listener.start()
        defer { listener.stop() }

        XCTAssertEqual(callbackURL.host(), "127.0.0.1")
        XCTAssertNotNil(callbackURL.port)
        XCTAssertNotEqual(callbackURL.port, 0)
    }
}
