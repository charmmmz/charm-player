import Foundation

@available(iOS 27.0, iOSApplicationExtension 27.0, *)
enum SonosRemoteMediaSessionRelayClient {
    enum TokenKind: String, Encodable, Sendable {
        case start
        case update
    }

    private struct RegistrationBody: Encodable, Sendable {
        let kind: TokenKind
        let groupId: String
        let token: String
        let sessionId: String
        let sessionGeneration: String?
        let clientId: String
        let speakerName: String
        let relayURLString: String
        let requestStart: Bool?
    }

    private struct DiagnosticBody: Encodable, Sendable {
        struct Entry: Encodable, Sendable {
            let category: String
            let level: String
            let message: String
        }

        let clientId: String
        let bundleId: String
        let processName: String
        let entries: [Entry]
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    static func register(
        token: Data,
        kind: TokenKind,
        attributes: SonosRemoteMediaSessionAttributes,
        requestStart: Bool = false
    ) async throws {
        guard let relayURLString = attributes.relayURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !relayURLString.isEmpty,
              let baseURL = URL(string: relayURLString) else {
            throw URLError(.badURL)
        }

        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("now-playing")
            .appendingPathComponent("register")
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RegistrationBody(
                kind: kind,
                groupId: attributes.groupID,
                token: token.hexString,
                sessionId: attributes.id,
                sessionGeneration: attributes.sessionGeneration,
                clientId: attributes.clientID,
                speakerName: attributes.speakerName,
                relayURLString: relayURLString,
                requestStart: kind == .start ? requestStart : nil
            )
        )
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    static func report(
        category: String = "NowPlayingArtwork",
        level: String,
        message: String,
        attributes: SonosRemoteMediaSessionAttributes
    ) async {
        guard let relayURLString = attributes.relayURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !relayURLString.isEmpty,
              let baseURL = URL(string: relayURLString) else { return }

        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("device-logs")
        var request = URLRequest(url: endpoint, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(
            DiagnosticBody(
                clientId: attributes.clientID,
                bundleId: "com.charm.SonosWidget.RemoteMediaSessionExtension",
                processName: "RemoteMediaSessionExtension",
                entries: [
                    .init(category: category, level: level, message: message)
                ]
            )
        )
        _ = try? await session.data(for: request)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
