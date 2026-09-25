import AppKit
import Foundation
import Testing
@testable import TPrinter

@MainActor
struct TemplateFilesTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterFiles-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func template(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name).appendingPathExtension("tprlabel")
        try LabelTemplate.encode(LabelDocument()).write(to: url)
        return url
    }

    @Test func importCopiesWithUniqueNamesAndRejectsOtherFiles() throws {
        let source = try folder(), library = try folder()
        let hello = try template(named: "Hello", in: source)
        _ = try template(named: "Hello", in: library)             // name already taken in the library
        let imported = try TemplateFiles.importFiles([hello], into: library)
        #expect(imported.map(\.lastPathComponent) == ["Hello 2.tprlabel"])
        #expect(FileManager.default.fileExists(atPath: hello.path), "import copies, never moves")

        let bogus = source.appendingPathComponent("notes.tprlabel")
        try Data("hi".utf8).write(to: bogus)
        #expect(throws: TemplateFiles.FileError.self) { try TemplateFiles.importFiles([bogus], into: library) }
    }

    @Test func duplicateAndRename() throws {
        let dir = try folder()
        let original = try template(named: "Price tag", in: dir)
        let copy = try TemplateFiles.duplicate(original)
        #expect(copy.lastPathComponent == "Price tag copy.tprlabel")
        #expect(try TemplateFiles.duplicate(original).lastPathComponent == "Price tag copy 2.tprlabel")

        let renamed = try TemplateFiles.rename(copy, to: "Sale / red")
        #expect(renamed.lastPathComponent == "Sale - red.tprlabel")
        #expect(throws: TemplateFiles.FileError.self) { try TemplateFiles.rename(renamed, to: "Price tag") }
    }

    @Test func pngExportIsFourTimesPrintResolution() throws {
        let data = try TemplateFiles.pngData(LabelDocument())
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == 240 * 4 && rep.pixelsHigh == 120 * 4)
    }

    @Test func sessionFollowsARenamedTemplate() throws {
        let dir = try folder()
        let url = try template(named: "Old", in: dir)
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterMoved-\(UUID())")!)
        session.load(url)
        let renamed = try TemplateFiles.rename(url, to: "New")
        session.templateMoved(from: url, to: renamed)
        #expect(session.fileURL == renamed)
        #expect(session.recentURLs.first == renamed)
        #expect(session.displayName == "New")
    }
}

@MainActor
struct DuplicateListingTests {
    /// A duplicate of a template outside the templates folder must still be listed (via recents).
    @Test func duplicateJoinsRecents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterDup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = dir.appendingPathComponent("SHAI OUD.tprlabel")
        try LabelTemplate.encode(LabelDocument()).write(to: original)
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterDupRecents-\(UUID())")!)
        session.addRecent(original)

        let copy = try TemplateFiles.duplicate(original)
        session.addRecent(copy)
        #expect(session.recentURLs.first == copy)
        #expect(session.recentURLs.contains(original))
    }
}
