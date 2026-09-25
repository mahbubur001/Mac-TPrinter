import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File operations for templates: import, duplicate, rename, trash, export (file or PNG).
enum TemplateFiles {
    enum FileError: LocalizedError {
        case notATemplate(String)
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .notATemplate(let name): "“\(name)” isn't a TPrinter template."
            case .nameTaken(let name): "A template called “\(name)” already exists."
            }
        }
    }

    /// `base.tprlabel`, or `base 2.tprlabel`, `base 3.tprlabel`… if taken.
    static func uniqueURL(named base: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(LabelTemplate.fileExtension)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(LabelTemplate.fileExtension)
            n += 1
        }
        return candidate
    }

    /// Copies template files into `folder` (skipping ones already there). Returns the new files.
    static func importFiles(_ urls: [URL], into folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var imported: [URL] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url), (try? LabelTemplate.decode(data)) != nil else {
                throw FileError.notATemplate(url.lastPathComponent)
            }
            if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
            let target = uniqueURL(named: url.deletingPathExtension().lastPathComponent, in: folder)
            try FileManager.default.copyItem(at: url, to: target)
            imported.append(target)
        }
        return imported
    }

    /// "Name copy" next to the original.
    static func duplicate(_ url: URL) throws -> URL {
        let target = uniqueURL(named: url.deletingPathExtension().lastPathComponent + " copy", in: url.deletingLastPathComponent())
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    static func rename(_ url: URL, to name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        let target = url.deletingLastPathComponent().appendingPathComponent(clean).appendingPathExtension(LabelTemplate.fileExtension)
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FileError.nameTaken(clean) }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Rewrites the template with a new category (the media category it's grouped by). Empty = none.
    static func setCategory(_ category: String, of url: URL) throws {
        var document = try LabelTemplate.decode(Data(contentsOf: url))
        document.mediaCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        try LabelTemplate.encode(document).write(to: url, options: .atomic)
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Asks where to save a copy of the template file.
    @MainActor
    static func exportTemplate(_ url: URL) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tprinterLabel]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.message = "Export a copy of this template"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: url, to: target)
    }

    /// Asks where to save a PNG of the label as it prints (4 px per printer dot, so it stays sharp).
    @MainActor
    static func exportImage(_ document: LabelDocument, name: String) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(name).png"
        panel.message = "Export the label as an image"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try pngData(document).write(to: target, options: .atomic)
    }

    @MainActor
    static func pngData(_ document: LabelDocument, scale: CGFloat = 4) throws -> Data {
        let renderer = ImageRenderer(content: LabelRenderView(document: document))
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw LabelPrintError.renderFailed }
        return data
    }
}
