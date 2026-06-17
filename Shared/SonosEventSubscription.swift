import Foundation

enum SonosEventService: Equatable, Sendable {
    case avTransport
    case renderingControl
    case zoneGroupTopology
    case contentDirectory

    nonisolated var eventPath: String {
        switch self {
        case .avTransport:
            return "/MediaRenderer/AVTransport/Event"
        case .renderingControl:
            return "/MediaRenderer/RenderingControl/Event"
        case .zoneGroupTopology:
            return "/ZoneGroupTopology/Event"
        case .contentDirectory:
            return "/MediaServer/ContentDirectory/Event"
        }
    }
}

struct SonosEventSubscription: Equatable, Sendable {
    var service: SonosEventService
    var sid: String
    var timeoutSeconds: Int?

    var renewalDelaySeconds: Int {
        guard let timeoutSeconds else { return 3_000 }
        return max(30, Int(Double(timeoutSeconds) * 0.8))
    }
}

enum SonosEventSubscriptionError: Error, Equatable {
    case badURL
    case nonHTTPResponse
    case unexpectedStatus(Int)
    case missingSID
}

struct SonosEventNotification: Equatable, Sendable {
    var sid: String
    var sequence: Int?
    var headers: [String: String]
    var body: String
}

enum SonosEventHTTPParserError: Error, Equatable {
    case incompleteHeaders
    case incompleteBody
    case malformedRequest
    case unsupportedMethod(String)
    case missingSID
}

enum SonosEventHTTPParser {
    private nonisolated static let headerSeparator = Data([13, 10, 13, 10])

    nonisolated static func isCompleteRequest(_ data: Data) -> Bool {
        guard let headerRange = data.range(of: headerSeparator),
              let headers = headerMap(in: data, headerRange: headerRange) else {
            return false
        }
        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        return data.count >= bodyStart + contentLength
    }

    nonisolated static func notification(from data: Data) throws -> SonosEventNotification {
        guard let headerRange = data.range(of: headerSeparator) else {
            throw SonosEventHTTPParserError.incompleteHeaders
        }
        guard let headerText = String(data: data.subdata(in: data.startIndex..<headerRange.lowerBound),
                                      encoding: .utf8) else {
            throw SonosEventHTTPParserError.malformedRequest
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw SonosEventHTTPParserError.malformedRequest
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard let method = requestParts.first else {
            throw SonosEventHTTPParserError.malformedRequest
        }
        guard method.uppercased() == "NOTIFY" else {
            throw SonosEventHTTPParserError.unsupportedMethod(method)
        }

        let headers = headerMap(from: lines.dropFirst())
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard data.count >= bodyEnd else {
            throw SonosEventHTTPParserError.incompleteBody
        }
        guard let sid = headers["sid"], !sid.isEmpty else {
            throw SonosEventHTTPParserError.missingSID
        }

        let bodyData = data.subdata(in: bodyStart..<bodyEnd)
        let body = String(data: bodyData, encoding: .utf8) ?? ""
        return SonosEventNotification(
            sid: sid,
            sequence: headers["seq"].flatMap(Int.init),
            headers: headers,
            body: body)
    }

    nonisolated static var okResponseData: Data {
        Data("HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 0\r\nCONNECTION: close\r\n\r\n".utf8)
    }

    private nonisolated static func headerMap(in data: Data,
                                              headerRange: Range<Data.Index>) -> [String: String]? {
        guard let headerText = String(data: data.subdata(in: data.startIndex..<headerRange.lowerBound),
                                      encoding: .utf8) else {
            return nil
        }
        return headerMap(from: headerText.components(separatedBy: "\r\n").dropFirst())
    }

    private nonisolated static func headerMap<S: Sequence>(from lines: S) -> [String: String]
        where S.Element == String {
        var headers: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                headers[key] = value
            }
        }
        return headers
    }
}

struct SonosEventSubscriptionRegistry: Equatable, Sendable {
    private var subscriptionsBySID: [String: SonosEventSubscription] = [:]

    var subscriptions: [SonosEventSubscription] {
        Array(subscriptionsBySID.values)
    }

    var isEmpty: Bool {
        subscriptionsBySID.isEmpty
    }

    mutating func replace(_ subscription: SonosEventSubscription) {
        subscriptionsBySID = subscriptionsBySID.filter { $0.value.service != subscription.service }
        subscriptionsBySID[subscription.sid] = subscription
    }

    mutating func removeAll() {
        subscriptionsBySID.removeAll()
    }

    mutating func remove(sid: String) {
        subscriptionsBySID.removeValue(forKey: sid)
    }

    func subscription(for service: SonosEventService) -> SonosEventSubscription? {
        subscriptionsBySID.values.first { $0.service == service }
    }

    func service(for notification: SonosEventNotification) -> SonosEventService? {
        subscriptionsBySID[notification.sid]?.service
    }
}

enum SonosEventSubscriptionClient {
    nonisolated static let port = 1400

