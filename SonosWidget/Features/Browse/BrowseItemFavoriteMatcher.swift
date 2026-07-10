import Foundation

struct BrowseItemFavoriteMatcher: Sendable {
    let cloudToLocalSid: [String: Int]
    let musicServices: [MusicService]

    func serviceSignature(for item: BrowseItem) -> String? {
        if let sid = item.serviceId { return "sid:\(sid)" }

        if let uri = item.playbackDescriptor.directURI,
           let query = uri.split(separator: "?").last {
            for param in query.split(separator: "&") {
                let pair = param.split(separator: "=", maxSplits: 1)
                if pair.count == 2, pair[0] == "sid", let sid = Int(pair[1]) {
                    return "sid:\(sid)"
                }
            }
        }

        for blob in [item.resMD, item.metaXML].compactMap({ $0 }) {
            guard let range = blob.range(of: "SA_RINCON") else { continue }
            let digits = String(blob[range.upperBound...].prefix { $0.isNumber })
            guard !digits.isEmpty else { continue }

            if let canonical = canonicalLocalSid(forCloudOrServiceTypeDigits: digits) {
                return "sid:\(canonical)"
            }

            return "rincon:\(digits)"
        }

        if let resMD = item.resMD, let idRange = resMD.range(of: "id=\"") {
            let digits = String(resMD[idRange.upperBound...].prefix { $0.isNumber })
            if digits.count >= 6 {
                let suffixes = [digits.dropFirst(2), digits.dropFirst(3), digits.dropFirst(4)]
                for suffix in suffixes {
                    if let canonical = canonicalLocalSid(
                        forCloudOrServiceTypeDigits: String(suffix)
                    ) {
                        return "sid:\(canonical)"
                    }
                }
                return "prefix:\(digits)"
            }
        }

        return nil
    }

    func favorite(matching item: BrowseItem, in favorites: [BrowseItem]) -> BrowseItem? {
        let itemSignature = serviceSignature(for: item)

        let signatureMatches: (BrowseItem) -> Bool = { favorite in
            guard let itemSignature, let favoriteSignature = serviceSignature(for: favorite) else {
                return true
            }
            return itemSignature == favoriteSignature
        }

        if let uri = item.playbackDescriptor.directURI {
            let normalizedURI = normalizedURIPath(uri)
            if let match = favorites.first(where: { favorite in
                guard signatureMatches(favorite),
                      let favoriteURI = favorite.playbackDescriptor.directURI else {
                    return false
                }
                return normalizedURIPath(favoriteURI) == normalizedURI
            }) {
                return match
            }
        }

        return favorites.first {
            signatureMatches($0) && $0.title == item.title && $0.artist == item.artist
        }
    }

    private func normalizedURIPath(_ uri: String) -> String {
        uri.split(separator: "?").first.map(String.init) ?? uri
    }

    private func canonicalLocalSid(forCloudOrServiceTypeDigits digits: String) -> Int? {
        if let localSid = cloudToLocalSid[digits] { return localSid }
        if let match = musicServices.first(where: { $0.serviceType == digits }) {
            return match.id
        }
        return nil
    }
}
