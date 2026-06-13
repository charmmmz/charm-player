import Foundation

/// Categorized logger for Sonos Widget.
///
/// Three levels:
///   - `.error` — always emitted, prefixed `[Category] ERROR:` so it stands
///     out during user-reported bug hunts.
///   - `.info`  — always emitted. Reserve for successful state transitions
///     and summary counts (e.g. "Added to favorites", "Refreshed N items").
///   - `.debug` — stripped at compile time in Release builds via `#if DEBUG`.
///     Use for verbose request/response traces, internal fallback decisions,
///     and diagnostic banners that would otherwise spam the console.
///
/// Every call site picks a `Category` so filtering in Xcode console is easy
/// (search e.g. `[Playback]` to see all playback logs).
enum SonosLog {
    /// All log categories used across the app. Add new cases here rather
    /// than inventing bare-string prefixes at call sites.
    enum Category: String {
        case search         = "Search"
        case playback       = "Playback"
        case station        = "Station"
        case favorites      = "Favorites"
        case cloudAPI       = "CloudAPI"
        case cloudSearch    = "CloudSearch"
        case soap           = "SOAP"
        case sonosCloud     = "SonosCloud"
        case sonosAuth      = "SonosAuth"
        case artistDetail   = "ArtistDetail"
        case albumDetail    = "AlbumDetail"
        case playlistDetail = "PlaylistDetail"
        case localService   = "LocalService"
        case nowPlaying     = "NowPlaying"
        case parseCloudIds  = "parseCloudIds"
        case navItem        = "NavItem"
        case sonosEvents    = "SonosEvents"
    }

    /// Always logged. Use sparingly for unexpected failures worth reporting.
    @inline(__always)
    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        emit(category, suffix: " ERROR:", message())
    }

    /// Always logged. Use for operational signal (success, counts, state).
    @inline(__always)
    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        emit(category, suffix: nil, message())
    }

    /// Compiled out of Release builds. Use for high-volume traces and
    /// internal details that would otherwise drown the console.
    @inline(__always)
    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        #if DEBUG
        emit(category, suffix: nil, message())
        #endif
    }

    private static func emit(_ category: Category, suffix: String?, _ message: String) {
        let line = "[\(category.rawValue)]\(suffix ?? "") \(message)"
        print(line)
        writeDiagnosticLine(line, category: category)
    }

    private static func writeDiagnosticLine(_ line: String, category: Category) {
        #if DEBUG
        guard diagnosticCategories.contains(category),
              let fileURL = diagnosticFileURL(),
              let data = "\(diagnosticTimestamp()) \(line)\n".data(using: .utf8) else {
            return
        }

        diagnosticQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    let header = "SonosWidget DEBUG diagnostics\n"
                    try header.write(to: fileURL, atomically: true, encoding: .utf8)
                }

                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } catch {
                // Diagnostics must never affect app behavior.
            }
        }
        #endif
    }

    #if DEBUG
    private static let diagnosticCategories: Set<Category> = [
        .localService,
        .playback,
        .station,
        .soap
    ]
    private static let diagnosticQueue = DispatchQueue(label: "com.charm.SonosWidget.diagnostics")

    private static func diagnosticFileURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("sonos-diagnostics.log")
    }

    private static func diagnosticTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
    #endif
}
