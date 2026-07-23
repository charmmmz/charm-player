import Foundation
import XCTest
@testable import SonosWidget

final class RemoteMediaSessionSharedTests: XCTestCase {
    @MainActor
    func testRegistrationLedgerCoalescesInflightAndPersistsRecentSuccess() {
        let suiteName = "RemoteMediaSessionSharedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_000)
        let ledger = SonosRemoteRegistrationLedger(
            defaults: defaults,
            storageKey: "registrations",
            refreshInterval: 900
        )

        XCTAssertEqual(ledger.begin(key: "token-a", now: now), .register)
        XCTAssertEqual(ledger.begin(key: "token-a", now: now), .inFlight)
        ledger.complete(key: "token-a", succeeded: true, now: now)
        XCTAssertEqual(ledger.begin(key: "token-a", now: now), .recent)

        let reloaded = SonosRemoteRegistrationLedger(
            defaults: defaults,
            storageKey: "registrations",
            refreshInterval: 900
        )
        XCTAssertEqual(reloaded.begin(key: "token-a", now: now), .recent)
        XCTAssertEqual(
            reloaded.begin(key: "token-a", now: now.addingTimeInterval(901)),
            .register
        )
    }

    @MainActor
    func testRegistrationLedgerRetriesImmediatelyAfterFailure() {
        let suiteName = "RemoteMediaSessionSharedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ledger = SonosRemoteRegistrationLedger(
            defaults: defaults,
            storageKey: "registrations",
            refreshInterval: 900
        )

        XCTAssertEqual(ledger.begin(key: "token-a"), .register)
        ledger.complete(key: "token-a", succeeded: false)
        XCTAssertEqual(ledger.begin(key: "token-a"), .register)
    }

    func testStartRegistrationKeepsPassiveAndStartRequestStateIndependent() {
        let now = Date(timeIntervalSince1970: 1_000)
        var state = SonosRemoteStartRegistrationState(retryInterval: 30)

        XCTAssertTrue(state.shouldRegister(key: "start-token", requestStart: false, now: now))
        state.recordSuccess(key: "start-token", requestStart: false, now: now)
        XCTAssertFalse(state.shouldRegister(key: "start-token", requestStart: false, now: now))
        XCTAssertTrue(state.shouldRegister(key: "start-token", requestStart: true, now: now))

        state.recordSuccess(key: "start-token", requestStart: true, now: now)
        XCTAssertFalse(state.shouldRegister(key: "start-token", requestStart: true, now: now))
        XCTAssertTrue(
            state.shouldRegister(
                key: "start-token",
                requestStart: true,
                now: now.addingTimeInterval(31)
            )
        )

        state.resetStartRequest()
        XCTAssertTrue(state.shouldRegister(key: "start-token", requestStart: true, now: now))
    }

    func testRegistrationKeyChangesWithTokenSessionOrGeneration() {
        let token = Data([0x01, 0x02])
        let first = SonosRemoteRegistrationKey.make(
            token: token,
            values: ["session-a", "generation-a"]
        )
        let second = SonosRemoteRegistrationKey.make(
            token: token,
            values: ["session-b", "generation-a"]
        )
        let nextGeneration = SonosRemoteRegistrationKey.make(
            token: token,
            values: ["session-a", "generation-b"]
        )
        let rotated = SonosRemoteRegistrationKey.make(
            token: Data([0x03]),
            values: ["session-a", "generation-a"]
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, nextGeneration)
        XCTAssertNotEqual(first, rotated)
    }

    func testArtworkCacheCoalescesRequestsAndPersistsData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteArtworkCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = RemoteArtworkLoadCounter()
        let expected = Data(repeating: 0x5A, count: 4_096)
        let url = URL(string: "https://example.test/cover.jpg")!
        let cache = SonosRemoteArtworkDataCache(directory: directory) { _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return expected
        }

        async let first = cache.data(for: url)
        async let second = cache.data(for: url)
        let values = try await [first, second]
        XCTAssertEqual(values.map(\.data), [expected, expected])
        let loadCount = await counter.value
        XCTAssertEqual(loadCount, 1)

        let reloaded = SonosRemoteArtworkDataCache(directory: directory) { _ in
            await counter.increment()
            return Data(repeating: 0x00, count: 4_096)
        }
        let diskValue = try await reloaded.data(for: url)
        XCTAssertEqual(diskValue.data, expected)
        XCTAssertEqual(diskValue.source, .disk)
        let finalLoadCount = await counter.value
        XCTAssertEqual(finalLoadCount, 1)
    }
}

private actor RemoteArtworkLoadCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
