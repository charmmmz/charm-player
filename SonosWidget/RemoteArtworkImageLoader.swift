import Foundation
import SwiftUI
import UIKit

enum RemoteArtworkImageCacheKey {
    static func normalized(_ url: URL) -> String {
        ArtworkURLNormalizer.artworkCacheKey(from: url.absoluteString) ?? url.absoluteString
    }
}

enum RemoteArtworkImagePlaceholderState: Equatable {
    case loading
    case failure
}

struct RemoteArtworkImageView<Placeholder: View>: View {
    let url: URL
    let contentMode: LocalMusicArtworkURL.ContentMode
    let diagnosticLabel: String?
    let failureLogPrefix: String
    @ViewBuilder let placeholder: (RemoteArtworkImagePlaceholderState) -> Placeholder

    @State private var image: UIImage?
    @State private var failure: Error?
    @State private var didLogFailure = false

    init(
        url: URL,
        contentMode: LocalMusicArtworkURL.ContentMode = .fit,
        diagnosticLabel: String? = nil,
        failureLogPrefix: String = "Remote artwork image failed",
        @ViewBuilder placeholder: @escaping (RemoteArtworkImagePlaceholderState) -> Placeholder
    ) {
        self.url = url
        self.contentMode = contentMode
        self.diagnosticLabel = diagnosticLabel
        self.failureLogPrefix = failureLogPrefix
        self.placeholder = placeholder
    }

    private var taskIdentity: String {
        RemoteArtworkImageCacheKey.normalized(url)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode.swiftUIContentMode)
            } else if failure != nil {
                placeholder(.failure)
            } else {
                placeholder(.loading)
            }
        }
        .task(id: taskIdentity) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        let loader = RemoteArtworkImageLoader.shared
        if let cached = loader.cachedImage(for: url) {
            image = cached
            failure = nil
            return
        }

        image = nil
        failure = nil
        didLogFailure = false

        do {
            let loadedImage = try await loader.image(for: url)
            guard !Task.isCancelled else { return }
            image = loadedImage
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            image = nil
            failure = error
            logFailureIfNeeded(error)
        }
    }

    private func logFailureIfNeeded(_ error: Error) {
        guard !didLogFailure,
              let diagnosticLabel else {
            return
        }
        didLogFailure = true
        SonosLog.error(
            .localService,
            "\(failureLogPrefix) \(diagnosticLabel) url='\(url.absoluteString)' error=\(error)")
    }
}

private extension LocalMusicArtworkURL.ContentMode {
    var swiftUIContentMode: ContentMode {
        switch self {
        case .fit: return .fit
        case .fill: return .fill
        }
    }
}

enum RemoteArtworkImageLoaderError: Error, Equatable {
    case httpStatus(Int)
    case invalidImageData
}

@MainActor
final class RemoteArtworkImageLoader {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = RemoteArtworkImageLoader()

    private struct LoadResult {
        let image: UIImage
        let cost: Int
    }

    private let fetch: Fetch
    private let memoryCache: NSCache<NSString, UIImage>
    private var inFlightLoads: [String: Task<LoadResult, Error>] = [:]

    init(
        memoryCache: NSCache<NSString, UIImage> = NSCache<NSString, UIImage>(),
        fetch: @escaping Fetch = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.memoryCache = memoryCache
        self.fetch = fetch
        self.memoryCache.totalCostLimit = 64 * 1024 * 1024
        self.memoryCache.countLimit = 512
    }

    func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: cacheKey(for: url))
    }

    func prefetch(
        urls: [URL],
        limit: Int = PlaybackArtworkPrewarmPolicy.defaultLimit,
        maxConcurrent: Int = 6
    ) async {
        guard limit > 0, maxConcurrent > 0 else { return }
        var seen = Set<String>()
        var duplicateCount = 0
        var memoryHitCount = 0
        var limitedCount = 0
        var ordered: [URL] = []

        for url in urls {
            let key = cacheKey(for: url) as String
            guard seen.insert(key).inserted else {
                duplicateCount += 1
                continue
            }
            guard memoryCache.object(forKey: key as NSString) == nil else {
                memoryHitCount += 1
                continue
            }
            guard ordered.count < limit else {
                limitedCount += 1
                continue
            }
            ordered.append(url)
        }

        SonosLog.debug(
            .playbackLink,
            "Remote artwork prefetch input=\(urls.count) scheduled=\(ordered.count) " +
                "duplicate=\(duplicateCount) memoryHit=\(memoryHitCount) limited=\(limitedCount) " +
                "limit=\(limit) maxConcurrent=\(maxConcurrent) " +
                "first=\(SonosLog.playbackLinkValue(ordered.first?.absoluteString, maxLength: 240))")

        guard !ordered.isEmpty else { return }

        var successCount = 0
        await withTaskGroup(of: Bool.self) { group in
            var index = 0

            func addNext() {
                guard index < ordered.count else { return }
                let url = ordered[index]
                index += 1
                group.addTask { [weak self] in
                    guard let self else { return false }
                    do {
                        _ = try await self.image(for: url)
                        return true
                    } catch {
                        SonosLog.debug(
                            .playbackLink,
                            "Remote artwork prefetch failed key=\(SonosLog.playbackLinkValue(RemoteArtworkImageCacheKey.normalized(url), maxLength: 240)) error=\(error)")
                        return false
                    }
                }
            }

            for _ in 0..<min(maxConcurrent, ordered.count) { addNext() }
            for await didLoad in group {
                if didLoad { successCount += 1 }
                addNext()
            }
        }
        SonosLog.debug(
            .playbackLink,
            "Remote artwork prefetch finished scheduled=\(ordered.count) success=\(successCount) failed=\(ordered.count - successCount)")
    }

    func image(for url: URL) async throws -> UIImage {
        let key = cacheKey(for: url)
        if let cached = memoryCache.object(forKey: key) {
            SonosLog.debug(
                .playbackLink,
                "Remote artwork cache hit key=\(SonosLog.playbackLinkValue(key as String, maxLength: 240))")
            return cached
        }
        if let inFlight = inFlightLoads[key as String] {
            SonosLog.debug(
                .playbackLink,
                "Remote artwork joined in-flight key=\(SonosLog.playbackLinkValue(key as String, maxLength: 240))")
            return try await inFlight.value.image
        }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "GET"
        SonosLog.debug(
            .playbackLink,
            "Remote artwork fetch start key=\(SonosLog.playbackLinkValue(key as String, maxLength: 240))")

        let task = Task<LoadResult, Error> { [fetch] in
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw RemoteArtworkImageLoaderError.httpStatus(http.statusCode)
            }
            guard let image = UIImage(data: data) else {
                throw RemoteArtworkImageLoaderError.invalidImageData
            }
            return LoadResult(image: image, cost: data.count)
        }

        inFlightLoads[key as String] = task
        do {
            let result = try await task.value
            memoryCache.setObject(result.image, forKey: key, cost: result.cost)
            inFlightLoads[key as String] = nil
            SonosLog.debug(
                .playbackLink,
                "Remote artwork fetch stored key=\(SonosLog.playbackLinkValue(key as String, maxLength: 240)) cost=\(result.cost)")
            return result.image
        } catch {
            inFlightLoads[key as String] = nil
            SonosLog.debug(
                .playbackLink,
                "Remote artwork fetch failed key=\(SonosLog.playbackLinkValue(key as String, maxLength: 240)) error=\(error)")
            throw error
        }
    }

    private func cacheKey(for url: URL) -> NSString {
        RemoteArtworkImageCacheKey.normalized(url) as NSString
    }
}
