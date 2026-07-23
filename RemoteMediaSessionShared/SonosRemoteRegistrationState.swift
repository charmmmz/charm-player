import CryptoKit
import Foundation

@MainActor
final class SonosRemoteRegistrationLedger {
    enum BeginResult: Equatable {
        case register
        case recent
        case inFlight
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let refreshInterval: TimeInterval
    private let retentionInterval: TimeInterval
    private let maxRecords: Int
    private var successfulRegistrations: [String: TimeInterval]
    private var inFlightKeys: Set<String> = []

    init(
        defaults: UserDefaults,
        storageKey: String,
        refreshInterval: TimeInterval,
        retentionInterval: TimeInterval = 24 * 60 * 60,
        maxRecords: Int = 64
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.refreshInterval = refreshInterval
        self.retentionInterval = retentionInterval
        self.maxRecords = maxRecords
        let stored = defaults.dictionary(forKey: storageKey) ?? [:]
        successfulRegistrations = stored.reduce(into: [:]) { result, item in
            if let value = item.value as? NSNumber {
                result[item.key] = value.doubleValue
            }
        }
    }

    func begin(key: String, now: Date = .now) -> BeginResult {
        prune(now: now)
        if inFlightKeys.contains(key) {
            return .inFlight
        }
        if let lastSuccess = successfulRegistrations[key],
           now.timeIntervalSince1970 - lastSuccess < refreshInterval {
            return .recent
        }
        inFlightKeys.insert(key)
        return .register
    }

    func complete(key: String, succeeded: Bool, now: Date = .now) {
        inFlightKeys.remove(key)
        guard succeeded else { return }
        successfulRegistrations[key] = now.timeIntervalSince1970
        prune(now: now)
        defaults.set(successfulRegistrations, forKey: storageKey)
    }

    var recordCount: Int { successfulRegistrations.count }

    private func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 - retentionInterval
        successfulRegistrations = successfulRegistrations.filter { $0.value >= cutoff }
        guard successfulRegistrations.count > maxRecords else { return }
        let newest = successfulRegistrations
            .sorted { $0.value > $1.value }
            .prefix(maxRecords)
        successfulRegistrations = Dictionary(
            uniqueKeysWithValues: newest.map { ($0.key, $0.value) }
        )
    }
}

struct SonosRemoteStartRegistrationState {
    private(set) var passiveRegistrationKey: String?
    private(set) var lastStartRequest: (key: String, date: Date)?
    let retryInterval: TimeInterval

    init(retryInterval: TimeInterval = 30) {
        self.retryInterval = retryInterval
    }

    func shouldRegister(key: String, requestStart: Bool, now: Date = .now) -> Bool {
        if requestStart {
            guard let lastStartRequest, lastStartRequest.key == key else { return true }
            return now.timeIntervalSince(lastStartRequest.date) >= retryInterval
        }
        return passiveRegistrationKey != key
    }

    mutating func recordSuccess(key: String, requestStart: Bool, now: Date = .now) {
        passiveRegistrationKey = key
        if requestStart {
            lastStartRequest = (key, now)
        }
    }

    mutating func resetStartRequest() {
        lastStartRequest = nil
    }
}

enum SonosRemoteRegistrationKey {
    static func make(token: Data, values: [String]) -> String {
        var input = Data()
        input.append(token)
        for value in values {
            input.append(0x1F)
            input.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
