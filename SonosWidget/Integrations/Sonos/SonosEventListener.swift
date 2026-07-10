import Darwin
import Foundation
import Network

enum SonosEventListenerError: Error, Equatable {
    case noLocalIPv4Address
    case missingListenerPort
    case noAvailableListenPort
    case badCallbackURL
}

final class SonosEventListener {
    typealias NotificationHandler = (SonosEventNotification) -> Void

    private let queue = DispatchQueue(label: "com.charm.SonosWidget.sonos-events")
    private let localAddressProvider: () -> String?
    private let notificationHandler: NotificationHandler
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    private nonisolated static let preferredListenPorts: [UInt16] = [
        1401, 3401, 3402, 3403, 3404, 3405, 3406, 3407, 3408, 3409, 3410
    ]

    private(set) var callbackURL: URL?

    init(localAddressProvider: @escaping () -> String? = SonosEventListener.localIPv4Address,
         notificationHandler: @escaping NotificationHandler) {
        self.localAddressProvider = localAddressProvider
        self.notificationHandler = notificationHandler
    }

    func start() throws -> URL {
        if let callbackURL {
            return callbackURL
        }
        guard let localAddress = localAddressProvider() else {
            throw SonosEventListenerError.noLocalIPv4Address
        }

        let (listener, port) = try Self.makeListener()
        guard let callbackURL = URL(string: "http://\(localAddress):\(port)/sonos/events") else {
            throw SonosEventListenerError.badCallbackURL
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                SonosLog.error(.sonosEvents, "listener failed: \(error)")
            case .ready:
                SonosLog.info(.sonosEvents, "listener ready at \(callbackURL.absoluteString)")
            default:
                break
            }
        }

        self.listener = listener
        self.callbackURL = callbackURL
        listener.start(queue: queue)
        return callbackURL
    }

    private nonisolated static func makeListener() throws -> (NWListener, UInt16) {
        for port in preferredListenPorts {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { continue }
            do {
                return (try NWListener(using: .tcp, on: nwPort), port)
            } catch {
                continue
            }
        }
        throw SonosEventListenerError.noAvailableListenPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        callbackURL = nil
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values {
                connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    private func handle(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, accumulated: Data())
    }

    private func receive(on connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = accumulated
            if let data {
                next.append(data)
            }

            if SonosEventHTTPParser.isCompleteRequest(next) {
                self.handleRequest(next, connection: connection, id: id)
                return
            }

            if let error {
                SonosLog.debug(.sonosEvents, "receive failed: \(error)")
                self.close(connection, id: id)
                return
            }

            if isComplete {
                self.close(connection, id: id)
                return
            }

            self.receive(on: connection, id: id, accumulated: next)
        }
    }

    private func handleRequest(_ data: Data, connection: NWConnection, id: UUID) {
        do {
            let notification = try SonosEventHTTPParser.notification(from: data)
            notificationHandler(notification)
        } catch {
            SonosLog.debug(.sonosEvents, "ignored event request: \(error)")
        }

        connection.send(content: SonosEventHTTPParser.okResponseData, completion: .contentProcessed { [weak self] _ in
            self?.close(connection, id: id)
        })
    }

    private func close(_ connection: NWConnection, id: UUID) {
        connections.removeValue(forKey: id)
        connection.cancel()
    }

    nonisolated static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }

        var fallback: String?
        var cursor = interfaces
        while let current = cursor {
            let interface = current.pointee
            defer { cursor = interface.ifa_next }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST)
            guard result == 0 else { continue }

            let ip = String(cString: host)
            let name = String(cString: interface.ifa_name)
            if name == "en0" {
                return ip
            }
            fallback = fallback ?? ip
        }

        return fallback
    }
}
