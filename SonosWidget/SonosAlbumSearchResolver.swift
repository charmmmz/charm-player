import Foundation

enum SonosAlbumSearchResolver {
    static func preferredAlbumID(
        in result: SonosCloudAPI.ServiceSearchResponse,
        title: String,
        artist: String
    ) -> String? {
        let targetTitle = normalizedText(title)
        guard !targetTitle.isEmpty else { return nil }

        let albums = result.allResources.filter {
            ($0.type ?? "").caseInsensitiveCompare("ALBUM") == .orderedSame
        }
        let titleMatches = albums.filter {
            normalizedText($0.name ?? "") == targetTitle
        }
        guard !titleMatches.isEmpty else { return nil }

        let targetArtist = normalizedText(artist)
        if !targetArtist.isEmpty {
            let artistMatches = titleMatches.filter {
                normalizedText($0.artists?.first?.name ?? "") == targetArtist
            }
            if let id = firstConcreteAlbumID(in: artistMatches) {
                return id
            }
        }

        return firstConcreteAlbumID(in: titleMatches)
    }

    private static func firstConcreteAlbumID(in resources: [SonosCloudAPI.CloudResource]) -> String? {
        resources.lazy.compactMap { resource in
            SonosAlbumBrowseID.concreteAlbumID(from: resource.id?.objectId)
        }.first
    }

    private static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
