import Foundation

/// Categorized logger for Sonos Widget.
///
/// Three levels:
///   - `.error` — always emitted, prefixed `[Category] ERROR:` so it stands
///     out during user-reported bug hunts.
///   - `.info`  — always emitted. Reserve for successful state transitions
///     and summary counts (e.g. "Added to favorites", "Refreshed N items").
///   - `.debug` — stripped at compile time in Release builds via `#if DEBUG`.
///     Use for verbose request/response traces, internal fallback decisions,
///     and diagnostic banners that would otherwise spam the console.
///
/// Every call site picks a `Category` so filtering in Xcode console or the
/// in-app diagnostics viewer is easy (search e.g. `[Playback]` to see all
/// playback logs).
enum SonosLog {
    /// All log categories used across the app. Add new cases here rather
    /// than inventing bare-string prefixes at call sites.
    enum Category: String, CaseIterable {
        case search         = "Search"
        case playback       = "Playback"
        case station        = "Station"
        case favorites      = "Favorites"
        case cloudAPI       = "CloudAPI"
        case cloudSearch    = "CloudSearch"
        case soap           = "SOAP"
        case sonosCloud     = "SonosCloud"
        case sonosAuth      = "SonosAuth"
        case artistDetail   = "ArtistDetail"
        case albumDetail    = "AlbumDetail"
        case playlistDetail = "PlaylistDetail"
        case localService   = "LocalService"
        case nowPlaying     = "NowPlaying"
        case parseCloudIds  = "parseCloudIds"
        case navItem        = "NavItem"
        case sonosEvents    = "SonosEvents"
        case networkAudit   = "NetworkAudit"
        case playbackLink   = "PlaybackLink"
        case relay          = "Relay"
    }

    /// Always logged. Use sparingly for unexpected failures worth reporting.
    @inline(__always)
    nonisolated static func error(_ category: Category, _ message: @autoclosure () -> String) {
        emit(category, level: .error, suffix: " ERROR:", message())
    }

    /// Always logged. Use for operational signal (success, counts, state).
    @inline(__always)
    nonisolated static func info(
        _ category: Category,
        _ message: @autoclosure () -> String,
        flushRemoteImmediately: Bool = false
    ) {
        emit(
            category,
            level: .info,
            suffix: nil,
            message(),
            flushRemoteImmediately: flushRemoteImmediately
        )
    }

