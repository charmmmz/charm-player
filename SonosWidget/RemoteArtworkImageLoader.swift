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

    func image(for url: URL) async throws -> UIImage {
        let key = cacheKey(for: url)
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        if let inFlight = inFlightLoads[key as String] {
            return try await inFlight.value.image
        }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "GET"

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
            return result.image
        } catch {
            inFlightLoads[key as String] = nil
            throw error
        }
    }

    private func cacheKey(for url: URL) -> NSString {
        RemoteArtworkImageCacheKey.normalized(url) as NSString
    }
}
