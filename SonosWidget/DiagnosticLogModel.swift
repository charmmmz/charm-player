import Foundation
import Observation

enum DiagnosticLogLevel: String, Equatable {
    case info = "Info"
    case error = "Error"
}

struct DiagnosticLogEntry: Identifiable, Equatable {
    let id: Int
    let timestampText: String?
    let category: String
    let level: DiagnosticLogLevel
    let message: String
    let rawLine: String

    var compactTimestampText: String? {
        guard let timestampText else { return nil }
        let time = timestampText
            .split(separator: "T", maxSplits: 1)
            .last?
            .replacingOccurrences(of: "Z", with: "")
        return time?.isEmpty == false ? time : timestampText
    }

    static func parse(line: String, id: Int) -> DiagnosticLogEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "SonosWidget diagnostics",
              trimmed != "SonosWidget DEBUG diagnostics" else {
            return nil
        }

        if let parsed = parseTimestampedLine(trimmed, id: id, rawLine: line) {
            return parsed
        }
        if let parsed = parseConsoleLine(trimmed, id: id, rawLine: line) {
            return parsed
        }
        return DiagnosticLogEntry(
            id: id,
            timestampText: nil,
            category: "Other",
            level: .info,
            message: trimmed,
            rawLine: line
        )
    }

    private static func parseTimestampedLine(
        _ line: String,
        id: Int,
        rawLine: String
    ) -> DiagnosticLogEntry? {
        let pattern = #"^(\S+)\s+\[([^\]]+)\]\s*(ERROR:)?\s*(.*)$"#
        guard let match = firstRegexMatch(pattern: pattern, in: line),
              let timestamp = string(in: line, from: match.range(at: 1)),
              let category = string(in: line, from: match.range(at: 2)),
              let message = string(in: line, from: match.range(at: 4)) else {
            return nil
        }
        let hasErrorSuffix = match.range(at: 3).location != NSNotFound
        return DiagnosticLogEntry(
            id: id,
            timestampText: timestamp,
            category: category,
            level: hasErrorSuffix ? .error : .info,
            message: message,
            rawLine: rawLine
        )
    }

    private static func parseConsoleLine(
        _ line: String,
        id: Int,
        rawLine: String
    ) -> DiagnosticLogEntry? {
        let pattern = #"^\[([^\]]+)\]\s*(ERROR:)?\s*(.*)$"#
        guard let match = firstRegexMatch(pattern: pattern, in: line),
              let category = string(in: line, from: match.range(at: 1)),
              let message = string(in: line, from: match.range(at: 3)) else {
            return nil
        }
        let hasErrorSuffix = match.range(at: 2).location != NSNotFound
        return DiagnosticLogEntry(
            id: id,
            timestampText: nil,
            category: category,
            level: hasErrorSuffix ? .error : .info,
            message: message,
            rawLine: rawLine
        )
    }

    private static func firstRegexMatch(pattern: String, in value: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }

    private static func string(in value: String, from range: NSRange) -> String? {
        guard range.location != NSNotFound,
              let valueRange = Range(range, in: value) else {
            return nil
        }
        return String(value[valueRange])
    }
}

struct DiagnosticLogFilter: Equatable {
    var selectedCategories: Set<String> = []
    var searchText = ""
    var showsErrorsOnly = false

    var hasActiveCategoryFilter: Bool {
        !selectedCategories.isEmpty
    }

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func includes(_ entry: DiagnosticLogEntry) -> Bool {
        if showsErrorsOnly, entry.level != .error {
            return false
        }

        if hasActiveCategoryFilter, !selectedCategories.contains(entry.category) {
            return false
        }

        let query = normalizedSearchText
        guard !query.isEmpty else { return true }
        return entry.category.localizedCaseInsensitiveContains(query)
            || entry.message.localizedCaseInsensitiveContains(query)
            || entry.rawLine.localizedCaseInsensitiveContains(query)
    }

    mutating func toggleCategory(_ category: String) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
    }
}