    /// Compiled out of Release builds. Use for high-volume traces and
    /// internal details that would otherwise drown the console.
    @inline(__always)
    nonisolated static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        #if DEBUG
        emit(category, level: .debug, suffix: nil, message())
        #endif
    }

    nonisolated static func playbackLinkValue(_ value: String?, maxLength: Int = 2_048) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        let singleLine = value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        guard singleLine.count > maxLength else { return singleLine }
        let clipped = singleLine.prefix(maxLength)
        return "\(clipped)…[truncated \(singleLine.count - maxLength) chars]"
    }

    nonisolated static func playbackMetadataSummary(_ metadata: String) -> String {
        let itemId = firstXMLAttribute(named: "id", inTags: ["item", "container"], from: metadata) ?? "nil"
        let desc = firstXMLTag(named: "desc", from: metadata) ?? "nil"
        let hasArt = metadata.contains("albumArtURI")
        let tag = metadata.contains("<container") ? "container" : (metadata.contains("<item") ? "item" : "unknown")
        return "bytes=\(metadata.utf8.count) tag=\(tag) itemId=\(playbackLinkValue(itemId, maxLength: 240)) " +
            "desc=\(playbackLinkValue(desc, maxLength: 240)) hasArt=\(hasArt)"
    }

    private nonisolated static func emit(
        _ category: Category,
        level: RemoteDiagnosticLogLevel,
        suffix: String?,
        _ message: String,
        flushRemoteImmediately: Bool = false
    ) {
        let line = "[\(category.rawValue)]\(suffix ?? "") \(message)"
        print(line)
        writeDiagnosticLine(
            line,
            category: category,
            level: level,
            message: message,
            flushRemoteImmediately: flushRemoteImmediately
        )
    }

    private nonisolated static func writeDiagnosticLine(
        _ line: String,
        category: Category,
        level: RemoteDiagnosticLogLevel,
        message: String,
        flushRemoteImmediately: Bool = false
    ) {
        guard diagnosticCategories.contains(category) else {
            return
        }

        let timestamp = diagnosticTimestamp()
        RemoteDiagnosticLogSink.enqueue(
            timestamp: timestamp,
            category: category.rawValue,
            level: level.rawValue,
            message: message,
            line: line,
            flushImmediately: flushRemoteImmediately
        )

        guard let fileURL = diagnosticFileURL(),
              let data = "\(timestamp) \(line)\n".data(using: .utf8) else {
            return
        }

        diagnosticQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    let header = "SonosWidget diagnostics\n"
                    try header.write(to: fileURL, atomically: true, encoding: .utf8)
                }

                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
                trimDiagnosticFileIfNeeded(fileURL)
            } catch {
                // Diagnostics must never affect app behavior.
            }
        }
    }

    private nonisolated static let diagnosticCategories = Set(Category.allCases)
    private nonisolated static let diagnosticQueueKey = DispatchSpecificKey<Void>()
    private nonisolated static let diagnosticQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.charm.SonosWidget.diagnostics")
        queue.setSpecific(key: diagnosticQueueKey, value: ())
        return queue
    }()
    private nonisolated static let diagnosticAppGroupID = "group.com.charm.SonosWidget"
    private nonisolated static let diagnosticMaxBytes = 1_048_576
    private nonisolated static let diagnosticMaxLines = 2_000

    nonisolated static func diagnosticLogFileURL() -> URL? {
        diagnosticFileURL()
    }

    nonisolated static func flushDiagnosticWrites() {
        if DispatchQueue.getSpecific(key: diagnosticQueueKey) != nil {
            return
        }
        diagnosticQueue.sync {}
    }

    private nonisolated static func diagnosticFileURL() -> URL? {
        if let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: diagnosticAppGroupID
        ) {
            return appGroupURL
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("sonos-diagnostics.log")
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("sonos-diagnostics.log")
    }

    private nonisolated static func diagnosticTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private nonisolated static func trimDiagnosticFileIfNeeded(_ fileURL: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > diagnosticMaxBytes,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }

        let bodyLines = text
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("SonosWidget") }
            .suffix(diagnosticMaxLines)

        var keptLines = Array(bodyLines)
        var trimmed = diagnosticText(from: keptLines)
        while trimmed.utf8.count > diagnosticMaxBytes, keptLines.count > 1 {
            keptLines.removeFirst()
            trimmed = diagnosticText(from: keptLines)
        }

        try? trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private nonisolated static func diagnosticText(from bodyLines: [String]) -> String {
        let body = bodyLines.joined(separator: "\n")
        guard !body.isEmpty else {
            return "SonosWidget diagnostics\n"
        }
        return "SonosWidget diagnostics\n\(body)\n"
    }

    private nonisolated static func firstXMLAttribute(
        named attribute: String,
        inTags tags: [String],
        from xml: String
    ) -> String? {
        for tag in tags {
            let pattern = #"<\#(tag)\s+[^>]*\#(attribute)="([^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(xml.startIndex..., in: xml)
            guard let match = regex.firstMatch(in: xml, range: range),
                  let valueRange = Range(match.range(at: 1), in: xml) else {
                continue
            }
            return String(xml[valueRange])
        }
        return nil
    }

    private nonisolated static func firstXMLTag(named tag: String, from xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = #"<\#(escaped)(?:\s[^>]*)?>(.*?)</\#(escaped)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let valueRange = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[valueRange])
    }
}

private enum RemoteDiagnosticLogLevel: String {
    case debug
    case info
    case error
}

