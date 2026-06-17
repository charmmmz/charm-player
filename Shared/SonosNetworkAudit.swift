import Foundation

enum SonosNetworkAudit {
    enum Kind: String, Sendable, Hashable {
        case soap1400
        case http1400
        case event1400
        case local1443
    }

    struct Status: Sendable {
        let label: String
        let failed: Bool

        static func http(_ code: Int?) -> Status {
            guard let code else { return Status(label: "ok", failed: false) }
            return Status(label: "http\(code)", failed: !(200 ... 299).contains(code))
        }

        static func success(_ label: String = "ok") -> Status {
            Status(label: label, failed: false)
        }

        static func failure(_ error: Error) -> Status {
            Status(label: String(describing: error), failed: true)
        }
    }

    nonisolated static func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()))
    }

    nonisolated static func record(kind: Kind,
                                   host: String?,
                                   target: String,
                                   action: String,
                                   durationMs: Int,
                                   status: Status) async {
        #if DEBUG
        await SonosNetworkAuditStore.shared.record(
            kind: kind,
            host: host,
            target: target,
            action: action,
            durationMs: durationMs,
            status: status)
        #endif
    }
}

#if DEBUG
private actor SonosNetworkAuditStore {
    static let shared = SonosNetworkAuditStore()

    private struct Key: Hashable {
        var kind: SonosNetworkAudit.Kind
        var host: String
        var target: String
        var action: String
    }

    private struct Aggregate {
        var count = 0
        var failures = 0
        var slow = 0
        var totalMs = 0
        var maxMs = 0

        mutating func record(durationMs: Int, failed: Bool, slowThresholdMs: Int) {
            count += 1
            totalMs += durationMs
            maxMs = max(maxMs, durationMs)
            if failed { failures += 1 }
            if durationMs >= slowThresholdMs { slow += 1 }
        }

        var averageMs: Int {
            guard count > 0 else { return 0 }
            return totalMs / count
        }
    }

    private var aggregates: [Key: Aggregate] = [:]
    private var windowStartedAt = Date()
    private var windowRequestCount = 0

    private let windowSeconds: TimeInterval = 10
    private let maxWindowRequests = 40

    func record(kind: SonosNetworkAudit.Kind,
                host: String?,
                target: String,
                action: String,
                durationMs: Int,
                status: SonosNetworkAudit.Status) {
        let normalizedHost = normalize(host, fallback: "-")
        let normalizedTarget = normalize(target, fallback: "-")
        let normalizedAction = normalize(action, fallback: "-")
        let threshold = slowThresholdMs(for: kind)

        let key = Key(
            kind: kind,
            host: normalizedHost,
            target: normalizedTarget,
            action: normalizedAction)
        var aggregate = aggregates[key] ?? Aggregate()
        aggregate.record(durationMs: durationMs, failed: status.failed, slowThresholdMs: threshold)
        aggregates[key] = aggregate
        windowRequestCount += 1

        if status.failed || durationMs >= threshold {
            SonosLog.info(
                .networkAudit,
                "request kind=\(kind.rawValue) host=\(normalizedHost) target=\(normalizedTarget) action=\(normalizedAction) durationMs=\(durationMs) status=\(status.label)")
        }

        let now = Date()
        if now.timeIntervalSince(windowStartedAt) >= windowSeconds || windowRequestCount >= maxWindowRequests {
            flush(now: now)
        }
    }

    private func flush(now: Date) {
        guard windowRequestCount > 0 else { return }

        let elapsed = max(0.1, now.timeIntervalSince(windowStartedAt))
        let total = aggregates.values.reduce(0) { $0 + $1.count }
        let failures = aggregates.values.reduce(0) { $0 + $1.failures }
        let slow = aggregates.values.reduce(0) { $0 + $1.slow }
        SonosLog.info(
            .networkAudit,
            "summary windowSeconds=\(String(format: "%.1f", elapsed)) total=\(total) slow=\(slow) failures=\(failures)")

        let entries = aggregates.sorted { lhs, rhs in
            if lhs.value.maxMs == rhs.value.maxMs {
                return lhs.value.count > rhs.value.count
            }
            return lhs.value.maxMs > rhs.value.maxMs
        }.prefix(10)

        for (key, aggregate) in entries {
            SonosLog.info(
                .networkAudit,
                "\(key.kind.rawValue) host=\(key.host) target=\(key.target) action=\(key.action) count=\(aggregate.count) avgMs=\(aggregate.averageMs) maxMs=\(aggregate.maxMs) failures=\(aggregate.failures)")
        }

        aggregates.removeAll()
        windowRequestCount = 0
        windowStartedAt = now
    }

    private func slowThresholdMs(for kind: SonosNetworkAudit.Kind) -> Int {
        switch kind {
        case .local1443:
            return 700
        case .event1400:
            return 1_000
        case .http1400, .soap1400:
            return 1_500
        }
    }

    private func normalize(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.count <= 140 { return trimmed }
        return String(trimmed.prefix(137)) + "..."
    }
}
#endif
