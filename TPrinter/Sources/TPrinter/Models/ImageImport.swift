import AppKit
import UniformTypeIdentifiers

/// Turns an image file into an image element sized to fit the label.
enum ImageImport {
    enum ImportError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "“\(name)” isn't an image TPrinter can read. Try PNG, JPEG, HEIC, TIFF or PDF."
            }
        }
    }

    /// Largest width worth keeping: a 120 mm label at 8 dots/mm. Bigger pictures are scaled down so
    /// templates stay small.
    static let maxPixelWidth = 960

    @MainActor
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Choose an image or logo for the label"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// - Parameter label: label size in mm; the image is fitted inside it with a 2 mm margin.
    static func element(from url: URL, label: CGSize) throws -> LabelElement {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url), let stored = normalized(data), let size = MonochromeImage.pixelSize(of: stored),
              size.width > 0, size.height > 0 else { throw ImportError.unreadable(url.lastPathComponent) }

        var element = LabelElement.image(stored, named: name)
        let aspect = size.width / size.height
        element.imageWidthMM = max(3, min(label.width - 4, (label.height - 4) * aspect)).rounded(toPlaces: 1)
        // Logos with few colours print best as line art; photos need dithering.
        element.dithers = !looksLikeLineArt(stored)
        // Shrinking to printer dots turns thin strokes grey; a darker cut keeps them as solid ink
        // (tested on a gold logo at 63 dots wide: 0.5 broke the lettering, 0.75 kept it readable).
        element.imageThreshold = element.dithers ? 0.5 : 0.75
        return element
    }

    /// PNG, at most `maxPixelWidth` wide. Also renders PDFs / vector images to pixels.
    static func normalized(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let width = min(cg.width, maxPixelWidth)
        let height = max(1, Int(Double(cg.height) * Double(width) / Double(cg.width)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard var result = context.makeImage() else { return nil }
        if let trimmed = trimMargins(result) { result = trimmed }
        return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    }

    /// Crops empty white / transparent margins (plus a small border), so a logo with a big canvas
    /// fills its element instead of printing tiny. Returns nil if there's nothing to trim.
    static func trimMargins(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return nil }
        let p = raw.assumingMemoryBound(to: UInt8.self)
        func isEmpty(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            let alpha = Int(p[i + 3])
            if alpha < 16 { return true }
            // Un-premultiply, then "near white" counts as paper.
            let luminance = (299 * Int(p[i]) + 587 * Int(p[i + 1]) + 114 * Int(p[i + 2])) / 1000 * 255 / max(alpha, 1)
            return luminance > 245
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where !isEmpty(x, y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil } // blank picture
        let pad = max(2, Int(Double(max(maxX - minX, maxY - minY)) * 0.03))
        // Context memory is top row first; CGImage.cropping uses the same top-left origin.
        let crop = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                          width: min(width, maxX + pad + 1) - max(0, minX - pad),
                          height: min(height, maxY + pad + 1) - max(0, minY - pad))
        guard crop.width < CGFloat(width) || crop.height < CGFloat(height) else { return nil }
        return image.cropping(to: crop)
    }

    /// Logos and text art: either mostly plain paper-white background (a shaded gold logo on white is
    /// ~87 % white but its ink covers every tone), or almost only black and white. Photos are neither.
    static func looksLikeLineArt(_ data: Data) -> Bool {
        guard let gray = MonochromeImage.grayscaleHistogram(data) else { return false }
        let total = Double(gray.reduce(0, +))
        guard total > 0 else { return false }
        let paper = Double(gray[224..<256].reduce(0, +)) / total
        let extremes = Double(gray[0..<40].reduce(0, +) + gray[216..<256].reduce(0, +)) / total
        return paper > 0.6 || extremes > 0.9
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