private enum RemoteDiagnosticLogSink {
    nonisolated static func enqueue(
        timestamp: String,
        category: String,
        level: String,
        message: String,
        line: String,
        flushImmediately: Bool = false
    ) {
        let redactedMessage = DiagnosticRemoteLogRedactor.redact(message)
        let redactedLine = DiagnosticRemoteLogRedactor.redact(line)
        Task.detached(priority: flushImmediately ? .userInitiated : .background) {
            await RemoteDiagnosticLogBatcher.shared.enqueue(
                timestamp: timestamp,
                category: category,
                level: level,
                message: redactedMessage,
                line: redactedLine,
                flushImmediately: flushImmediately
            )
        }
    }
}

private actor RemoteDiagnosticLogBatcher {
    static let shared = RemoteDiagnosticLogBatcher()

    private var pending: [RemoteDeviceLogEntryBody] = []
    private var flushTask: Task<Void, Never>?
    private let maxBatchSize = 20
    private let maxBufferedEntries = 200

    func enqueue(
        timestamp: String,
        category: String,
        level: String,
        message: String,
        line: String,
        flushImmediately: Bool = false
    ) async {
        guard Self.relayBaseURL() != nil else { return }

        pending.append(
            RemoteDeviceLogEntryBody(
                timestamp: timestamp,
                category: category,
                level: level,
                message: message,
                line: line
            )
        )

        if pending.count > maxBufferedEntries {
            pending.removeFirst(pending.count - maxBufferedEntries)
        }

        if flushImmediately || pending.count >= maxBatchSize {
            flushTask?.cancel()
            flushTask = nil
            await flush()
            return
        }

        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            await self.flush()
        }
    }

    private func flush() async {
        flushTask?.cancel()
        flushTask = nil

        guard let baseURL = Self.relayBaseURL(),
              !pending.isEmpty else {
            return
        }

        let entries = pending
        pending.removeAll(keepingCapacity: true)

        let body = RemoteDeviceLogBody(
            clientId: Self.clientID(),
            bundleId: Bundle.main.bundleIdentifier,
            processName: ProcessInfo.processInfo.processName,
            entries: entries
        )
        try? await Self.postDeviceLogs(baseURL: baseURL, body: body)
    }

    private static func relayBaseURL() -> URL? {
        let manualURLString = defaults.string(forKey: "relayURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let discoveredURLString = defaults.string(forKey: "discoveredRelayURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let urlString = manualURLString.isEmpty ? discoveredURLString : manualURLString
        guard !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    private static func clientID() -> String {
        if let existing = defaults.string(forKey: "liveActivityRelayClientID"), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: "liveActivityRelayClientID")
        return value
    }

    private static func postDeviceLogs(baseURL: URL, body: RemoteDeviceLogBody) async throws {
        guard !body.entries.isEmpty else { return }

        let url = baseURL.appendingPathComponent("/api/device-logs")
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await remoteSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static let remoteSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.com.charm.SonosWidget") ?? .standard
    }
}

private nonisolated struct RemoteDeviceLogEntryBody: Encodable, Sendable {
    let timestamp: String
    let category: String
    let level: String
    let message: String
    let line: String
}

private nonisolated struct RemoteDeviceLogBody: Encodable, Sendable {
    let clientId: String
    let bundleId: String?
    let processName: String?
    let entries: [RemoteDeviceLogEntryBody]
}

enum DiagnosticRemoteLogRedactor {
    nonisolated static func redact(_ value: String) -> String {
        var redacted = value
        redacted = replace(
            #"X_#Svc(\d+)-[A-Za-z0-9_-]+-Token"#,
            in: redacted,
            with: #"X_#Svc$1-<redacted>-Token"#
        )
        redacted = replace(
            #"(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+"#,
            in: redacted,
            with: #"$1<redacted>"#
        )
        redacted = replace(
            #"(?i)((?:access|refresh)_token=)[^\s&]+"#,
            in: redacted,
            with: #"$1<redacted>"#
        )
        return redacted
    }

    private nonisolated static func replace(
        _ pattern: String,
        in value: String,
        with template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }
}
