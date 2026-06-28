import XCTest
import UIKit
@testable import SonosWidget

final class AlbumPaletteExtractorTests: XCTestCase {
    func testExtractsMultipleDistinctColorsFromStripedArtwork() throws {
        let image = makeStripedImage(colors: [.red, .green, .blue, .yellow], size: CGSize(width: 80, height: 40))

        let palette = AlbumPaletteExtractor.palette(from: image, maxColors: 4)

        XCTAssertEqual(palette.count, 4)
        XCTAssertTrue(palette.contains { $0.r > 0.8 && $0.g < 0.3 && $0.b < 0.3 })
        XCTAssertTrue(palette.contains { $0.g > 0.6 && $0.r < 0.4 && $0.b < 0.4 })
        XCTAssertTrue(palette.contains { $0.b > 0.6 && $0.r < 0.4 && $0.g < 0.4 })
    }

    func testHueXYConversionKeepsValuesInsideBridgeRange() {
        let xy = HueRGBColor(r: 1, g: 0.2, b: 0.1).xy

        XCTAssertGreaterThanOrEqual(xy.x, 0)
        XCTAssertLessThanOrEqual(xy.x, 1)
        XCTAssertGreaterThanOrEqual(xy.y, 0)
        XCTAssertLessThanOrEqual(xy.y, 1)
    }

    func testHueXYConversionUsesSafeNeutralFallbackForZeroRGB() {
        let xy = HueRGBColor(r: 0, g: 0, b: 0).xy

        XCTAssertNotEqual(xy, HueXYColor(x: 0, y: 0))
    }

    func testDefaultPaletteCapsExtractionAtFiveColors() throws {
        let image = makeStripedImage(
            colors: [.red, .green, .blue, .yellow, .magenta, .cyan],
            size: CGSize(width: 120, height: 40)
        )

        let palette = AlbumPaletteExtractor.palette(from: image)

        XCTAssertLessThanOrEqual(palette.count, 5)
    }

    func testArtworkThemePalettePrefersAppleBackgroundOverVibrantFallback() throws {
        let fallbackImage = makeSolidImage(color: .red, size: CGSize(width: 40, height: 40))
        let themeColors = ArtworkThemeColors(
            background: HueRGBColor(r: 0.12, g: 0.18, b: 0.27),
            textColors: [
                HueRGBColor(r: 1, g: 1, b: 1),
                HueRGBColor(r: 0.95, g: 0.42, b: 0.12)
            ]
        )

        let palette = AlbumPaletteExtractor.palette(
            from: themeColors,
            fallbackImage: fallbackImage,
            maxColors: 4
        )

        let first = try XCTUnwrap(palette.first)
        XCTAssertGreaterThan(first.b, first.r)
        XCTAssertGreaterThan(first.b, first.g)
        XCTAssertFalse(first.r > 0.8 && first.g < 0.2 && first.b < 0.2)
    }

    func testDarkArtworkThemeKeepsDimNeonAccentsInsteadOfPastels() throws {
        let themeColors = ArtworkThemeColors(
            background: HueRGBColor(r: 0.02, g: 0.02, b: 0.03),
            textColors: [
                HueRGBColor(r: 0.96, g: 0.96, b: 0.9),
                HueRGBColor(r: 0.98, g: 0.05, b: 0.12),
                HueRGBColor(r: 0.0, g: 0.72, b: 0.95),
                HueRGBColor(r: 1.0, g: 0.46, b: 0.06)
            ]
        )

        let palette = AlbumPaletteExtractor.palette(from: themeColors, maxColors: 4)

        XCTAssertGreaterThanOrEqual(palette.count, 2, "palette: \(palette)")
        XCTAssertTrue(palette.allSatisfy { $0.brightness <= 0.62 }, "palette: \(palette)")
        XCTAssertTrue(palette.allSatisfy { saturation(of: $0) >= 0.35 }, "palette: \(palette)")
        XCTAssertTrue(palette.contains {
            $0.r > 0.42 && $0.r > $0.g * 1.5 && $0.r > $0.b * 1.25
        }, "palette: \(palette)")
        XCTAssertTrue(palette.contains {
            max($0.g, $0.b) > 0.42 && max($0.g, $0.b) > $0.r * 1.45
        }, "palette: \(palette)")
    }

    func testArtworkThemeColorsParseAppleMusicAPIHexFields() throws {
        let themeColors = try XCTUnwrap(ArtworkThemeColors(
            backgroundHex: "203044",
            textColorHexes: ["FFFFFF", "#dd8844", "bad"]
        ))

        XCTAssertEqual(themeColors.background, HueRGBColor(r: 32.0 / 255.0, g: 48.0 / 255.0, b: 68.0 / 255.0))
        XCTAssertEqual(themeColors.textColors.count, 2)
    }

    func testPlainArtworkFallsBackToUsableHueColor() throws {
        let image = makeSolidImage(color: .black, size: CGSize(width: 40, height: 40))

        let palette = AlbumPaletteExtractor.palette(from: image)

        let fallbackColor = try XCTUnwrap(palette.first)
        XCTAssertGreaterThanOrEqual(fallbackColor.r, 0)
        XCTAssertGreaterThanOrEqual(fallbackColor.g, 0)
        XCTAssertGreaterThanOrEqual(fallbackColor.b, 0)
        XCTAssertNotEqual(fallbackColor.xy, HueXYColor(x: 0, y: 0))
    }

    func testGrayscaleArtworkFallsBackToNeutralCoverColor() throws {
        let image = makeStripedImage(
            colors: [
                UIColor(white: 0.08, alpha: 1),
                UIColor(white: 0.82, alpha: 1)
            ],
            size: CGSize(width: 80, height: 40)
        )

        let palette = AlbumPaletteExtractor.palette(from: image)

        XCTAssertEqual(palette.count, 1)
        let neutral = try XCTUnwrap(palette.first)
        XCTAssertLessThan(abs(neutral.r - neutral.g), 0.02)
        XCTAssertLessThan(abs(neutral.g - neutral.b), 0.02)
        XCTAssertGreaterThanOrEqual(neutral.r, 0.25)
        XCTAssertLessThanOrEqual(neutral.r, 0.8)
    }

    func testMotionPaletteExpandsSingleSaturatedColorWithinSameHueFamily() {
        let palette = AlbumPaletteExtractor.motionPalette(from: [HueRGBColor(r: 0.82, g: 0.08, b: 0.12)])

        XCTAssertGreaterThanOrEqual(palette.count, 3)
        XCTAssertEqual(palette.first, HueRGBColor(r: 0.82, g: 0.08, b: 0.12))
        XCTAssertTrue(palette.allSatisfy { $0.r > $0.g && $0.r > $0.b })
    }

    func testMotionPaletteKeepsNeutralSingleColorNeutral() {
        let palette = AlbumPaletteExtractor.motionPalette(from: [HueRGBColor(r: 0.42, g: 0.42, b: 0.42)])

        XCTAssertGreaterThanOrEqual(palette.count, 3)
        XCTAssertTrue(palette.allSatisfy {
            abs($0.r - $0.g) < 0.02 && abs($0.g - $0.b) < 0.02
        })
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

    private func makeSolidImage(color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func saturation(of color: HueRGBColor) -> Double {
        let maxComponent = max(color.r, color.g, color.b)
        let minComponent = min(color.r, color.g, color.b)
        guard maxComponent > 0 else { return 0 }
        return (maxComponent - minComponent) / maxComponent
    }
}
