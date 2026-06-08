import Foundation

enum ShareSonosAPI {
    private static let port = 1400
    private static let avTransport = "/MediaRenderer/AVTransport/Control"
    private static let zoneGroupTopology = "/ZoneGroupTopology/Control"

    static func play(ip: String) async throws {
        _ = try await soap(
            ip: ip,
            endpoint: avTransport,
            service: "AVTransport",
            action: "Play",
            body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    @discardableResult
    static func addURIToQueue(
        ip: String,
        uri: String,
        metadata: String,
        position: Int = 0
    ) async throws -> Int {
        let xml = try await soap(
            ip: ip,
            endpoint: avTransport,
            service: "AVTransport",
            action: "AddURIToQueue",
            body: "<InstanceID>0</InstanceID>" +
                "<EnqueuedURI>\(escapeXML(uri))</EnqueuedURI>" +
                "<EnqueuedURIMetaData>\(escapeXML(metadata))</EnqueuedURIMetaData>" +
                "<DesiredFirstTrackNumberEnqueued>\(position)</DesiredFirstTrackNumberEnqueued>" +
                "<EnqueueAsNext>0</EnqueueAsNext>")
        return Int(extractTag("FirstTrackNumberEnqueued", from: xml) ?? "1") ?? 1
    }

    static func removeAllTracksFromQueue(ip: String) async throws {
        _ = try await soap(
            ip: ip,
            endpoint: avTransport,
            service: "AVTransport",
            action: "RemoveAllTracksFromQueue",
            body: "<InstanceID>0</InstanceID>")
    }

    static func seekToTrack(ip: String, trackNumber: Int) async throws {
        _ = try await soap(
            ip: ip,
            endpoint: avTransport,
            service: "AVTransport",
            action: "Seek",
            body: "<InstanceID>0</InstanceID><Unit>TRACK_NR</Unit><Target>\(trackNumber)</Target>")
    }

    static func setAVTransportToQueue(ip: String, speakerUUID: String) async throws {
        _ = try await soap(
            ip: ip,
            endpoint: avTransport,
            service: "AVTransport",
            action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID>" +
                "<CurrentURI>x-rincon-queue:\(escapeXML(speakerUUID))#0</CurrentURI>" +
                "<CurrentURIMetaData></CurrentURIMetaData>")
    }

    static func getZoneGroupState(ip: String) async throws -> [ShareSpeaker] {
        let xml = try await soap(
            ip: ip,
            endpoint: zoneGroupTopology,
            service: "ZoneGroupTopology",
            action: "GetZoneGroupState",
            body: "")
        guard let raw = extractTag("ZoneGroupState", from: xml) else { return [] }
        let decoded = decodeXMLEntities(raw)
        let grouped = parseZoneGroups(decoded)
        return grouped.isEmpty ? parseZoneMembersFlat(decoded) : grouped
    }

    private static func soap(
        ip: String,
        endpoint: String,
        service: String,
        action: String,
        body: String
    ) async throws -> String {
        let cleanIP = ip.contains(":") ? "[\(ip.split(separator: "%").first ?? Substring(ip))]" : ip
        guard let url = URL(string: "http://\(cleanIP):\(port)\(endpoint)") else {
            throw URLError(.badURL)
        }

        let longActions: Set<String> = [
            "RemoveAllTracksFromQueue",
            "AddURIToQueue",
            "SetAVTransportURI",
            "Play"
        ]
        var request = URLRequest(
            url: url,
            timeoutInterval: longActions.contains(action) ? 30 : 10
        )
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:\(service):1#\(action)\"",
            forHTTPHeaderField: "SOAPACTION"
        )
        request.httpBody = envelope(service: service, action: action, body: body).data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = String(data: data, encoding: .utf8) ?? ""
        if response.contains("<s:Fault>") || response.contains("UPnPError") {
            let code = extractTag("errorCode", from: response) ?? "?"
            let desc = extractTag("errorDescription", from: response) ?? "SOAP Fault"
            throw SharePlaybackError.playbackFailed("\(action) failed: \(desc) (code \(code))")
        }
        return response
    }

    private static func envelope(service: String, action: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\
        \(body)</u:\(action)></s:Body></s:Envelope>
        """
    }

    static func extractTag(_ tag: String, from xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escaped)(?:\\s[^>]*)?>(.*?)</\(escaped)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    static func decodeXMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    static func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func attr(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    private static func parseZoneGroups(_ xml: String) -> [ShareSpeaker] {
        let groupPattern = "<ZoneGroup\\s[^>]*Coordinator=\"([^\"]*)\"[^>]*ID=\"([^\"]*)\"[^>]*>(.*?)</ZoneGroup>"
        guard let groupRegex = try? NSRegularExpression(pattern: groupPattern, options: .dotMatchesLineSeparators) else {
            return []
        }
        let groupMatches = groupRegex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        var players: [ShareSpeaker] = []
        for groupMatch in groupMatches {
            guard let coordinatorRange = Range(groupMatch.range(at: 1), in: xml),
                  let groupIDRange = Range(groupMatch.range(at: 2), in: xml),
                  let bodyRange = Range(groupMatch.range(at: 3), in: xml) else {
                continue
            }

            let coordinatorID = String(xml[coordinatorRange])
            let groupID = String(xml[groupIDRange])
            let body = String(xml[bodyRange])

            var members: [(uuid: String, name: String, ip: String, invisible: Bool)] = []
            var coordinatorIP: String?

            let memberPattern = "<ZoneGroupMember[^>]*?(?:/>|>)"
            guard let memberRegex = try? NSRegularExpression(pattern: memberPattern, options: .dotMatchesLineSeparators) else {
                continue
            }
            for memberMatch in memberRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let range = Range(memberMatch.range, in: body) else { continue }
                let tag = String(body[range])
                let uuid = attr("UUID", in: tag) ?? UUID().uuidString
                let name = attr("ZoneName", in: tag) ?? "Unknown"
                let location = attr("Location", in: tag) ?? ""
                let invisible = attr("Invisible", in: tag) == "1"
                if let url = URL(string: location), let host = url.host {
                    members.append((uuid, name, host, invisible))
                    if uuid == coordinatorID {
                        coordinatorIP = host
                    }
                }
            }

            for member in members {
                let isCoordinator = member.uuid == coordinatorID
                players.append(ShareSpeaker(
                    id: member.uuid,
                    name: member.name,
                    ipAddress: member.ip,
                    isCoordinator: isCoordinator,
                    groupId: groupID,
                    coordinatorIP: isCoordinator ? nil : coordinatorIP,
                    isInvisible: member.invisible
                ))
            }
        }
        return players
    }

    private static func parseZoneMembersFlat(_ xml: String) -> [ShareSpeaker] {
        let patterns = ["<ZoneGroupMember[^/]*?/>", "<ZoneGroupMember[^>]*?>"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
                continue
            }

            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            var players: [ShareSpeaker] = []
            for match in matches {
                guard let range = Range(match.range, in: xml) else { continue }
                let tag = String(xml[range])
                let uuid = attr("UUID", in: tag) ?? UUID().uuidString
                let name = attr("ZoneName", in: tag) ?? "Unknown"
                let location = attr("Location", in: tag) ?? ""
                if let url = URL(string: location), let host = url.host {
                    players.append(ShareSpeaker(
                        id: uuid,
                        name: name,
                        ipAddress: host,
                        isCoordinator: true
                    ))
                }
            }
            if !players.isEmpty { return players }
        }
        return []
    }
}