    nonisolated static func subscribeRequest(ip: String,
                                             service: SonosEventService,
                                             callbackURL: URL,
                                             timeoutSeconds: Int = 300) throws -> URLRequest {
        var request = try baseRequest(ip: ip, service: service, timeoutInterval: 10)
        request.httpMethod = "SUBSCRIBE"
        request.setValue("<\(callbackURL.absoluteString)>", forHTTPHeaderField: "CALLBACK")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue(timeoutHeader(timeoutSeconds), forHTTPHeaderField: "TIMEOUT")
        return request
    }

    nonisolated static func renewRequest(ip: String,
                                         service: SonosEventService,
                                         sid: String,
                                         timeoutSeconds: Int = 300) throws -> URLRequest {
        var request = try baseRequest(ip: ip, service: service, timeoutInterval: 10)
        request.httpMethod = "SUBSCRIBE"
        request.setValue(sid, forHTTPHeaderField: "SID")
        request.setValue(timeoutHeader(timeoutSeconds), forHTTPHeaderField: "TIMEOUT")
        return request
    }

    nonisolated static func unsubscribeRequest(ip: String,
                                               service: SonosEventService,
                                               sid: String) throws -> URLRequest {
        var request = try baseRequest(ip: ip, service: service, timeoutInterval: 10)
        request.httpMethod = "UNSUBSCRIBE"
        request.setValue(sid, forHTTPHeaderField: "SID")
        return request
    }

    nonisolated static func subscribe(ip: String,
                                      service: SonosEventService,
                                      callbackURL: URL,
                                      timeoutSeconds: Int = 300) async throws -> SonosEventSubscription {
        let request = try subscribeRequest(
            ip: ip,
            service: service,
            callbackURL: callbackURL,
            timeoutSeconds: timeoutSeconds)
        let response = try await send(request, ip: ip, service: service, action: "SUBSCRIBE")
        return try subscription(from: response, service: service)
    }

    nonisolated static func renew(ip: String,
                                  existingSubscription: SonosEventSubscription,
                                  timeoutSeconds: Int = 300) async throws -> SonosEventSubscription {
        let request = try renewRequest(
            ip: ip,
            service: existingSubscription.service,
            sid: existingSubscription.sid,
            timeoutSeconds: timeoutSeconds)
        let response = try await send(request, ip: ip, service: existingSubscription.service, action: "RENEW")
        return try subscription(from: response, service: existingSubscription.service)
    }

    nonisolated static func unsubscribe(ip: String,
                                        subscription: SonosEventSubscription) async throws {
        let request = try unsubscribeRequest(
            ip: ip,
            service: subscription.service,
            sid: subscription.sid)
        let response = try await send(request, ip: ip, service: subscription.service, action: "UNSUBSCRIBE")
        try validate(response)
    }

    private nonisolated static func send(_ request: URLRequest,
                                         ip: String,
                                         service: SonosEventService,
                                         action: String) async throws -> URLResponse {
        let auditStartedAt = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            await SonosNetworkAudit.record(
                kind: .event1400,
                host: ip,
                target: service.eventPath,
                action: action,
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .http((response as? HTTPURLResponse)?.statusCode))
            return response
        } catch {
            await SonosNetworkAudit.record(
                kind: .event1400,
                host: ip,
                target: service.eventPath,
                action: action,
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .failure(error))
            throw error
        }
    }

    nonisolated static func subscription(from response: URLResponse,
                                         service: SonosEventService) throws -> SonosEventSubscription {
        guard let http = response as? HTTPURLResponse else {
            throw SonosEventSubscriptionError.nonHTTPResponse
        }
        try validate(http)
        guard let sid = header("SID", in: http), !sid.isEmpty else {
            throw SonosEventSubscriptionError.missingSID
        }
        return SonosEventSubscription(
            service: service,
            sid: sid,
            timeoutSeconds: timeoutSeconds(from: header("TIMEOUT", in: http)))
    }

    nonisolated static func timeoutSeconds(from value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        let lowercased = value.lowercased()
        guard lowercased.hasPrefix("second-") else { return nil }
        let suffix = lowercased.dropFirst("second-".count)
        guard suffix != "infinite" else { return nil }
        return Int(suffix)
    }

    private nonisolated static func baseRequest(ip: String,
                                                service: SonosEventService,
                                                timeoutInterval: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: "http://\(cleanHost(ip)):\(port)\(service.eventPath)") else {
            throw SonosEventSubscriptionError.badURL
        }
        return URLRequest(url: url, timeoutInterval: timeoutInterval)
    }

    private nonisolated static func cleanHost(_ ip: String) -> String {
        let withoutScope = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
        guard withoutScope.contains(":"),
              !withoutScope.hasPrefix("[") else {
            return withoutScope
        }
        return "[\(withoutScope)]"
    }

    private nonisolated static func timeoutHeader(_ seconds: Int) -> String {
        "Second-\(seconds)"
    }

    private nonisolated static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SonosEventSubscriptionError.nonHTTPResponse
        }
        try validate(http)
    }

    private nonisolated static func validate(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw SonosEventSubscriptionError.unexpectedStatus(response.statusCode)
        }
    }

    private nonisolated static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if String(describing: key).caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }
}
