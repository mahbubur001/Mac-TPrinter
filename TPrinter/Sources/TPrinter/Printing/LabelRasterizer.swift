import CoreGraphics
import Foundation
import SwiftUI

/// A 1-bit, TSPL-ready bitmap: MSB first, `0` = black dot.
struct MonochromeBitmap: Equatable {
    let widthBytes: Int
    let height: Int
    let rows: Data

    var widthDots: Int { widthBytes * 8 }
}

enum LabelRasterizer {
    /// Converts any CGImage to a TSPL bitmap by drawing it onto white and thresholding.
    /// The image is drawn at 1 pixel = 1 dot; `widthDots` is rounded up to a multiple of 8.
    static func monochrome(from image: CGImage, widthDots: Int, heightDots: Int, threshold: UInt8 = 128) -> MonochromeBitmap? {
        let widthBytes = (widthDots + 7) / 8
        let paddedWidth = widthBytes * 8
        guard let context = CGContext(
            data: nil,
            width: paddedWidth,
            height: heightDots,
            bitsPerComponent: 8,
            bytesPerRow: paddedWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: paddedWidth, height: heightDots))
        context.interpolationQuality = .none
        // CGContext origin is bottom-left; drawing the image into the full rect keeps it upright.
        context.draw(image, in: CGRect(x: 0, y: heightDots - image.height, width: image.width, height: image.height))

        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        var rows = Data(count: widthBytes * heightDots)
        rows.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for y in 0..<heightDots {
                // CGContext memory is top row first.
                let rowStart = y * paddedWidth
                for byteIndex in 0..<widthBytes {
                    var byte: UInt8 = 0xFF // all white
                    for bit in 0..<8 {
                        let x = byteIndex * 8 + bit
                        if pixels[rowStart + x] < threshold {
                            byte &= ~(0x80 >> UInt8(bit))
                        }
                    }
                    out[y * widthBytes + byteIndex] = byte
                }
            }
        }
        return MonochromeBitmap(widthBytes: widthBytes, height: heightDots, rows: rows)
    }

    /// Renders a single element at print resolution (for elements the printer can't draw itself).
    @MainActor
    static func render(_ element: LabelElement) -> MonochromeBitmap? {
        let renderer = ImageRenderer(content: LabelElementView(element: element).background(Color.white))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        return monochrome(from: image, widthDots: image.width, heightDots: image.height)
    }

    /// The label repeated at each cell origin (mm) of a multi-label arrangement.
    @MainActor
    static func renderSheet(_ document: LabelDocument, cellOrigins: [CGPoint]) -> MonochromeBitmap? {
        let renderer = ImageRenderer(content: LabelRenderView(document: document))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let label = renderer.cgImage else { return nil }
        let sheet = document.arrangement.sheetSize(label: CGSize(width: document.widthMM, height: document.heightMM))
        let width = Int((sheet.width * dotsPerMM).rounded()), height = Int((sheet.height * dotsPerMM).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        for origin in cellOrigins {
            // CGContext's origin is bottom-left; cell origins are top-left.
            let x = origin.x * dotsPerMM, top = origin.y * dotsPerMM
            context.draw(label, in: CGRect(x: x, y: Double(height) - top - Double(label.height),
                                           width: Double(label.width), height: Double(label.height)))
        }
        guard let image = context.makeImage() else { return nil }
        return monochrome(from: image, widthDots: width, heightDots: height)
    }

    /// Renders the label exactly as the preview shows it, at 1 point = 1 dot.
    @MainActor
    static func render(_ document: LabelDocument) -> MonochromeBitmap? {
        let renderer = ImageRenderer(content: LabelRenderView(document: document))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        return monochrome(from: image, widthDots: document.widthDots, heightDots: document.heightDots)
    }
}
