import CryptoKit
import Foundation

@available(iOSApplicationExtension 27.0, *)
actor SonosRemoteAnimatedArtworkCache {
    static let shared = SonosRemoteAnimatedArtworkCache()

    private enum CacheError: LocalizedError {
        case invalidPlaylist
        case noCompatibleVariant
        case unsupportedMediaPlaylist
        case invalidResponse
        case invalidVideoFile
        case videoTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidPlaylist:
                "The animated artwork playlist is invalid."
            case .noCompatibleVariant:
                "The animated artwork has no compatible square video variant."
            case .unsupportedMediaPlaylist:
                "The animated artwork playlist does not expose one downloadable MP4 file."
            case .invalidResponse:
                "The animated artwork server returned an invalid response."
            case .invalidVideoFile:
                "The downloaded animated artwork is not a valid MP4 file."
            case .videoTooLarge:
                "The animated artwork video is too large."
            }
        }
    }

    private struct Variant {
        let url: URL
        let width: Int
        let height: Int
        let codecs: String

        var shortSide: Int { min(width, height) }
        var isSquare: Bool {
            guard width > 0, height > 0 else { return false }
            return abs(Double(width) / Double(height) - 1) < 0.03
        }
        var isAVC: Bool { codecs.localizedCaseInsensitiveContains("avc1") }
    }

    private static let maximumVideoBytes: Int64 = 80 * 1_024 * 1_024
    private let session: URLSession
    private var inFlight: [String: Task<URL, Error>] = [:]

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 28
        session = URLSession(configuration: configuration)
    }

    func videoURL(for playlistURL: URL, requestedSize: CGSize) async throws -> URL {
        let key = cacheKey(for: playlistURL)
        let destination = try cacheDirectory()
            .appendingPathComponent(key, isDirectory: false)
            .appendingPathExtension("mp4")

        if isValidCachedVideo(destination) {
            return destination
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task<URL, Error> {
            let videoURL = try await resolveVideoFileURL(
                from: playlistURL,
                requestedSize: requestedSize
            )
            return try await downloadVideo(from: videoURL, to: destination)
        }
        inFlight[key] = task
        do {
            let result = try await task.value
            inFlight[key] = nil
            pruneCache(keeping: result)
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    private func resolveVideoFileURL(
        from masterURL: URL,
        requestedSize: CGSize
    ) async throws -> URL {
        let master = try await text(from: masterURL)
        let variants = Self.variants(in: master, relativeTo: masterURL)
        let mediaPlaylistURL: URL
        if variants.isEmpty {
            mediaPlaylistURL = masterURL
        } else {
            guard let variant = Self.preferredVariant(variants, requestedSize: requestedSize) else {
                throw CacheError.noCompatibleVariant
            }
            mediaPlaylistURL = variant.url
        }

        let mediaPlaylist = mediaPlaylistURL == masterURL
            ? master
            : try await text(from: mediaPlaylistURL)
        guard let result = Self.singleMediaFileURL(
            in: mediaPlaylist,
            relativeTo: mediaPlaylistURL
        ) else {
            throw CacheError.unsupportedMediaPlaylist
        }
        return result
    }

    private func text(from url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw CacheError.invalidResponse
        }
        return text
    }

    private func downloadVideo(from source: URL, to destination: URL) async throws -> URL {
        // The selected rendition is normally around 1-2 MB. Persist the bytes
        // atomically from this cache task instead of returning a framework
        // temporary download that can disappear when the system re-enters the
        // artwork provider while expanding Now Playing.
        let (data, response) = try await session.data(from: source)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw CacheError.invalidResponse
        }
        if http.expectedContentLength > Self.maximumVideoBytes {
            throw CacheError.videoTooLarge
        }

        guard data.count > 1_024,
              Int64(data.count) <= Self.maximumVideoBytes,
              Self.hasMP4Signature(data) else {
            throw CacheError.invalidVideoFile
        }

        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func cacheDirectory() throws -> URL {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw CacheError.invalidVideoFile
        }
        let directory = caches.appendingPathComponent(
            "RemoteAnimatedArtwork",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func isValidCachedVideo(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 1_024 else {
            return false
        }
        return Self.hasMP4Signature(url)
    }

    private func pruneCache(keeping currentURL: URL) {
        guard let directory = try? cacheDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }
        let sorted = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left > right
        }
        for file in sorted.dropFirst(12) where file != currentURL {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func preferredVariant(
        _ variants: [Variant],
        requestedSize: CGSize
    ) -> Variant? {
        let square = variants.filter(\.isSquare)
        guard !square.isEmpty else { return nil }
        let avc = square.filter(\.isAVC)
        let compatible = avc.isEmpty ? square : avc
        // A remote-media extension only gets a short execution window while
        // the system expands Now Playing. Prefer Apple's compact square AVC
        // rendition so the local file is ready before the extension suspends.
        // The 960px rendition is several times larger and can be restarted on
        // every expansion if suspension interrupts its first download.
        let target = min(max(Int(max(requestedSize.width, requestedSize.height)), 360), 486)
        let ordered = compatible.sorted { $0.shortSide < $1.shortSide }
        return ordered.first(where: { $0.shortSide >= target }) ?? ordered.last
    }

    private static func variants(in playlist: String, relativeTo baseURL: URL) -> [Variant] {
        let lines = playlist.components(separatedBy: .newlines)
        var result: [Variant] = []
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:"),
                  let resolution = capture(#"RESOLUTION=(\d+)x(\d+)"#, in: line),
                  resolution.count == 2,
                  let width = Int(resolution[0]),
                  let height = Int(resolution[1]),
                  let uri = nextURI(after: index, in: lines),
                  let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
                continue
            }
            let codecs = capture(#"CODECS=\"([^\"]+)\""#, in: line)?.first ?? ""
            result.append(
                Variant(url: url, width: width, height: height, codecs: codecs)
            )
        }
        return result
    }

    private static func singleMediaFileURL(
        in playlist: String,
        relativeTo baseURL: URL
    ) -> URL? {
        let lines = playlist.components(separatedBy: .newlines)
        var candidates: [URL] = []
        for lineValue in lines {
            let line = lineValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MAP:"),
               let uri = capture(#"URI=\"([^\"]+)\""#, in: line)?.first,
               let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                candidates.append(url)
            } else if !line.isEmpty,
                      !line.hasPrefix("#"),
                      let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                candidates.append(url)
            }
        }
        guard let first = candidates.first,
              candidates.allSatisfy({ $0 == first }),
              ["mp4", "m4v"].contains(first.pathExtension.lowercased()) else {
            return nil
        }
        return first
    }

    private static func nextURI(after index: Int, in lines: [String]) -> String? {
        guard index < lines.index(before: lines.endIndex) else { return nil }
        for candidateIndex in lines.index(after: index)..<lines.endIndex {
            let value = lines[candidateIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            if value.hasPrefix("#") { return nil }
            return value
        }
        return nil
    }

    private static func capture(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func hasMP4Signature(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 12),
              data.count >= 8 else {
            return false
        }
        return String(data: data[4..<8], encoding: .ascii) == "ftyp"
    }

    private static func hasMP4Signature(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data[4..<8] == Data("ftyp".utf8)
    }

}
