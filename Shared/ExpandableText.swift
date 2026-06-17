import SwiftUI
import UIKit

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
    var uiTextStyle: UIFont.TextStyle = .subheadline
    var textColor: Color = .white.opacity(0.7)
    var toggleColor: Color = .white
    var multilineTextAlignment: TextAlignment = .leading

    @State private var isPresented = false
    @State private var availableWidth: CGFloat = 0

    private var attributedText: AttributedString {
        ExpandableDescriptionTextFormatter.attributedString(from: text)
    }

    private var uiFont: UIFont {
        .preferredFont(forTextStyle: uiTextStyle)
    }

    private var collapsedResult: ExpandableDescriptionTruncationResult {
        ExpandableDescriptionTruncator.collapsedText(
            from: text,
            font: uiFont,
            textColor: UIColor(textColor),
            moreColor: UIColor(toggleColor),
            width: availableWidth,
            lineLimit: collapsedLineLimit
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            collapsedText
                .contentShape(Rectangle())
                .onTapGesture {
                    if collapsedResult.isTruncated {
                        isPresented = true
                    }
                }
        }
        .sheet(isPresented: $isPresented) {
            ExpandedTextSheet(text: attributedText, title: title)
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

    private var collapsedText: some View {
        Text(swiftUIAttributedString(from: collapsedResult.attributedText))
            .lineLimit(collapsedLineLimit)
            .multilineTextAlignment(multilineTextAlignment)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ExpandableDescriptionWidthPreferenceKey.self,
                        value: proxy.size.width
                    )
                }
            )
            .onPreferenceChange(ExpandableDescriptionWidthPreferenceKey.self) { width in
                guard width > 0, abs(width - availableWidth) > 0.5 else { return }
                availableWidth = width
            }
    }

    private func swiftUIAttributedString(from attributedText: NSAttributedString) -> AttributedString {
        (try? AttributedString(attributedText, including: \.uiKit)) ?? AttributedString(attributedText.string)
    }
}

enum ExpandableDescriptionPolicy {
    static let moreLabel = "MORE"
    static let appleMusicCollapsedLineLimit = 2
    static let usesCollapsedTextLayerMask = false
    static let moreLabelWidth: CGFloat = 38
    static let moreLabelLeadingPadding: CGFloat = 6
    static let moreFadeWidth: CGFloat = 40
    static let moreOverlayDefaultLineHeight: CGFloat = 17
    static let inlineMoreFadeCharacterCount = 5
    static let inlineMoreMinimumFadeAlpha: CGFloat = 0.18

    static func inlineMoreReservedWidth(labelWidth: CGFloat = moreLabelWidth) -> CGFloat {
        moreFadeWidth + moreLabelLeadingPadding + labelWidth
    }

    static func moreOverlayReservedWidth(labelWidth: CGFloat = moreLabelWidth) -> CGFloat {
        inlineMoreReservedWidth(labelWidth: labelWidth)
    }
}

struct ExpandableDescriptionTruncationResult {
    let attributedText: NSAttributedString
    let isTruncated: Bool
}

enum ExpandableDescriptionTruncator {
    static func collapsedText(
        from rawText: String,
        font: UIFont,
        textColor: UIColor,
        moreColor: UIColor,
        width: CGFloat,
        lineLimit: Int
    ) -> ExpandableDescriptionTruncationResult {
        let full = attributedString(
            from: rawText,
            characterLimit: nil,
            shouldTrimTrailingWhitespace: false,
            font: font,
            textColor: textColor
        )
        guard width > 1, lineLimit > 0 else {
            return ExpandableDescriptionTruncationResult(attributedText: full, isTruncated: false)
        }
        guard !fits(full, width: width, lineLimit: lineLimit) else {
            return ExpandableDescriptionTruncationResult(attributedText: full, isTruncated: false)
        }

        let plainText = ExpandableDescriptionTextFormatter.plainText(from: rawText)
        var lower = 0
        var upper = plainText.count
        var best = 0

        while lower <= upper {
            let mid = (lower + upper) / 2
            let candidate = attributedPrefixWithMore(
                from: rawText,
                characterLimit: mid,
                font: font,
                textColor: textColor,
                moreColor: moreColor
            )

            if fits(candidate, width: width, lineLimit: lineLimit) {
                best = mid
                lower = mid + 1
            } else {
                upper = mid - 1
            }
        }

        return ExpandableDescriptionTruncationResult(
            attributedText: attributedPrefixWithMore(
                from: rawText,
                characterLimit: best,
                font: font,
                textColor: textColor,
                moreColor: moreColor
            ),
            isTruncated: true
        )
    }

