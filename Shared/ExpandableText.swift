import SwiftUI

/// Apple-Music–style expandable description.
///
/// Renders text clamped to `collapsedLineLimit` with a small Apple-Music-style
/// "...more" toggle in the trailing-bottom corner. Tapping more opens a sheet
/// that shows the full text in a scrollable view, with an X close button
/// and the surfacing screen's `title` at the top — same pattern Apple Music
/// uses for album / artist editorial copy.
///
/// Only shows the toggle when truncation actually occurs (probed via a hidden
/// reference layout), so short blurbs render cleanly without dangling chrome.
struct ExpandableText: View {
    let text: String
    /// Used as the sheet's navigation title (typically the playlist / album
    /// / artist name the description is describing).
    var title: String = ""
    var collapsedLineLimit: Int = 3
    var font: Font = .subheadline
    var textColor: Color = .white.opacity(0.7)
    var toggleColor: Color = .white
    var multilineTextAlignment: TextAlignment = .leading

    @State private var isPresented = false
    @State private var truncationDetected = false

    private var attributedText: AttributedString {
        ExpandableDescriptionTextFormatter.attributedString(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Text(attributedText)
                    .font(font)
                    .foregroundStyle(textColor)
                    .lineLimit(collapsedLineLimit)
                    .multilineTextAlignment(multilineTextAlignment)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)

                // Hidden probe that detects if the text would overflow when
                // clamped — by comparing the height of an unclamped vs
                // clamped copy of the same string.
                Text(attributedText)
                    .font(font)
                    .lineLimit(collapsedLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { clamped in
                            Text(attributedText)
                                .font(font)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .background(
                                    GeometryReader { full in
                                        Color.clear.onAppear {
                                            truncationDetected = full.size.height > clamped.size.height + 1
                                        }
                                    }
                                )
                                .hidden()
                        }
                    )
                    .hidden()

                if truncationDetected {
                    Button {
                        isPresented = true
                    } label: {
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.black.opacity(0.22)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 30)

                            Text(ExpandableDescriptionPolicy.moreLabel)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(toggleColor.opacity(0.86))
                                .padding(.leading, 3)
                                .background(Color.black.opacity(0.22))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $isPresented) {
            ExpandedTextSheet(text: attributedText, title: title)
        }
        .onChange(of: text) { _, _ in
            truncationDetected = false
        }
    }

    private var frameAlignment: Alignment {
        switch multilineTextAlignment {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }
}

enum ExpandableDescriptionPolicy {
    static let moreLabel = "MORE"
}

struct ExpandableDescriptionTextSegment: Equatable, Sendable {
    let text: String
    let isItalic: Bool
}

enum ExpandableDescriptionTextFormatter {
    static func plainText(from rawText: String) -> String {
        segments(from: rawText).map(\.text).joined()
    }

    static func attributedString(from rawText: String) -> AttributedString {
        var result = AttributedString()
        for segment in segments(from: rawText) where !segment.text.isEmpty {
            var part = AttributedString(segment.text)
            if segment.isItalic {
                part.inlinePresentationIntent = .emphasized
            }
            result += part
        }
        return result
    }

    static func segments(from rawText: String) -> [ExpandableDescriptionTextSegment] {
        var segments: [ExpandableDescriptionTextSegment] = []
        var buffer = ""
        var isItalic = false
        var index = rawText.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(
                ExpandableDescriptionTextSegment(text: buffer, isItalic: isItalic)
            )
            buffer.removeAll(keepingCapacity: true)
        }

        while index < rawText.endIndex {
            if rawText[index] == "<",
               let tagEnd = rawText[index...].firstIndex(of: ">") {
                let tagBody = rawText[rawText.index(after: index)..<tagEnd]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                switch tagBody {
                case "i", "em":
                    flush()
                    isItalic = true
                    index = rawText.index(after: tagEnd)
                    continue
                case "/i", "/em":
                    flush()
                    isItalic = false
                    index = rawText.index(after: tagEnd)
                    continue
                case "br", "br/":
                    buffer.append("\n")
                    index = rawText.index(after: tagEnd)
                    continue
                default:
                    break
                }
            }

            buffer.append(rawText[index])
            index = rawText.index(after: index)
        }

        flush()
        return segments
    }
}

/// The modal Apple-Music–style fullscreen reader presented when the user
/// taps "MORE". Scrollable body with a top bar carrying an X dismiss button
/// and (optional) title.
private struct ExpandedTextSheet: View {
    let text: AttributedString
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(8)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
