import Foundation

enum DetailArtworkURLSelection {
    static func firstAvailable(
        entryArtworkURL: String?,
        responseArtworkURL: String?,
        fallbackArtworkURL: String? = nil
    ) -> String? {
        [entryArtworkURL, responseArtworkURL, fallbackArtworkURL]
            .lazy
            .compactMap { normalized($0) }
            .first
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
