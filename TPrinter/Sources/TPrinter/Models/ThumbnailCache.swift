import AppKit
import CryptoKit
import SwiftUI

/// Saved label thumbnails, so the Templates page and Recent work don't re-render every label (image
/// dithering is the slow part) each time they appear. Keyed by a hash of the template's content, so
/// an edited template gets a new thumbnail and identical ones share one. PNGs live in
/// ~/Library/Caches/TPrinter/Thumbnails (safe to delete; they're rebuilt on demand).
@MainActor
enum ThumbnailCache {
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TPrinter/Thumbnails", isDirectory: true)
    }

    /// Longest side of a stored thumbnail, in pixels (sharp on Retina at card size).
    static let maxPixels: CGFloat = 480

    private static let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    /// Content hash of a label (what the thumbnail depends on).
    static func key(for document: LabelDocument) -> String? {
        guard let data = try? LabelTemplate.encode(document) else { return nil }
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The label's thumbnail: from memory, else from disk, else rendered now and saved.
    static func image(for document: LabelDocument) -> NSImage? {
        guard let key = key(for: document) else { return render(document) }
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let file = folder.appendingPathComponent(key).appendingPathExtension("png")
        if let stored = NSImage(contentsOf: file) {
            memory.setObject(stored, forKey: key as NSString)
            return stored
        }
        guard let rendered = render(document) else { return nil }
        memory.setObject(rendered, forKey: key as NSString)
        if let tiff = rendered.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
        return rendered
    }

    /// Renders the label on white paper, fitted to `maxPixels`.
    static func render(_ document: LabelDocument) -> NSImage? {
        let longest = CGFloat(max(document.widthDots, document.heightDots))
        guard longest > 0 else { return nil }
        let renderer = ImageRenderer(content: LabelRenderView(document: document))
        renderer.scale = min(maxPixels / longest, 2)
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: document.widthDots, height: document.heightDots))
    }

    /// Deletes thumbnails not used for `days` days (called at launch, so the cache can't grow forever).
    static func prune(olderThan days: Double = 60) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentAccessDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        for file in files {
            let used = (try? file.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
            if used < cutoff { try? fm.removeItem(at: file) }
        }
    }

    static func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A template's saved thumbnail, fitted into `maxSize` (label proportions kept). Shows a blank paper
/// tile while the thumbnail loads.
struct LabelThumbnail: View {
    let document: LabelDocument
    let maxSize: CGSize
    var cornerRadius: CGFloat = 3
    @State private var image: NSImage?

    private var fitted: CGSize {
        let w = CGFloat(max(document.widthDots, 1)), h = CGFloat(max(document.heightDots, 1))
        let factor = min(maxSize.width / w, maxSize.height / h)
        return CGSize(width: w * factor, height: h * factor)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Rectangle().fill(Color.white)
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: document) {
            image = ThumbnailCache.image(for: document)
        }
        .accessibilityLabel("\(document.widthMM.formatted()) by \(document.heightMM.formatted()) millimetre label")
    }
}
