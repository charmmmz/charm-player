import CoreGraphics

enum AppleMusicArtworkTapPolicy {
    static let defaultThreshold: CGFloat = 8

    static func shouldOpen(
        translation: CGSize,
        threshold: CGFloat = defaultThreshold
    ) -> Bool {
        let distance = sqrt(translation.width * translation.width + translation.height * translation.height)
        return distance <= threshold
    }
}
