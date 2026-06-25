import XCTest
@testable import SonosWidget

final class DiagnosticLogModelTests: XCTestCase {
    func testRemoteDiagnosticRedactorMasksSonosServiceTokens() {
        let raw = "Username for 52231: X_#Svc52231-408f19a7-Token"

        XCTAssertEqual(
            DiagnosticRemoteLogRedactor.redact(raw),
            "Username for 52231: X_#Svc52231-<redacted>-Token"
        )
    }

    func testRemoteDiagnosticRedactorMasksBearerAndQueryTokens() {
        let raw = "Authorization: Bearer abc.def_123 access_token=secret&refresh_token=alsoSecret"

        XCTAssertEqual(
            DiagnosticRemoteLogRedactor.redact(raw),
            "Authorization: Bearer <redacted> access_token=<redacted>&refresh_token=<redacted>"
        )
    }

    func testParsesInfoLine() {
        let entry = DiagnosticLogEntry.parse(
            line: "2026-06-21T01:02:03Z [Playback] Artwork cache hit source=musicKit",
            id: 7
        )

        XCTAssertEqual(entry?.id, 7)
        XCTAssertEqual(entry?.timestampText, "2026-06-21T01:02:03Z")
        XCTAssertEqual(entry?.category, "Playback")
        XCTAssertEqual(entry?.level, .info)
        XCTAssertEqual(entry?.message, "Artwork cache hit source=musicKit")
    }

    func testParsesErrorLine() {
        let entry = DiagnosticLogEntry.parse(
            line: "2026-06-21T01:02:03Z [Relay] ERROR: Probe failed status=500",
            id: 1
        )

        XCTAssertEqual(entry?.category, "Relay")
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.message, "Probe failed status=500")
    }

    func testSkipsDiagnosticHeadersAndBlankLines() {
        XCTAssertNil(DiagnosticLogEntry.parse(line: "", id: 0))
        XCTAssertNil(DiagnosticLogEntry.parse(line: "SonosWidget diagnostics", id: 1))
        XCTAssertNil(DiagnosticLogEntry.parse(line: "SonosWidget DEBUG diagnostics", id: 2))
    }

    func testFilterMatchesCategorySearchAndErrorsOnly() {
        let playback = DiagnosticLogEntry(
            id: 1,
            timestampText: "2026-06-21T01:02:03Z",
            category: "Playback",
            level: .info,
            message: "Artwork cache hit source=musicKit",
            rawLine: "raw playback"
        )
        let relay = DiagnosticLogEntry(
            id: 2,
            timestampText: "2026-06-21T01:02:04Z",
            category: "Relay",
            level: .error,
            message: "Probe failed",
            rawLine: "raw relay"
        )

        var filter = DiagnosticLogFilter(
            selectedCategories: ["Playback"],
            searchText: "musicKit",
            showsErrorsOnly: false
        )
        XCTAssertTrue(filter.includes(playback))
        XCTAssertFalse(filter.includes(relay))

        filter.searchText = ""
        filter.showsErrorsOnly = true
        XCTAssertFalse(filter.includes(playback))

        filter.selectedCategories = ["Relay"]
        XCTAssertTrue(filter.includes(relay))
    }

    func testStoreLoadsAndClearsDiagnosticFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLogModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("sonos-diagnostics.log")
        try """
        SonosWidget diagnostics
        2026-06-21T01:02:03Z [Playback] Artwork cache hit
        2026-06-21T01:02:04Z [Relay] ERROR: Probe failed

        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = DiagnosticLogStore(fileURLProvider: { fileURL })

        store.refresh()

        XCTAssertEqual(store.entries.map(\.category), ["Playback", "Relay"])
        XCTAssertEqual(store.availableCategories, ["Playback", "Relay"])

        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testExporterCopiesCurrentDiagnosticLogToDocuments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLogExporterTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("AppGroup", isDirectory: true)
        let documentsDirectory = directory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = sourceDirectory.appendingPathComponent("sonos-diagnostics.log")
        let text = """
        SonosWidget diagnostics
        2026-06-21T01:02:03Z [Playback] Export me

        """
        try text.write(to: sourceURL, atomically: true, encoding: .utf8)

        let exporter = DiagnosticLogExporter(
            sourceURLProvider: { sourceURL },
            documentsDirectoryProvider: { documentsDirectory }
        )

        let result = try exporter.export()

        XCTAssertEqual(result.sourceURL, sourceURL)
        XCTAssertEqual(result.exportURL, documentsDirectory.appendingPathComponent("sonos-diagnostics-export.log"))
        XCTAssertEqual(result.byteCount, text.data(using: .utf8)?.count)
        XCTAssertEqual(try String(contentsOf: result.exportURL, encoding: .utf8), text)
    }

    func testExporterReplacesExistingExportFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLogExporterTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("AppGroup", isDirectory: true)
        let documentsDirectory = directory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = sourceDirectory.appendingPathComponent("sonos-diagnostics.log")
        let exportURL = documentsDirectory.appendingPathComponent("sonos-diagnostics-export.log")
        try "fresh log".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "stale log".write(to: exportURL, atomically: true, encoding: .utf8)

        let exporter = DiagnosticLogExporter(
            sourceURLProvider: { sourceURL },
            documentsDirectoryProvider: { documentsDirectory }
        )

        _ = try exporter.export()

        XCTAssertEqual(try String(contentsOf: exportURL, encoding: .utf8), "fresh log")
    }

    func testExporterFlushesPendingWritesBeforeCopying() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLogExporterTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("AppGroup", isDirectory: true)
        let documentsDirectory = directory.appendingPathComponent("Documents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = sourceDirectory.appendingPathComponent("sonos-diagnostics.log")
        let exporter = DiagnosticLogExporter(
            sourceURLProvider: { sourceURL },
            documentsDirectoryProvider: { documentsDirectory },
            flushPendingWrites: {
                try? FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
                try? "flushed log".write(to: sourceURL, atomically: true, encoding: .utf8)
            }
        )

        let result = try exporter.export()

        XCTAssertEqual(try String(contentsOf: result.exportURL, encoding: .utf8), "flushed log")
    }

    func testExporterReportsMissingSourceFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLogExporterTests-\(UUID().uuidString)", isDirectory: true)
        let missingSourceURL = directory.appendingPathComponent("missing.log")
        let documentsDirectory = directory.appendingPathComponent("Documents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let exporter = DiagnosticLogExporter(
            sourceURLProvider: { missingSourceURL },
            documentsDirectoryProvider: { documentsDirectory }
        )

        XCTAssertThrowsError(try exporter.export()) { error in
            XCTAssertEqual(error as? DiagnosticLogExportError, .sourceMissing(missingSourceURL))
        }
    }
}
