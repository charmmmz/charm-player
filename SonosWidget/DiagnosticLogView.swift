import SwiftUI
import UIKit

struct DiagnosticLogView: View {
    @State private var store = DiagnosticLogStore()
    @State private var filter = DiagnosticLogFilter()
    @State private var isConfirmingClear = false
    @State private var didCopyVisibleLogs = false

    private var visibleEntries: [DiagnosticLogEntry] {
        store.filteredEntries(using: filter)
    }

    private var categoryOptions: [String] {
        let known = SonosLog.Category.allCases.map(\.rawValue)
        return Set(known + store.availableCategories).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            summarySection
            filterSection
            entriesSection
        }
        .searchable(text: $filter.searchText, prompt: "Search logs")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh Logs")

                Button {
                    copyVisibleLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy Visible Logs")
                .disabled(visibleEntries.isEmpty)

                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Clear Logs")
                .disabled(store.entries.isEmpty)
            }
        }
        .confirmationDialog("Clear diagnostic logs?", isPresented: $isConfirmingClear) {
            Button("Clear Logs", role: .destructive) {
                store.clear()
                didCopyVisibleLogs = false
            }
        }
        .onAppear {
            store.refresh()
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent("Entries", value: "\(store.entries.count)")
            LabeledContent("Visible", value: "\(visibleEntries.count)")
            if let fileURL = SonosLog.diagnosticLogFileURL() {
                LabeledContent("File", value: fileURL.lastPathComponent)
            }
            if let loadError = store.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if didCopyVisibleLogs {
                Label("Copied visible logs", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Summary")
        } footer: {
            Text("Info and error logs are stored locally. DEBUG builds also include debug logs. The log file is capped at 1 MB.")
        }
    }

    private var filterSection: some View {
        Section {
            Menu {
                Button {
                    filter.selectedCategories.removeAll()
                } label: {
                    Label(
                        "All Categories",
                        systemImage: filter.selectedCategories.isEmpty ? "checkmark.circle.fill" : "circle"
                    )
                }

                Divider()

                ForEach(categoryOptions, id: \.self) { category in
                    Button {
                        filter.toggleCategory(category)
                    } label: {
                        Label(
                            category,
                            systemImage: filter.selectedCategories.contains(category) ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                HStack {
                    Label(categoryFilterTitle, systemImage: "line.3.horizontal.decrease.circle")
                    Spacer()
                    Text(categoryFilterDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Toggle("Errors Only", isOn: $filter.showsErrorsOnly)
        } header: {
            Text("Filters")
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        Section {
            if store.entries.isEmpty {
                Label("No logs yet", systemImage: "doc.text")
                    .foregroundStyle(.secondary)
            } else if visibleEntries.isEmpty {
                Label("No logs match current filters", systemImage: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleEntries) { entry in
                    DiagnosticLogEntryRow(entry: entry)
                }
            }
        } header: {
            Text("Entries")
        }
    }

    private var categoryFilterTitle: String {
        switch filter.selectedCategories.count {
        case 0:
            return "All Categories"
        case 1:
            return filter.selectedCategories.first ?? "1 Category"
        default:
            return "\(filter.selectedCategories.count) Categories"
        }
    }

    private var categoryFilterDetail: String {
        guard !filter.selectedCategories.isEmpty else {
            return "\(categoryOptions.count) total"
        }
        return filter.selectedCategories.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        .joined(separator: ", ")
    }

    private func copyVisibleLogs() {
        UIPasteboard.general.string = visibleEntries
            .map(\.rawLine)
            .joined(separator: "\n")
        didCopyVisibleLogs = true
    }
}

private struct DiagnosticLogEntryRow: View {
    let entry: DiagnosticLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(entry.category)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(categoryTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(categoryTint.opacity(0.16), in: Capsule())

                if entry.level == .error {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 8)

                if let timestamp = entry.compactTimestampText {
                    Text(timestamp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Text(entry.message)
                .font(.caption)
                .foregroundStyle(entry.level == .error ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 5)
    }

    private var categoryTint: Color {
        let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .cyan]
        let scalarSum = entry.category.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[scalarSum % palette.count]
    }
}
