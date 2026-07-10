import Foundation

enum SonosLocalControlAPI {
    nonisolated static let port = 1443
    nonisolated static let apiKey = "12345678-abcd-1234-5678-123456789000"

    struct PlayerInfo: Decodable, Sendable {
        let householdId: String?
        let playerId: String?
        let groupId: String?
        let restUrl: String?
    }

    struct AreasResponse: Decodable, Sendable {
        let areas: [SonosArea]
        let version: String?
    }

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(
            configuration: configuration,
            delegate: SonosLocalControlSessionDelegate(),
            delegateQueue: nil)
    }()

    nonisolated static func playerInfo(ip: String, playerId: String) async throws -> PlayerInfo {
        let request = try playerInfoRequest(ip: ip, playerId: playerId)
        let data = try await data(for: request)
        return try decodePlayerInfo(data)
    }

    nonisolated static func getPlaybackMetadata(ip: String, playerId: String) async throws -> SonosCloudAPI.CloudPlaybackMetadata {
        let info = try await playerInfo(ip: ip, playerId: playerId)
        guard let groupId = info.groupId, !groupId.isEmpty else {
            throw SonosLocalControlError.missingGroupId
        }
        return try await getPlaybackMetadata(ip: ip, groupId: groupId)
    }

    nonisolated static func getPlaybackMetadata(ip: String, groupId: String) async throws -> SonosCloudAPI.CloudPlaybackMetadata {
        let request = try playbackMetadataRequest(ip: ip, groupId: groupId)
        let data = try await data(for: request)
        return try decodePlaybackMetadata(data)
    }

    nonisolated static func getAreas(ip: String, householdId: String) async throws -> AreasResponse {
        let request = try areasRequest(ip: ip, householdId: householdId)
        let data = try await data(for: request)
        return try decodeAreas(data)
    }

    @discardableResult
    nonisolated static func createGroup(
        ip: String,
        householdId: String,
        playerIds: [String],
        areaIds: [String],
        musicContextGroupId: String?
    ) async throws -> SonosCloudAPI.CreateGroupResponse {
        let request = try createGroupRequest(
            ip: ip,
            householdId: householdId,
            playerIds: playerIds,
            areaIds: areaIds,
            musicContextGroupId: musicContextGroupId)
        let data = try await data(for: request)
        return try JSONDecoder().decode(SonosCloudAPI.CreateGroupResponse.self, from: data)
    }

    nonisolated static func playerInfoRequest(ip: String, playerId: String) throws -> URLRequest {
        try request(ip: ip, path: "/api/v1/players/\(pathSegment(playerId))/info")
    }

    nonisolated static func playbackMetadataRequest(ip: String, groupId: String) throws -> URLRequest {
        try request(ip: ip, path: "/api/v1/groups/\(pathSegment(groupId))/playbackMetadata")
    }

    nonisolated static func areasRequest(ip: String, householdId: String) throws -> URLRequest {
        try request(ip: ip, path: "/api/v1/households/\(pathSegment(householdId))/areas")
    }

    nonisolated static func createGroupRequest(
        ip: String,
        householdId: String,
        playerIds: [String],
        areaIds: [String],
        musicContextGroupId: String?
    ) throws -> URLRequest {
        var request = try request(
            ip: ip,
            path: "/api/v1/households/\(pathSegment(householdId))/groups/createGroup")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["playerIds": playerIds]
        if !areaIds.isEmpty {
            body["areaIds"] = areaIds
        }
        if let musicContextGroupId,
           !musicContextGroupId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["musicContextGroupId"] = musicContextGroupId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    nonisolated static func decodePlayerInfo(_ data: Data) throws -> PlayerInfo {
        try JSONDecoder().decode(PlayerInfo.self, from: data)
    }

    nonisolated static func decodePlaybackMetadata(_ data: Data) throws -> SonosCloudAPI.CloudPlaybackMetadata {
        try JSONDecoder().decode(SonosCloudAPI.CloudPlaybackMetadata.self, from: data)
    }

    nonisolated static func decodeAreas(_ data: Data) throws -> AreasResponse {
        try JSONDecoder().decode(AreasResponse.self, from: data)
    }

    private nonisolated static func request(ip: String, path: String) throws -> URLRequest {
        guard let url = URL(string: "https://\(hostLiteral(ip)):\(port)\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-Sonos-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private nonisolated static func data(for request: URLRequest) async throws -> Data {
        let auditStartedAt = Date()
        let endpoint = request.url?.path ?? "unknown"
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200 ... 299).contains(status) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                SonosLog.error(.sonosCloud, "local control \(endpoint) -> HTTP \(status): \(body.prefix(300))")
                throw SonosLocalControlError.httpStatus(status)
            }
            await SonosNetworkAudit.record(
                kind: .local1443,
                host: request.url?.host,
                target: endpoint,
                action: request.httpMethod ?? "GET",
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .http(status))
            return data
        } catch {
            await SonosNetworkAudit.record(
                kind: .local1443,
                host: request.url?.host,
                target: endpoint,
                action: request.httpMethod ?? "GET",
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .failure(error))
            throw error
        }
    }

    private nonisolated static func hostLiteral(_ ip: String) -> String {
        if ip.contains(":") {
            let withoutZone = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
            return "[\(withoutZone)]"
        }
        return ip
    }

    private nonisolated static func pathSegment(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#[\\]@!$&'()*+,;="))
            .union(CharacterSet(charactersIn: ":"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum SonosLocalControlError: Error, Equatable {
    case missingGroupId
    case httpStatus(Int)
}

private final class SonosLocalControlSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        if host.isLocalSonosControlHost || SecTrustEvaluateWithError(serverTrust, nil) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private extension String {
    var isLocalSonosControlHost: Bool {
        let lower = lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") { return true }
        if lower.hasPrefix("192.168.") || lower.hasPrefix("10.") || lower.hasPrefix("169.254.") { return true }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16 ... 31).contains(second) {
                return true
            }
        }
        if lower == "::1" || lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            return true
        }
        return false
    }
}
