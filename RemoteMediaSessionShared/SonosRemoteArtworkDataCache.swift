import CryptoKit
import Foundation

actor SonosRemoteArtworkDataCache {
    enum Source: Equatable, Sendable {
        case memory
        case disk
        case network
    }

    struct Value: Sendable {
        let data: Data
        let source: Source
    }

    typealias Loader = @Sendable (URL) async throws -> Data

    static let shared = SonosRemoteArtworkDataCache()

    private static let maximumImageBytes = 8 * 1_024 * 1_024
    private static let networkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    private let directory: URL
    private let loader: Loader
    private let maxMemoryBytes: Int
    private let maxDiskBytes: Int
    private let maxDiskEntries: Int
    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private var memoryBytes = 0
    private var inFlight: [String: Task<Data, Error>] = [:]

    init(
        directory: URL? = nil,
        maxMemoryBytes: Int = 16 * 1_024 * 1_024,
        maxDiskBytes: Int = 32 * 1_024 * 1_024,
        maxDiskEntries: Int = 24,
        loader: Loader? = nil
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.maxMemoryBytes = maxMemoryBytes
        self.maxDiskBytes = maxDiskBytes
        self.maxDiskEntries = maxDiskEntries
        self.loader = loader ?? { url in
            try await Self.loadFromNetwork(url)
        }
    }

    func data(for url: URL) async throws -> Value {
        let key = cacheKey(for: url)
        if let data = memory[key] {
            touchMemoryKey(key)
            return Value(data: data, source: .memory)
        }

        let destination = directory.appendingPathComponent(key).appendingPathExtension("artwork")
        if let data = validData(at: destination) {
            insertIntoMemory(data, key: key)
            return Value(data: data, source: .disk)
        }

        if let task = inFlight[key] {
            let data = try await task.value
            insertIntoMemory(data, key: key)
            return Value(data: data, source: .memory)
        }

        let loader = self.loader
        let task = Task<Data, Error> {
            try await loader(url)
        }
        inFlight[key] = task
        do {
            let data = try await task.value
            inFlight[key] = nil
            guard !data.isEmpty, data.count <= Self.maximumImageBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            insertIntoMemory(data, key: key)
            pruneDiskCache(keeping: destination)
            return Value(data: data, source: .network)
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func remove(_ url: URL) {
        let key = cacheKey(for: url)
        if let data = memory.removeValue(forKey: key) {
            memoryBytes -= data.count
        }
        memoryOrder.removeAll { $0 == key }
        let destination = directory.appendingPathComponent(key).appendingPathExtension("artwork")
        try? FileManager.default.removeItem(at: destination)
    }

    private func insertIntoMemory(_ data: Data, key: String) {
        if let previous = memory.updateValue(data, forKey: key) {
            memoryBytes -= previous.count
        }
        memoryBytes += data.count
        touchMemoryKey(key)
        while memoryBytes > maxMemoryBytes, let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            if let removed = memory.removeValue(forKey: oldest) {
                memoryBytes -= removed.count
            }
        }
    }

    private func touchMemoryKey(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    private func validData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumImageBytes,
              let data = try? Data(contentsOf: url),
              data.count == size else {
            return nil
        }
        return data
    }

    private func pruneDiskCache(keeping currentURL: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left > right
        }
        var retainedBytes = 0
        for (index, file) in sorted.enumerated() {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let shouldRemove = index >= maxDiskEntries || retainedBytes + size > maxDiskBytes
            if shouldRemove, file != currentURL {
                try? FileManager.default.removeItem(at: file)
            } else {
                retainedBytes += size
            }
        }
    }

    private func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RemoteStaticArtwork", isDirectory: true)
    }

    private static func loadFromNetwork(_ url: URL) async throws -> Data {
        let (data, response) = try await networkSession.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
