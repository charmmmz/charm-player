import UIKit
import SwiftUI

extension UIImage {
    /// Extracts a vibrant, high-contrast color suitable for use against dark backgrounds.
    func dominantColor() -> Color? {
        guard let (r, g, b) = extractVibrantRGB() else { return nil }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    func dominantUIColor() -> UIColor? {
        guard let (r, g, b) = extractVibrantRGB() else { return nil }
        return UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    func dominantColorHex() -> String? {
        guard let (r, g, b) = extractVibrantRGB() else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Average RGB of the bottom strip of the cover (default ~bottom 12%).
    /// Used by the player background so the gradient starts from the colour
    /// the cover *actually* ends with — without this, an album with a white-
    /// snow bottom over a brown-dominant scene leaves a visible hard edge
    /// where the sharp cover meets the dominant-colour backdrop.
    /// Unlike `dominantColor()`, this returns the raw averaged colour with
    /// no saturation / lightness boost.
    func bottomEdgeColor(stripFraction: CGFloat = 0.12) -> Color? {
        guard let (r, g, b) = averageRGB(stripFraction: stripFraction) else { return nil }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    private func averageRGB(stripFraction: CGFloat) -> (Double, Double, Double)? {
        guard let cgImage else { return nil }
        let imgW = cgImage.width
        let imgH = cgImage.height
        guard imgW > 0, imgH > 0 else { return nil }

        // Down-sample to a thin strip (W=16, H≈2) to keep cost trivial.
        let stripPixels = max(1, Int(CGFloat(imgH) * stripFraction))
        let dstW = 16
        let dstH = max(1, dstW * stripPixels / max(imgW, 1))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var raw = [UInt8](repeating: 0, count: dstW * dstH * 4)

        guard let ctx = CGContext(
            data: &raw, width: dstW, height: dstH,
            bitsPerComponent: 8, bytesPerRow: dstW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw only the bottom strip of the source into the destination.
        let srcY = imgH - stripPixels
        let drawRect = CGRect(x: 0, y: -CGFloat(srcY) * (CGFloat(dstH) / CGFloat(stripPixels)),
                              width: CGFloat(dstW),
                              height: CGFloat(imgH) * (CGFloat(dstH) / CGFloat(stripPixels)))
        ctx.clip(to: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        ctx.draw(cgImage, in: drawRect)

        var rSum: Double = 0, gSum: Double = 0, bSum: Double = 0
        var count: Double = 0
        for i in stride(from: 0, to: raw.count, by: 4) {
            rSum += Double(raw[i]) / 255.0
            gSum += Double(raw[i + 1]) / 255.0
            bSum += Double(raw[i + 2]) / 255.0
            count += 1
        }
        guard count > 0 else { return nil }
        return (rSum / count, gSum / count, bSum / count)
    }

    /// Samples the image, picks the most saturated representative color,
    /// then boosts lightness and saturation so it reads clearly on dark backgrounds.
    private func extractVibrantRGB() -> (Double, Double, Double)? {
        guard let cgImage = cgImage else { return nil }

        let size = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var raw = [UInt8](repeating: 0, count: size * size * 4)

        guard let ctx = CGContext(
            data: &raw, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var bestColor: (r: Double, g: Double, b: Double) = (0.6, 0.6, 0.6)
        var bestScore: Double = -1
        var sampledR: Double = 0
        var sampledG: Double = 0
        var sampledB: Double = 0
        var sampledCount: Double = 0
        var colorfulCount: Double = 0
        var saturationTotal: Double = 0

        for i in stride(from: 0, to: raw.count, by: 4) {
            let r = Double(raw[i]) / 255.0
            let g = Double(raw[i + 1]) / 255.0
            let b = Double(raw[i + 2]) / 255.0

            let hsl = hslComponents(r, g, b)
            let lightness = hsl.l
            let saturation = hsl.s

            if lightness >= 0.08 && lightness <= 0.94 {
                sampledR += r
                sampledG += g
                sampledB += b
                sampledCount += 1
                saturationTotal += saturation
                if saturation >= 0.18 {
                    colorfulCount += 1
                }
            }

            // Strongly prefer saturated colors; target lightness around 0.6 for dark-bg legibility.
            // Penalise near-black and near-white pixels.
            let score = saturation * 3.0
                + (1.0 - abs(lightness - 0.60)) * 0.8
                - (lightness < 0.15 ? 3.0 : 0)
                - (lightness > 0.92 ? 2.0 : 0)

            if score > bestScore {
                bestScore = score
                bestColor = (r, g, b)
            }
        }

        if sampledCount > 0 {
            let averageSaturation = saturationTotal / sampledCount
            let colorfulFraction = colorfulCount / sampledCount
            if averageSaturation < 0.10 && colorfulFraction < 0.05 {
                return neutralForDarkBackground(
                    sampledR / sampledCount,
                    sampledG / sampledCount,
                    sampledB / sampledCount
                )
            }
        }

        // Post-process: convert to HSL, clamp to a readable range, convert back.
        return boostForDarkBackground(bestColor.r, bestColor.g, bestColor.b)
    }

    /// Converts RGB to HSL, preserving neutral covers as neutral while boosting
    /// genuinely colorful covers so they stay legible on a dark background.
    private func boostForDarkBackground(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let hsl = hslComponents(r, g, b)
        guard hsl.s >= 0.12 else {
            return neutralForDarkBackground(lightness: hsl.l)
        }

        // Enforce readable ranges for dark-background display
        let newL = max(hsl.l, 0.60)       // boost dark colours up to 60 % lightness
        let newS = max(hsl.s, 0.55)       // ensure enough colour so it doesn't look grey
        let clampedL = min(newL, 0.88)    // don't blow out to near-white

        return hslToRgb(hsl.h, min(newS, 1.0), clampedL)
    }

    private func neutralForDarkBackground(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        neutralForDarkBackground(lightness: hslComponents(r, g, b).l)
    }

    private func neutralForDarkBackground(lightness: Double) -> (Double, Double, Double) {
        let component = min(max(lightness, 0.48), 0.74)
        return (component, component, component)
    }

    private func hslComponents(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var h: Double = 0
        var s: Double = 0
        let l = (maxC + minC) / 2.0

        if delta > 0.001 {
            s = delta / (1.0 - abs(2.0 * l - 1.0))
            switch maxC {
            case r: h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: h = (b - r) / delta + 2
            default: h = (r - g) / delta + 4
            }
            h = (h / 6.0).truncatingRemainder(dividingBy: 1.0)
            if h < 0 { h += 1 }
        }

        return (h, s, l)
    }

    private func hslToRgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let x = c * (1.0 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2.0
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(h * 6) % 6 {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }
}

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((val >> 16) & 0xFF) / 255.0,
            green: Double((val >> 8) & 0xFF) / 255.0,
            blue: Double(val & 0xFF) / 255.0,
            opacity: 1
        )
    }
}
