import Foundation

enum SonosAlbumBrowseID {
    static func from(_ rawID: String) -> String {
        let decoded = rawID.removingPercentEncoding ?? rawID
        let base = decoded.firstIndex(of: "#").map { String(decoded[..<$0]) } ?? decoded
        let normalized = stripKnownContainerPrefix(from: base.trimmingCharacters(in: .whitespacesAndNewlines))
        let parts = normalized.components(separatedBy: ":")

        guard let albumIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("album") == .orderedSame }),
              albumIndex < parts.index(before: parts.endIndex) else {
            return normalized
        }
        return parts[albumIndex...].joined(separator: ":")
    }

    static func concreteAlbumID(from rawID: String?) -> String? {
        guard let rawID else { return nil }
        let normalized = from(rawID)
        let parts = normalized.components(separatedBy: ":")
        guard parts.count >= 2,
              parts[0].caseInsensitiveCompare("album") == .orderedSame,
              !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return normalized
    }

    private static func stripKnownContainerPrefix(from value: String) -> String {
        let lowercased = value.lowercased()
        let prefix = "1004206c"
        guard lowercased.hasPrefix(prefix) else { return value }
        return String(value.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
