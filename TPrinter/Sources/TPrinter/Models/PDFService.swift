import AppKit

/// "Print with TPrinter" in the PDF ▾ menu of every macOS print window. macOS lists whatever is in
/// ~/Library/PDF Services; choosing an app there saves the document as a temporary PDF and opens it
/// with that app. TPrinter then shows Print PDF Labels with it (see `LabelSession.receivePDFs`).
enum PDFService {
    static let menuTitle = "Print with TPrinter"

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/PDF Services", isDirectory: true)
    }

    static var entry: URL { folder.appendingPathComponent(menuTitle) }

    /// Whether the menu entry exists (and points at an app that still exists).
    static var isInstalled: Bool {
        guard let target = try? URL(resolvingAliasFileAt: entry) else { return false }
        return FileManager.default.fileExists(atPath: target.path)
    }

    /// Adds (or refreshes) the entry: a Finder alias to this app, so it follows the app if moved.
    static func install(app: URL = Bundle.main.bundleURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? entry.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: entry.path)) != nil {
            try fm.removeItem(at: entry)
        }
        let bookmark = try app.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: entry)
    }

    static func uninstall() throws {
        if (try? entry.checkResourceIsReachable()) == true { try FileManager.default.removeItem(at: entry) }
    }

    /// Keeps the entry pointing at the running app (only a real .app bundle, not `swift run`).
    static func refreshIfEnabled() {
        guard UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let current = try? URL(resolvingAliasFileAt: entry)
        if current?.standardizedFileURL.path != Bundle.main.bundleURL.standardizedFileURL.path { try? install() }
    }

    static let enabledKey = "pdfService.enabled"

    /// Where received PDFs are kept while TPrinter prints them (the print system deletes its own copy).
    static var inbox: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TPrinter/Incoming PDFs", isDirectory: true)
    }

    /// Copies incoming PDFs into the inbox (unique names), clearing ones older than a week.
    static func keep(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        for old in (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < weekAgo { try? fm.removeItem(at: old) }
        }
        return urls.compactMap { url in
            if url.path.hasPrefix(inbox.path) { return url }
            var target = inbox.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = inbox.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).pdf")
                n += 1
            }
            do { try fm.copyItem(at: url, to: target); return target } catch { return nil }
        }
    }
}