    private static func attributedPrefixWithMore(
        from rawText: String,
        characterLimit: Int,
        font: UIFont,
        textColor: UIColor,
        moreColor: UIColor
    ) -> NSAttributedString {
        let result = attributedString(
            from: rawText,
            characterLimit: characterLimit,
            shouldTrimTrailingWhitespace: true,
            font: font,
            textColor: textColor
        )
        applyTrailingInlineMoreFade(to: result, textColor: textColor)
        result.append(
            NSAttributedString(
                string: " ",
                attributes: [.font: font, .foregroundColor: textColor]
            )
        )
        result.append(
            NSAttributedString(
                string: ExpandableDescriptionPolicy.moreLabel,
                attributes: [
                    .font: fontWithTraits(font, traits: .traitBold),
                    .foregroundColor: moreColor
                ]
            )
        )
        return result
    }

    private static func attributedString(
        from rawText: String,
        characterLimit: Int?,
        shouldTrimTrailingWhitespace: Bool,
        font: UIFont,
        textColor: UIColor
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        var remaining = characterLimit

        for segment in ExpandableDescriptionTextFormatter.segments(from: rawText) {
            if let remainingCount = remaining, remainingCount <= 0 {
                break
            }

            let segmentText: String
            if let remainingCount = remaining {
                segmentText = String(segment.text.prefix(remainingCount))
                remaining = remainingCount - segmentText.count
            } else {
                segmentText = segment.text
            }

            guard !segmentText.isEmpty else { continue }
            result.append(
                NSAttributedString(
                    string: segmentText,
                    attributes: [
                        .font: segment.isItalic ? fontWithTraits(font, traits: .traitItalic) : font,
                        .foregroundColor: textColor
                    ]
                )
            )
        }

        if shouldTrimTrailingWhitespace {
            trimTrailingWhitespace(from: result)
        }
        return result
    }

    private static func applyTrailingInlineMoreFade(
        to attributedString: NSMutableAttributedString,
        textColor: UIColor
    ) {
        guard attributedString.length > 0 else { return }

        let fadeLength = min(ExpandableDescriptionPolicy.inlineMoreFadeCharacterCount, attributedString.length)
        let baseAlpha = resolvedAlpha(for: textColor)
        let start = attributedString.length - fadeLength

        for offset in 0..<fadeLength {
            let progress = CGFloat(offset + 1) / CGFloat(fadeLength)
            let alphaMultiplier = 1 - progress * (1 - ExpandableDescriptionPolicy.inlineMoreMinimumFadeAlpha)
            let color = textColor.withAlphaComponent(baseAlpha * alphaMultiplier)
            attributedString.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: start + offset, length: 1)
            )
        }
    }

    private static func resolvedAlpha(for color: UIColor) -> CGFloat {
        color.resolvedColor(with: UITraitCollection.current).cgColor.alpha
    }

    private static func trimTrailingWhitespace(from attributedString: NSMutableAttributedString) {
        while attributedString.length > 0 {
            let lastRange = NSRange(location: attributedString.length - 1, length: 1)
            let lastCharacter = attributedString.string as NSString
            let value = lastCharacter.substring(with: lastRange)
            guard value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else {
                break
            }
            attributedString.deleteCharacters(in: lastRange)
        }
    }

    private static func fits(
        _ attributedString: NSAttributedString,
        width: CGFloat,
        lineLimit: Int
    ) -> Bool {
        lineCount(for: attributedString, width: width) <= lineLimit
    }

    private static func lineCount(
        for attributedString: NSAttributedString,
        width: CGFloat
    ) -> Int {
        guard attributedString.length > 0 else { return 0 }

        let textStorage = NSTextStorage(attributedString: attributedString)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var glyphIndex = glyphRange.location
        var lineCount = 0

        while glyphIndex < NSMaxRange(glyphRange) {
            var effectiveRange = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
            guard effectiveRange.length > 0 else { break }
            glyphIndex = NSMaxRange(effectiveRange)
            lineCount += 1
        }
        return lineCount
    }

    private static func fontWithTraits(
        _ font: UIFont,
        traits: UIFontDescriptor.SymbolicTraits
    ) -> UIFont {
        var symbolicTraits = font.fontDescriptor.symbolicTraits
        symbolicTraits.insert(traits)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(symbolicTraits) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

private struct ExpandableDescriptionWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
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
