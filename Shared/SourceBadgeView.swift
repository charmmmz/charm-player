import SwiftUI

struct SourceBadgePresentation {
    let source: PlaybackSource

    var brandAssetImageName: String? {
        source == .appleMusic ? "BrandAppleMusicWordmark" : source.brandAssetImageName
    }

    var iconSystemName: String? {
        return brandAssetImageName == nil ? source.iconName : nil
    }

    var title: String? {
        brandAssetImageName == nil ? source.displayName : nil
    }

    func brandMarkWidth(compact: Bool) -> CGFloat {
        source == .appleMusic ? (compact ? 38 : 46) : (compact ? 12 : 14)
    }
}

struct SourceBadgeView: View {
    let source: PlaybackSource
    /// Retained for API compatibility — previous capsule layout used this to tint the pill.
    /// Ignored in the current bare-mark layout; brand SVGs carry their own color.
    var tintColor: Color?
    var compact: Bool = false

    private var symbolColor: Color {
        tintColor ?? .white.opacity(0.9)
    }

    var body: some View {
        if source != .unknown {
            let presentation = SourceBadgePresentation(source: source)
            HStack(spacing: compact ? 0 : 4) {
                if let brand = presentation.brandAssetImageName {
                    Image(brand)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: presentation.brandMarkWidth(compact: compact),
                               height: compact ? 12 : 14)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                } else if let iconSystemName = presentation.iconSystemName {
                    Image(systemName: iconSystemName)
                        .font(.system(size: compact ? 10 : 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                } else {
                    Image(systemName: source.iconName)
                        .font(.system(size: compact ? 10 : 12, weight: .semibold))
                        .foregroundStyle(symbolColor)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                }
                if !compact, let title = presentation.title {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                }
            }
        }
    }
}
