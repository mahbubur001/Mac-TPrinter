import AppKit
import CoreGraphics

/// Converts a picture into the black/white dots the printer will actually print, at 8 dots/mm.
/// The preview shows this result too, so photos and logos look on screen exactly as on paper.
enum MonochromeImage {
    private static let cache = NSCache<NSString, CGImage>()

    /// Pixel size of the source picture (for aspect ratio), or nil if it isn't a readable image.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let rep = NSBitmapImageRep(data: data) else {
            return NSImage(data: data).map { $0.size }
        }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// Grey-level histogram (256 buckets) of a small copy of the picture, transparency as white.
    static func grayscaleHistogram(_ data: Data) -> [Int]? {
        guard let source = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil), source.width > 0 else { return nil }
        let width = min(source.width, 128)
        let height = max(1, Int(Double(source.height) * Double(width) / Double(source.width)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        autoLevels(pixels, count: width * height)
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<(width * height) { histogram[Int(pixels[i])] += 1 }
        return histogram
    }

    /// Stretches the picture's own darkest → lightest tones to full black → white, in place.
    /// A gold or light-blue logo on white (all tones above the 50 % cut) would otherwise print blank.
    /// The ends are taken at 0.1 % of the pixels, so a few stray specks don't decide the range.
    static func autoLevels(_ pixels: UnsafeMutablePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<count { histogram[Int(pixels[i])] += 1 }
        let ignore = max(1, count / 1000)
        func edge(_ range: some Sequence<Int>) -> Int {
            var seen = 0
            for value in range {
                seen += histogram[value]
                if seen >= ignore { return value }
            }
            return 0
        }
        let low = edge(0...255)
        let high = edge((0...255).reversed())
        guard high - low >= 16 else { return } // flat picture: leave it alone
        let scale = 255 / Double(high - low)
        var lookup = [UInt8](repeating: 0, count: 256)
        for value in 0...255 { lookup[value] = UInt8(max(0, min(255, (Double(value - low) * scale).rounded()))) }
        for i in 0..<count { pixels[i] = lookup[Int(pixels[i])] }
    }

    /// - Parameters:
    ///   - widthDots: output width; height follows the aspect ratio.
    ///   - dithers: Floyd–Steinberg error diffusion (photos) vs. plain threshold (line art).
    ///   - threshold: 0…1. Threshold mode: luminance below this is black. Dither mode: shifts overall
    ///     darkness (0.5 = neutral, higher = darker).
    /// - Returns: 8-bit grey image containing only 0 (black) and 255 (white).
    static func render(_ data: Data, widthDots: Int, dithers: Bool, threshold: Double,
                       inverted: Bool = false, trims: Bool = true, crop: CGRect? = nil) -> CGImage? {
        guard widthDots > 0 else { return nil }
        let key = "\(data.count)-\(data.hashValue)-\(widthDots)-\(dithers)-\(Int(threshold * 100))-\(inverted)-\(trims)-\(crop.map { "\($0)" } ?? "")" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let original = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              original.width > 0 else { return nil }
        // Also trims pictures stored before import-time trimming existed, so old logos fill their width.
        let cropped = crop.flatMap { unit in
            original.cropping(to: CGRect(x: unit.minX * Double(original.width), y: unit.minY * Double(original.height),
                                         width: unit.width * Double(original.width), height: unit.height * Double(original.height)).integral)
        } ?? original
        let source = trims ? (ImageImport.trimMargins(cropped) ?? cropped) : cropped
        let width = widthDots
        let height = max(1, Int((Double(widthDots) * Double(source.height) / Double(source.width)).rounded()))

        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // Transparent areas print as white paper.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let count = width * height
        autoLevels(pixels, count: count)
        if dithers {
            // Bias the error-diffusion midpoint so the slider still controls darkness.
            let bias = Float((threshold - 0.5) * 255)
            var values = (0..<count).map { Float(pixels[$0]) - bias }
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    let old = values[i]
                    let new: Float = old < 128 ? 0 : 255
                    pixels[i] = UInt8(new)
                    let error = old - new
                    if x + 1 < width { values[i + 1] += error * 7 / 16 }
                    if y + 1 < height {
                        if x > 0 { values[i + width - 1] += error * 3 / 16 }
                        values[i + width] += error * 5 / 16
                        if x + 1 < width { values[i + width + 1] += error * 1 / 16 }
                    }
                }
            }
        } else {
            let cut = UInt8(max(0, min(255, threshold * 255)))
            for i in 0..<count { pixels[i] = pixels[i] < cut ? 0 : 255 }
        }

        if inverted { for i in 0..<count { pixels[i] = 255 - pixels[i] } }
        guard let image = context.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
