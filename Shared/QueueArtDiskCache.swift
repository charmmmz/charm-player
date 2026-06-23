import UIKit

/// Two-level album art cache: memory (NSCache) → disk (Caches/QueueArt/).
///
/// Disk eviction is LRU: every read touches the file's modification date so
/// frequently-accessed images (e.g. the currently playing song) are never
/// evicted ahead of images that haven't been viewed.
nonisolated final class QueueArtDiskCache {
    static let shared = QueueArtDiskCache()

    private let cacheDir: URL
    private let maxDiskBytes: Int = 100 * 1024 * 1024  // 100 MB
    private let fm = FileManager.default

    private init() {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("QueueArt", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func data(for urlStr: String) -> Data? {
        let path = filePath(for: urlStr)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        return data
    }

    func image(for urlStr: String) -> UIImage? {
        guard let data = data(for: urlStr) else { return nil }
        return UIImage(data: data)
    }

    func store(_ data: Data, for urlStr: String) {
        let path = filePath(for: urlStr)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        evictIfNeeded()
    }

    func contains(_ urlStr: String) -> Bool {
        fm.fileExists(atPath: filePath(for: urlStr))
    }

    /// Refresh LRU timestamp without re-reading the full image (used when
    /// the image is served from the memory cache but we still want to keep
    /// the disk entry warm).
    func touch(_ urlStr: String) {
        let path = filePath(for: urlStr)
        guard fm.fileExists(atPath: path) else { return }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }

    // MARK: - Private helpers

    private func filePath(for urlStr: String) -> String {
        cacheDir.appendingPathComponent(String(stableHash(urlStr))).path
    }

    /// Deterministic djb2 hash — stable across app launches unlike Swift's hashValue.
    private func stableHash(_ s: String) -> UInt64 {
        s.utf8.reduce(5381 as UInt64) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
    }

    private func evictIfNeeded() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        ) else { return }

        var totalSize = files.compactMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }.reduce(0, +)

        guard totalSize > maxDiskBytes else { return }

        let sorted = files.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return d1 < d2  // oldest first
        }

        for file in sorted {
            guard totalSize > maxDiskBytes else { break }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try? fm.removeItem(at: file)
            totalSize -= size
        }
    }
}
