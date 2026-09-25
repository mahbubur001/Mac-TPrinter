import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Generates crisp barcode / QR images (1 pixel per module) via CoreImage.
enum CodeImageGenerator {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Code 128 with no quiet zone; each module is one pixel wide, 1 pixel tall.
    static func code128(_ content: String) -> CGImage? {
        guard let message = content.data(using: .ascii), !message.isEmpty else { return nil }
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = message
        filter.quietSpace = 0
        filter.barcodeHeight = 1
        return render(filter.outputImage)
    }

    /// QR code, error correction M, no quiet zone beyond CoreImage's default 1-module border.
    static func qrCode(_ content: String, correction: String = "M") -> CGImage? {
        guard let message = content.data(using: .utf8), !message.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = message
        filter.correctionLevel = ["L", "M", "Q", "H"].contains(correction) ? correction : "M"
        return render(filter.outputImage)
    }

    private static func render(_ image: CIImage?) -> CGImage? {
        guard let image else { return nil }
        return context.createCGImage(image, from: image.extent)
    }
}
