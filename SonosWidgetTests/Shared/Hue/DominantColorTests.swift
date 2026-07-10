import XCTest
import UIKit
@testable import SonosWidget

final class DominantColorTests: XCTestCase {
    func testGrayscaleArtworkDoesNotInventSaturatedAccent() throws {
        let image = makeStripedImage(
            colors: [
                UIColor(white: 0.04, alpha: 1),
                UIColor(white: 0.88, alpha: 1),
                UIColor(white: 0.18, alpha: 1),
                UIColor(white: 0.62, alpha: 1)
            ],
            size: CGSize(width: 80, height: 80)
        )

        let color = try XCTUnwrap(rgb(from: image.dominantColorHex()))

        XCTAssertLessThan(color.saturation, 0.12)
        XCTAssertLessThan(abs(color.r - color.g), 0.08)
        XCTAssertLessThan(abs(color.g - color.b), 0.08)
    }

    func testNearlyGrayscaleArtworkWithWarmNoiseStaysNeutral() throws {
        let image = makeStripedImage(
            colors: [
                UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),
                UIColor(red: 0.84, green: 0.82, blue: 0.80, alpha: 1),
                UIColor(red: 0.16, green: 0.15, blue: 0.15, alpha: 1),
                UIColor(red: 0.58, green: 0.56, blue: 0.54, alpha: 1)
            ],
            size: CGSize(width: 80, height: 80)
        )

        let color = try XCTUnwrap(rgb(from: image.dominantColorHex()))

        XCTAssertLessThan(color.saturation, 0.18)
    }

    func testSaturatedArtworkStillReturnsColorfulAccent() throws {
        let image = makeStripedImage(
            colors: [
                UIColor(red: 0.80, green: 0.10, blue: 0.16, alpha: 1),
                UIColor(red: 0.22, green: 0.08, blue: 0.42, alpha: 1)
            ],
            size: CGSize(width: 80, height: 80)
        )

        let color = try XCTUnwrap(rgb(from: image.dominantColorHex()))

        XCTAssertGreaterThan(color.saturation, 0.45)
    }

    private func makeStripedImage(colors: [UIColor], size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let stripeWidth = size.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(CGRect(x: CGFloat(index) * stripeWidth, y: 0, width: stripeWidth, height: size.height))
            }
        }
    }

    private func rgb(from hex: String?) -> (r: Double, g: Double, b: Double, saturation: Double)? {
        guard var hex, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        let maxComponent = max(r, g, b)
        let minComponent = min(r, g, b)
        let saturation = maxComponent > 0 ? (maxComponent - minComponent) / maxComponent : 0

        return (r, g, b, saturation)
    }
}
