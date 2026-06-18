import Foundation
import Network

@MainActor
final class RelayDiscovery {
    nonisolated static let bonjourType = "_charmrelay._tcp"

    var onCandidate: ((URL) -> Void)?

    private var browser: NWBrowser?
    private var connections: [NWConnection] = []
    private var seenURLs: Set<URL> = []

    nonisolated static func preferredRelayURL(
        manualURLString: String?,
        discoveredURL: URL?
    ) -> URL? {
        let manual = manualURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !manual.isEmpty, let url = URL(string: manual) {
            return url
        }
        return discoveredURL
    }

    nonisolated static func relayURL(host: String, port: Int) -> URL? {
        let trimmedHost = normalizedBonjourHost(
            host.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmedHost.isEmpty, port > 0, port <= UInt16.max else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmedHost
        components.port = port
        return components.url
    }

    private nonisolated static func normalizedBonjourHost(_ host: String) -> String {
        let hostWithoutScope = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        let rootlessHost = hostWithoutScope.hasSuffix(".")
            ? String(hostWithoutScope.dropLast())
            : hostWithoutScope
        guard !rootlessHost.isEmpty else { return rootlessHost }
        if rootlessHost.contains(".") || rootlessHost.contains(":") {
            return rootlessHost
        }
        return "\(rootlessHost).local"
    }

    func start() {
        guard browser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(type: Self.bonjourType, domain: nil),
            using: .tcp
        )
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                if case .added(let result) = change {
                    Task { @MainActor in
                        self.resolve(result.endpoint)
                    }
                }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor [weak self] in self?.stop() }
            }
        }

        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func resolve(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .ready = state {
                Task { @MainActor [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.didResolve(connection)
                    connection.cancel()
                }
            } else if case .failed = state {
                connection?.cancel()
            }
        }

        connection.start(queue: .main)
    }

    private func didResolve(_ connection: NWConnection) {
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case .hostPort(let host, let port) = endpoint
        else { return }

        guard let url = Self.relayURL(host: "\(host)", port: Int(port.rawValue)),
              seenURLs.insert(url).inserted
        else { return }

        onCandidate?(url)
    }
}