@MainActor
@Observable
final class DiagnosticLogStore {
    private(set) var entries: [DiagnosticLogEntry] = []
    private(set) var rawText = ""
    private(set) var loadError: String?

    @ObservationIgnored private let fileURLProvider: () -> URL?
    @ObservationIgnored private let fileManager: FileManager

    init(
        fileURLProvider: @escaping () -> URL? = SonosLog.diagnosticLogFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURLProvider = fileURLProvider
        self.fileManager = fileManager
    }

    var availableCategories: [String] {
        Set(entries.map(\.category)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func filteredEntries(using filter: DiagnosticLogFilter) -> [DiagnosticLogEntry] {
        entries.filter { filter.includes($0) }
    }

    func refresh() {
        guard let fileURL = fileURLProvider() else {
            entries = []
            rawText = ""
            loadError = "Diagnostic log file is unavailable."
            return
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            entries = []
            rawText = ""
            loadError = nil
            return
        }

        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            rawText = text
            entries = text
                .components(separatedBy: .newlines)
                .enumerated()
                .compactMap { DiagnosticLogEntry.parse(line: $0.element, id: $0.offset) }
            loadError = nil
        } catch {
            entries = []
            rawText = ""
            loadError = error.localizedDescription
        }
    }

    func clear() {
        guard let fileURL = fileURLProvider() else {
            entries = []
            rawText = ""
            return
        }
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            entries = []
            rawText = ""
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct DiagnosticLogExportResult: Equatable {
    let sourceURL: URL
    let exportURL: URL
    let byteCount: Int
}

enum DiagnosticLogExportError: Error, Equatable, LocalizedError {
    case sourceUnavailable
    case documentsDirectoryUnavailable
    case sourceMissing(URL)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "Diagnostic log file is unavailable."
        case .documentsDirectoryUnavailable:
            return "Documents directory is unavailable."
        case .sourceMissing(let url):
            return "Diagnostic log file does not exist: \(url.lastPathComponent)"
        }
    }
}

struct DiagnosticLogExporter {
    static let exportFileName = "sonos-diagnostics-export.log"

    var sourceURLProvider: () -> URL?
    var documentsDirectoryProvider: () -> URL?
    var flushPendingWrites: () -> Void
    var fileManager: FileManager

    init(
        sourceURLProvider: @escaping () -> URL? = SonosLog.diagnosticLogFileURL,
        documentsDirectoryProvider: @escaping () -> URL? = {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        },
        flushPendingWrites: @escaping () -> Void = SonosLog.flushDiagnosticWrites,
        fileManager: FileManager = .default
    ) {
        self.sourceURLProvider = sourceURLProvider
        self.documentsDirectoryProvider = documentsDirectoryProvider
        self.flushPendingWrites = flushPendingWrites
        self.fileManager = fileManager
    }

    func export() throws -> DiagnosticLogExportResult {
        guard let sourceURL = sourceURLProvider() else {
            throw DiagnosticLogExportError.sourceUnavailable
        }
        guard let documentsDirectory = documentsDirectoryProvider() else {
            throw DiagnosticLogExportError.documentsDirectoryUnavailable
        }
        flushPendingWrites()
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DiagnosticLogExportError.sourceMissing(sourceURL)
        }

        try fileManager.createDirectory(
            at: documentsDirectory,
            withIntermediateDirectories: true
        )

        let exportURL = documentsDirectory.appendingPathComponent(Self.exportFileName)
        if fileManager.fileExists(atPath: exportURL.path) {
            try fileManager.removeItem(at: exportURL)
        }
        try fileManager.copyItem(at: sourceURL, to: exportURL)

        let byteCount = (try? fileManager.attributesOfItem(atPath: exportURL.path)[.size] as? NSNumber)?
            .intValue ?? 0
        return DiagnosticLogExportResult(
            sourceURL: sourceURL,
            exportURL: exportURL,
            byteCount: byteCount
        )
    }
}
