import Foundation
import Darwin

@MainActor
final class RelayDiscovery: NSObject {
    nonisolated static let bonjourType = "_charmrelay._tcp"
    private nonisolated static let netServiceType = "_charmrelay._tcp."

    var onCandidate: ((URL) -> Void)?
    var onEvent: ((String) -> Void)?

    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
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

    nonisolated static func resolvedRelayURLs(
        hostName: String?,
        addresses: [Data],
        port: Int
    ) -> [URL] {
        var urls: [URL] = []
        var seen: Set<URL> = []

        for host in addresses.compactMap(numericHost(from:)) {
            guard let url = relayURL(host: host, port: port),
                  seen.insert(url).inserted
            else { continue }
            urls.append(url)
        }

        if let hostName,
           let url = relayURL(host: hostName, port: port),
           seen.insert(url).inserted {
            urls.append(url)
        }

        return urls
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

    private nonisolated static func numericHost(from address: Data) -> String? {
        address.withUnsafeBytes { rawBuffer -> String? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let socketAddress = baseAddress.assumingMemoryBound(to: sockaddr.self)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(address.count),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { return nil }
            return String(cString: host)
        }
    }

    func start() {
        guard browser == nil else {
            record("bonjour search already running")
            return
        }

        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        record("starting bonjour search type=\(Self.netServiceType) domain=local.")
        browser.searchForServices(ofType: Self.netServiceType, inDomain: "local.")
    }

    func stop() {
        record("stopping bonjour search services=\(services.count)")
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for service in services {
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
    }

    private func emitCandidate(_ url: URL) {
        guard seenURLs.insert(url).inserted else {
            record("duplicate candidate ignored url=\(url.absoluteString)")
            return
        }
        record("candidate url=\(url.absoluteString)")
        onCandidate?(url)
    }

    private func record(_ message: String) {
        let line = "relay-discovery \(message)"
        SonosLog.info(.relay, line)
        onEvent?(message)
    }
}

extension RelayDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        record("bonjour browser will search")
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        record(
            "found service name='\(service.name)' type=\(service.type) " +
            "domain=\(service.domain) moreComing=\(moreComing)"
        )
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let urls = Self.resolvedRelayURLs(
            hostName: sender.hostName,
            addresses: sender.addresses ?? [],
            port: sender.port
        )
        let addressHosts = (sender.addresses ?? []).compactMap(Self.numericHost(from:))
        record(
            "resolved service name='\(sender.name)' host=\(sender.hostName ?? "nil") " +
            "port=\(sender.port) addresses=\(addressHosts.joined(separator: ",")) " +
            "urls=\(urls.map(\.absoluteString).joined(separator: ","))"
        )
        for url in urls {
            emitCandidate(url)
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        record("bonjour browser did not search error=\(errorDict)")
        stop()
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        record("service did not resolve name='\(sender.name)' error=\(errorDict)")
        sender.stop()
    }
}
