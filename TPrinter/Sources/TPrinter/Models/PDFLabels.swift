import AppKit
import CoreGraphics
import PDFKit

/// Ready-made labels from PDFs (courier parcel labels such as Steadfast's) or images: every page
/// becomes one label on the chosen media, rotated to match the label's shape, trimmed of white margins,
/// fitted, and printed as sharp black line art.
enum PDFLabels {
    /// One page to print: page `index` of a PDF, or a whole image file (index 0).
    struct Page: Identifiable, Hashable {
        let url: URL
        let index: Int
        let pageCount: Int
        var id: String { "\(url.path)#\(index)" }
        var title: String {
            pageCount > 1 ? "\(url.deletingPathExtension().lastPathComponent) · page \(index + 1)"
                          : url.deletingPathExtension().lastPathComponent
        }
    }

    struct Options: Equatable {
        /// Turn the page 90° when its shape doesn't match the label's (portrait page on a landscape label…).
        var rotates = true
        /// Crop white page margins, so the label content fills the label.
        var trims = true
        /// Sharp black and white (text, barcodes). Off = dithered, for photos.
        var lineArt = true
        /// Darkness for line art / photos (0.2 … 0.95; higher prints more as black).
        var threshold = 0.6
        /// Space left around the content on the label, mm.
        var marginMM = 1.0
    }

    /// Pages in the given files, in order (PDFs expand to one entry per page).
    static func pages(in urls: [URL]) -> [Page] {
        urls.flatMap { url -> [Page] in
            if url.pathExtension.lowercased() == "pdf" {
                guard let pdf = CGPDFDocument(url as CFURL), pdf.numberOfPages > 0 else { return [] }
                return (0..<pdf.numberOfPages).map { Page(url: url, index: $0, pageCount: pdf.numberOfPages) }
            }
            return NSImage(contentsOf: url) == nil ? [] : [Page(url: url, index: 0, pageCount: 1)]
        }
    }

    /// The label for one page on `media`. nil when the page can't be read.
    @MainActor
    static func document(for page: Page, media: Media, options: Options) -> LabelDocument? {
        var document = LabelDocument(media: media)
        document.copies = 1
        let label = CGSize(width: document.widthMM, height: document.heightMM)
        let room = CGSize(width: max(label.width - 2 * options.marginMM, 1), height: max(label.height - 2 * options.marginMM, 1))

        // Render big enough for the printer (8 dots/mm) with room to spare for trimming.
        let targetPixels = Int(max(room.width, room.height) * dotsPerMM * 2)
        guard var image = render(page, longestSide: min(max(targetPixels, 600), 2400)) else { return nil }

        let pageIsLandscape = image.width > image.height
        let labelIsLandscape = room.width > room.height
        if options.rotates, pageIsLandscape != labelIsLandscape, abs(image.width - image.height) > min(image.width, image.height) / 10,
           let turned = rotated(image) {
            image = turned
        }
        if options.trims, let trimmed = ImageImport.trimMargins(image) { image = trimmed }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }

        // Fit inside the label (keep proportions), centred.
        let aspect = Double(image.height) / Double(max(image.width, 1))
        let width = min(room.width, room.height / aspect)
        var element = LabelElement.image(png, named: page.title)
        element.imageWidthMM = (width * 10).rounded(.down) / 10
        element.x = ((label.width - element.imageWidthMM) / 2 * 10).rounded() / 10
        element.y = ((label.height - element.imageWidthMM * aspect) / 2 * 10).rounded() / 10
        element.dithers = !options.lineArt
        element.imageThreshold = options.threshold
        element.trimsImage = false // already trimmed (and fitted) above
        document.elements = [element]
        return document
    }

    /// The page as an opaque white-backed bitmap, longest side `longestSide` pixels.
    static func render(_ page: Page, longestSide: Int) -> CGImage? {
        if page.url.pathExtension.lowercased() == "pdf" {
            guard let pdf = CGPDFDocument(page.url as CFURL), let pdfPage = pdf.page(at: page.index + 1) else { return nil }
            let box = pdfPage.getBoxRect(.cropBox)
            // Respect the page's own rotation (scanned / exported labels often use /Rotate 90).
            let quarterTurns = ((pdfPage.rotationAngle % 360) + 360) % 360 / 90
            let size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
            guard size.width > 0, size.height > 0 else { return nil }
            let scale = CGFloat(longestSide) / max(size.width, size.height)
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard let context = whiteContext(width: width, height: height) else { return nil }
            context.interpolationQuality = .high
            let transform = pdfPage.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                        rotate: 0, preserveAspectRatio: true)
            context.concatenate(transform)
            context.drawPDFPage(pdfPage)
            return context.makeImage()
        }
        guard let image = NSImage(contentsOf: page.url) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let scale = min(CGFloat(longestSide) / CGFloat(max(cg.width, cg.height)), 1)
        let width = max(Int(CGFloat(cg.width) * scale), 1), height = max(Int(CGFloat(cg.height) * scale), 1)
        guard let context = whiteContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func whiteContext(width: Int, height: Int) -> CGContext? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// Quarter turn clockwise.
    static func rotated(_ image: CGImage) -> CGImage? {
        guard let context = whiteContext(width: image.height, height: image.width) else { return nil }
        context.translateBy(x: 0, y: CGFloat(image.width))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
