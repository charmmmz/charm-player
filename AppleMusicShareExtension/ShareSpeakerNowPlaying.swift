import Foundation

struct ShareSpeakerNowPlaying: Equatable, Sendable {
    private static let sonosPort = 1400

    let title: String
    let artist: String?
    let albumArtURLString: String?

    init?(title: String, artist: String?, albumArtURLString: String? = nil) {
        guard let cleanTitle = Self.clean(title) else {
            return nil
        }
        self.title = cleanTitle
        self.artist = Self.clean(artist)
        self.albumArtURLString = Self.clean(albumArtURLString)
    }

    init?(positionInfoXML xml: String, speakerIP: String? = nil) {
        let trackURI = Self.decodeXMLEntities(Self.extractTag("TrackURI", from: xml) ?? "")
        let inputSourceFallback = Self.inputSourceFallback(fromTrackURI: trackURI)

        guard let rawMetadata = Self.extractTag("TrackMetaData", from: xml) else {
            if let inputSourceFallback {
                self.init(title: inputSourceFallback.title, artist: inputSourceFallback.artist)
                return
            }
            return nil
        }

        let metadata = Self.decodeXMLEntities(rawMetadata)
        var title = Self.decodeXMLEntities(Self.extractTag("dc:title", from: metadata) ?? "")
        var artist = Self.decodeXMLEntities(
            Self.extractTag("dc:creator", from: metadata)
                ?? Self.extractTag("upnp:artist", from: metadata)
                ?? ""
        )

        if let streamContent = Self.extractTag("r:streamContent", from: metadata), !streamContent.isEmpty {
            Self.applyStreamContent(streamContent, title: &title, artist: &artist)
        }

        if Self.clean(title) == nil, let inputSourceFallback {
            self.init(title: inputSourceFallback.title, artist: inputSourceFallback.artist)
            return
        }

        self.init(
            title: title,
            artist: artist,
            albumArtURLString: Self.albumArtURLString(from: metadata, speakerIP: speakerIP)
        )
    }

    var displayText: String {
        if let artist {
            return "\(title) - \(artist)"
        }
        return title
    }

    private static func inputSourceFallback(fromTrackURI trackURI: String) -> (title: String, artist: String?)? {
        let uri = trackURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !uri.isEmpty else { return nil }

        if uri.hasPrefix("x-sonos-htastream:") {
            return ("TV Audio", "HDMI")
        }
        if uri.hasPrefix("x-rincon-stream:") {
            return ("Line-In", nil)
        }
        if uri.hasPrefix("x-sonos-vli:"), uri.contains(",airplay:") {
            return ("AirPlay", nil)
        }

        return nil
    }

    private static func applyStreamContent(
        _ streamContent: String,
        title: inout String,
        artist: inout String
    ) {
        let decoded = decodeXMLEntities(streamContent)
        if decoded.contains("TITLE ") || decoded.contains("ARTIST ") {
            var fields: [String: String] = [:]
            for segment in decoded.split(separator: "|") {
                let text = String(segment)
                for key in ["TITLE ", "ARTIST "] where text.hasPrefix(key) {
                    fields[key.trimmingCharacters(in: .whitespaces)] = String(text.dropFirst(key.count))
                }
            }
            if let streamTitle = fields["TITLE"], !streamTitle.isEmpty {
                title = streamTitle
            }
            if let streamArtist = fields["ARTIST"], !streamArtist.isEmpty {
                artist = streamArtist
            }
        } else if decoded.contains(" - ") {
            let parts = decoded.split(separator: " - ", maxSplits: 1)
            if parts.count == 2 {
                artist = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                title = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if clean(title) == nil {
            title = decoded
        }
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sentinels = ["UNKNOWN", "NOT_IMPLEMENTED"]
        guard !sentinels.contains(trimmed.uppercased()) else { return nil }
        return trimmed
    }

    private static func albumArtURLString(from metadata: String, speakerIP: String?) -> String? {
        guard let raw = extractTag("upnp:albumArtURI", from: metadata)
            ?? extractTag("albumArtURI", from: metadata) else {
            return nil
        }

        var decoded = decodeXMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }

        if decoded.contains("%25") {
            decoded = decoded.removingPercentEncoding ?? decoded
        }
        if decoded.hasPrefix("http://") || decoded.hasPrefix("https://") {
            return decoded
        }
        guard let speakerIP, !speakerIP.isEmpty else {
            return decoded
        }

        let host = speakerIP.contains(":")
            ? "[\(speakerIP.split(separator: "%").first ?? Substring(speakerIP))]"
            : speakerIP
        let path = decoded.hasPrefix("/") ? decoded : "/\(decoded)"
        return "http://\(host):\(sonosPort)\(path)"
    }

    private static func extractTag(_ tag: String, from xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escaped)(?:\\s[^>]*)?>(.*?)</\(escaped)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private static func decodeXMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
