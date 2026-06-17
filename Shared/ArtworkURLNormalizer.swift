import Foundation

nonisolated enum ArtworkURLNormalizer {
    static func loadableURLString(
        from value: String?,
        shortSidePixels: Int? = nil,
        speakerIP: String? = nil,
        sonosPort: Int = 1400
    ) -> String? {
        loadableURL(
            from: value,
            shortSidePixels: shortSidePixels,
            speakerIP: speakerIP,
            sonosPort: sonosPort
        )?.absoluteString
    }

    static func loadableURL(
        from value: String?,
        shortSidePixels: Int? = nil,
        speakerIP: String? = nil,
        sonosPort: Int = 1400
    ) -> URL? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                guard isLoadableArtworkURLString(url.absoluteString) else { return nil }
                return resizedAppleArtworkURL(url, shortSidePixels: shortSidePixels)
            case "musickit":
                guard let artworkURL = appleArtworkURL(fromMusicKitArtworkURL: url),
                      isLoadableArtworkURLString(artworkURL.absoluteString) else {
                    return nil
                }
                return resizedAppleArtworkURL(artworkURL, shortSidePixels: shortSidePixels)
            default:
                return nil
            }
        }

        return sonosArtworkURL(fromRelativePath: trimmed, speakerIP: speakerIP, port: sonosPort)
    }

    static func isLoadableArtworkURLString(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return false
        }
        return !value.contains("{") && !value.contains("}")
    }

    static func artworkCacheKey(from value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host else {
            return nil
        }

        components.scheme = scheme.lowercased()
        components.host = host.lowercased()
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func sonosArtworkURL(fromRelativePath value: String, speakerIP: String?, port: Int) -> URL? {
        let trimmedSpeakerIP = speakerIP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedSpeakerIP.isEmpty,
              value.hasPrefix("/"),
              !value.hasPrefix("//"),
              !value.contains("..") else {
            return nil
        }

        return URL(string: "http://\(trimmedSpeakerIP):\(port)\(value)")
    }

    private static func appleArtworkURL(fromMusicKitArtworkURL url: URL) -> URL? {
        guard url.scheme?.lowercased() == "musickit",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let artworkURLString = components.queryItems?.first(where: {
                  $0.name.lowercased() == "aat"
              })?.value else {
            return nil
        }

        let trimmed = artworkURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let artworkURL = URL(string: trimmed),
           isLoadableArtworkURLString(artworkURL.absoluteString) {
            return artworkURL
        }

        guard let artworkURL = appleArtworkURL(fromRelativeArtworkPath: trimmed),
              isLoadableArtworkURLString(artworkURL.absoluteString) else {
            return nil
        }
        return artworkURL
    }

    private static func appleArtworkURL(fromRelativeArtworkPath value: String) -> URL? {
        var path = (value.removingPercentEncoding ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty,
              !path.contains(".."),
              !path.localizedCaseInsensitiveContains("://") else {
            return nil
        }

        if path.hasPrefix("image/thumb/") {
            path.removeFirst("image/thumb/".count)
        }

        guard path.split(separator: "/").count > 1,
              path.range(
                  of: #"(?:\.(?:jpg|jpeg|png|webp)|/\d+x\d+bb(?:\.[a-z0-9]+)?)$"#,
                  options: [.regularExpression, .caseInsensitive]
              ) != nil else {
            return nil
        }

        if path.range(of: #"/\d+x\d+bb(\.[^/]+)?$"#, options: .regularExpression) == nil {
            path += "/600x600bb.jpg"
        }

        let fullPath = "/image/thumb/\(path)"
        guard let encodedPath = fullPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "is1-ssl.mzstatic.com"
        components.percentEncodedPath = encodedPath
        return components.url
    }

    private static func resizedAppleArtworkURL(_ url: URL, shortSidePixels: Int?) -> URL {
        guard let shortSidePixels, shortSidePixels > 0,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var path = components.percentEncodedPath
        guard let range = path.range(
            of: #"/\d+x\d+bb(\.[^/]+)?$"#,
            options: .regularExpression
        ) else {
            return url
        }

        let matchedComponent = String(path[range])
        let suffix: String
        if let dotIndex = matchedComponent.lastIndex(of: ".") {
            suffix = String(matchedComponent[dotIndex...])
        } else {
            suffix = ""
        }
        path.replaceSubrange(range, with: "/\(shortSidePixels)x\(shortSidePixels)bb\(suffix)")
        components.percentEncodedPath = path
        return components.url ?? url
    }
}
