import AppKit
import Foundation
import Testing
@testable import TPrinter

@MainActor
struct NewElementsTests {
    // MARK: Barcodes

    @Test func ean13AddsTheCheckDigit() throws {
        let encoded = try BarcodeEncoder.encode("400638133393", as: .ean13)
        #expect(encoded.text == "4006381333931")
        #expect(encoded.modules.count == 95)
        #expect(try BarcodeEncoder.encode("4006381333931", as: .ean13) == encoded)
    }

    @Test func wrongCheckDigitIsRejected() {
        #expect(throws: BarcodeEncoder.EncodeError.self) { try BarcodeEncoder.encode("4006381333932", as: .ean13) }
        #expect(throws: BarcodeEncoder.EncodeError.self) { try BarcodeEncoder.encode("12AB", as: .ean8) }
    }

    @Test func otherSymbologiesEncode() throws {
        #expect(try BarcodeEncoder.encode("9638507", as: .ean8).text == "96385074")
        #expect(try BarcodeEncoder.encode("03600029145", as: .upcA).text == "036000291452")
        #expect(try BarcodeEncoder.encode("1540014128876", as: .itf14).text == "15400141288763")
        #expect(try BarcodeEncoder.encode("abc-12", as: .code39).text == "ABC-12")
        #expect(try BarcodeEncoder.encode("A40156B", as: .codabar).text == "40156")
        // UPC-A is EAN-13 with a leading zero: same bars.
        #expect(try BarcodeEncoder.encode("03600029145", as: .upcA).modules
            == BarcodeEncoder.encode("003600029145", as: .ean13).modules)
    }

    @Test func nonCode128BarcodesPrintAsBitmapInNativeMode() throws {
        var element = LabelElement.make(.barcode)
        element.barcodeType = .ean13
        element.content = "400638133393"
        var document = LabelDocument()
        document.printMethod = .nativeTSPL
        document.elements = [element]
        let text = String(decoding: try LabelPrintService.job(for: document), as: UTF8.self)
        #expect(text.contains("BITMAP") && !text.contains("BARCODE"))
    }

    // MARK: Date & counter

    @Test func dateUsesFormatAndOffset() {
        var element = LabelElement.make(.date)
        element.dateFormat = "yyyy-MM-dd"
        element.dateOffsetDays = 7
        let day = DateComponents(calendar: .current, year: 2026, month: 9, day: 25, hour: 12).date!
        #expect(element.displayText(counterOffset: 0, date: day) == "2026-10-02")
    }

    @Test func counterPadsAndAdvances() {
        var element = LabelElement.make(.counter)
        element.counterNext = 7; element.counterStep = 5; element.counterDigits = 3
        element.counterPrefix = "#"; element.counterSuffix = "-A"
        #expect(element.displayText == "#007-A")
        #expect(element.counterText(offset: 2) == "#017-A")
        var document = LabelDocument()
        document.elements = [element, LabelElement.make(.text)]
        #expect(document.advancingCounters(by: 3).elements[0].counterNext == 22)
        #expect(document.advancingCounters(by: 3).elements[1] == document.elements[1])
    }

    @Test func eachCopyGetsItsOwnCounterValue() throws {
        var element = LabelElement.make(.counter)
        element.counterNext = 41
        var document = LabelDocument()
        document.printMethod = .nativeTSPL
        document.elements = [element]
        let second = String(decoding: try LabelPrintService.job(for: document.advancingCounters(by: 1)), as: UTF8.self)
        #expect(second.contains("\"0042\""))
    }

    @Test func sessionCounterContinuesAfterPrinting() {
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterCounter-\(UUID())")!)
        session.document.elements = [LabelElement.make(.counter)]
        session.advanceCounters(by: 5)
        #expect(session.document.elements[0].counterNext == 6)
    }

    // MARK: Shapes

    @Test func shapeRendersAtItsSize() {
        var element = LabelElement.make(.shape)
        element.shapeWidthMM = 10; element.shapeHeightMM = 5
        let size = ElementGeometry.sizeMM(of: element)
        #expect(abs(size.width - 10) < 0.2 && abs(size.height - 5) < 0.2)
        element.shapeKind = .line
        #expect(ElementGeometry.sizeMM(of: element).height < 1)
    }

    @Test func resizingAShapeStretchesOneAxis() {
        let element = LabelElement.make(.shape)
        let size = ElementGeometry.sizeMM(of: element)
        let wider = ElementResize.resized(element, handle: .trailing, translationMM: CGSize(width: 3, height: 0), sizeMM: size)
        #expect(abs(wider.shapeWidthMM - (element.shapeWidthMM + 3)) < 0.05)
        #expect(wider.shapeHeightMM == element.shapeHeightMM)
    }

    @Test func filledShapePrintsBlackDots() throws {
        var element = LabelElement.make(.shape)
        element.shapeFilled = true
        let bitmap = try #require(LabelRasterizer.render(element))
        #expect(bitmap.rows.contains(0x00))
    }

    @Test func newFieldsRoundTrip() throws {
        var shape = LabelElement.make(.shape)
        shape.shapeKind = .ellipse; shape.dashed = true; shape.lineWidthMM = 0.5
        var counter = LabelElement.make(.counter)
        counter.counterNext = 99; counter.counterPrefix = "B"
        var image = LabelElement.make(.image)
        image.setCrop(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        var barcode = LabelElement.make(.barcode)
        barcode.barcodeType = .code39
        var document = LabelDocument()
        document.elements = [shape, counter, image, barcode, LabelElement.make(.date)]
        #expect(try LabelTemplate.decode(LabelTemplate.encode(document)) == document)
    }

    // MARK: Crop

    @Test func cropKeepsOnlyTheSelectedPart() throws {
        // Left half black, right half white: cropping to the right half leaves no black.
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 20, height: 20).fill()
            return true
        }
        let data = try #require(image.tiffRepresentation)
        let right = try #require(MonochromeImage.render(data, widthDots: 40, dithers: false, threshold: 0.5, trims: false,
                                                        crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        let left = try #require(MonochromeImage.render(data, widthDots: 40, dithers: false, threshold: 0.5, trims: false,
                                                       crop: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        #expect(darkFraction(right) < 0.05)
        #expect(darkFraction(left) > 0.95)
    }

    private func darkFraction(_ image: CGImage) -> Double {
        let bitmap = LabelRasterizer.monochrome(from: image, widthDots: image.width, heightDots: image.height)!
        var black = 0
        for y in 0..<bitmap.height {
            for x in 0..<image.width {
                let byte = bitmap.rows[y * bitmap.widthBytes + x / 8]
                if byte & (0x80 >> UInt8(x % 8)) == 0 { black += 1 }
            }
        }
        return Double(black) / Double(image.width * bitmap.height)
    }
}

@MainActor
struct MultilineTextTests {
    @Test func multilineTextPrintsAsBitmapInNativeMode() throws {
        var element = LabelElement.make(.text)
        element.content = "HAWAS\nICE"
        #expect(!element.isPlainText)
        var document = LabelDocument()
        document.printMethod = .nativeTSPL
        document.elements = [element]
        let text = String(decoding: try LabelPrintService.job(for: document), as: UTF8.self)
        #expect(text.contains("BITMAP") && !text.contains("TEXT "))
    }

    @Test func secondLineMakesTheElementTaller() {
        var element = LabelElement.make(.text)
        element.content = "HAWAS"
        let one = ElementGeometry.sizeMM(of: element)
        element.content = "HAWAS\nICE"
        let two = ElementGeometry.sizeMM(of: element)
        #expect(two.height > one.height * 1.6)
    }
}

@MainActor
struct BackNavigationTests {
    @Test func backReturnsToTheTabTheEditorWasOpenedFrom() {
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterBack-\(UUID())")!)
        session.route = .home(.templates)
        session.route = .editor
        session.goBack()
        #expect(session.route == .home(.templates))
        session.route = .home(.history)
        session.startNewLabel()
        session.route = .editor
        session.goBack()
        #expect(session.route == .home(.history))
    }
}

@MainActor
struct ClipboardTests {
    private func pasteboard() -> NSPasteboard { NSPasteboard(name: .init("TPrinterTest-\(UUID())")) }

    @Test func copiedElementsPasteWithNewIdsAndNudgedInTheSameLabel() throws {
        let board = pasteboard()
        var element = LabelElement.make(.text)
        element.content = "HAWAS"; element.fontFamily = "DIN Condensed"
        ElementClipboard.copy([element], to: board)
        let copied = try #require(ElementClipboard.elements(from: board))
        #expect(copied == [element])
        var same = LabelDocument(); same.elements = [element]
        let pasted = ElementClipboard.pasteable(copied, into: same)[0]
        #expect(pasted.id != element.id && pasted.x == element.x + 1 && pasted.fontFamily == "DIN Condensed")
        let other = ElementClipboard.pasteable(copied, into: LabelDocument())[0]
        #expect(other.x == element.x && other.y == element.y)
    }

    @Test func pasteStyleKeepsContentAndPosition() {
        var source = LabelElement(kind: .text, content: "Source", x: 1, y: 1, fontSizeMM: 6)
        source.fontFamily = "serif"; source.fontWeight = .heavy; source.invertsText = true
        let target = LabelElement(kind: .text, content: "Target", x: 10, y: 5, fontSizeMM: 3)
        let styled = target.applyingStyle(of: source)
        #expect(styled.content == "Target" && styled.x == 10 && styled.y == 5 && styled.id == target.id)
        #expect(styled.fontFamily == "serif" && styled.fontWeight == .heavy && styled.invertsText && styled.fontSizeMM == 6)
        // Text style onto a counter keeps the counter's own settings.
        var counter = LabelElement.make(.counter); counter.counterPrefix = "#"
        let styledCounter = counter.applyingStyle(of: source)
        #expect(styledCounter.kind == .counter && styledCounter.counterPrefix == "#" && styledCounter.fontFamily == "serif")
        #expect(!LabelElement.make(.barcode).acceptsStyle(of: source))
    }
}

@MainActor
struct DiscardPromptTests {
    @Test func unsavedChangesAskBeforeReplacingAndDontSaveContinues() {
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterDiscard-\(UUID())")!)
        session.newDocument(size: CGSize(width: 30, height: 15))
        session.document.elements.append(LabelElement.make(.text))
        #expect(session.isDirty)
        session.newDocument(size: CGSize(width: 50, height: 30))
        #expect(session.discardPrompt != nil && session.document.widthMM == 30) // waiting for an answer
        session.answerDiscardPrompt(save: nil)                                 // Cancel
        #expect(session.discardPrompt == nil && session.document.widthMM == 30)
        session.newDocument(size: CGSize(width: 50, height: 30))
        session.answerDiscardPrompt(save: false)                               // Don't Save
        #expect(session.document.widthMM == 50 && !session.isDirty)
    }
}

@MainActor
struct MultiSelectTests {
    private func session(with elements: [LabelElement]) -> LabelSession {
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterMulti-\(UUID())")!)
        session.newDocument(size: CGSize(width: 60, height: 20))
        session.document.elements = elements
        return session
    }

    private func shape(x: Double, y: Double, width: Double) -> LabelElement {
        var element = LabelElement.make(.shape)
        element.x = x; element.y = y; element.shapeWidthMM = width; element.shapeHeightMM = 4
        return element
    }

    @Test func distributeMakesEqualGapsAndKeepsTheEnds() {
        let a = shape(x: 0, y: 0, width: 5), b = shape(x: 8, y: 0, width: 10), c = shape(x: 40, y: 0, width: 5)
        let s = session(with: [a, b, c])
        s.distributeElements([a.id, b.id, c.id], .horizontal)
        let xs = s.document.elements.map(\.x)
        let widths = s.document.elements.map { ElementGeometry.sizeMM(of: $0).width }
        #expect(abs(xs[0] - 0) < 0.05 && abs(xs[2] - 40) < 0.05)
        let gap1 = xs[1] - (xs[0] + widths[0]), gap2 = xs[2] - (xs[1] + widths[1])
        #expect(abs(gap1 - gap2) < 0.05)
    }

    @Test func alignLeftLinesUpOnTheLeftmostEdge() {
        let a = shape(x: 3, y: 0, width: 5), b = shape(x: 9, y: 6, width: 10)
        let s = session(with: [a, b])
        s.alignElements([a.id, b.id], .left)
        #expect(s.document.elements.allSatisfy { abs($0.x - 3) < 0.01 })
        s.alignElements([a.id, b.id], .top)
        #expect(s.document.elements.allSatisfy { abs($0.y) < 0.01 })
    }

    @Test func groupMoveSkipsLockedAndGroupDeleteIsOneStep() {
        var locked = shape(x: 5, y: 5, width: 5); locked.isLocked = true
        let free = shape(x: 1, y: 1, width: 5)
        let s = session(with: [locked, free])
        s.moveElements([locked.id, free.id], by: CGSize(width: 2, height: 1))
        #expect(s.document.elements[0].x == 5 && s.document.elements[1].x == 3 && s.document.elements[1].y == 2)
        let copies = s.duplicateElements([locked.id, free.id])
        #expect(copies.count == 2 && s.document.elements.count == 4)
        s.deleteElements(Set(copies))
        #expect(s.document.elements.count == 2)
    }
}

@MainActor
struct TextBoxTests {
    @Test func fixedBoxWrapsAndHidesTheRest() {
        var element = LabelElement(kind: .text, content: "ALICI: Musteri Adi sasas sasas asas", x: 0, y: 0, fontSizeMM: 3)
        element.wrapsText = true
        element.fitWidthMM = 12
        let grown = ElementGeometry.sizeMM(of: element)
        #expect(grown.height > 6) // wraps onto several lines
        element.boxHeightMM = 4
        let boxed = ElementGeometry.sizeMM(of: element)
        #expect(abs(boxed.height - 4) < 0.2 && abs(boxed.width - 12) < 0.2)
    }

    @Test func boxHeightRoundTrips() throws {
        var element = LabelElement.make(.text)
        element.wrapsText = true; element.boxHeightMM = 5.5
        var document = LabelDocument(); document.elements = [element]
        #expect(try LabelTemplate.decode(LabelTemplate.encode(document)).elements[0].boxHeightMM == 5.5)
    }
}

@MainActor
struct HiddenTextTests {
    @Test func detectsCutOffLinesOnlyInAFixedBox() {
        var element = LabelElement(kind: .text, content: "ALICI: Musteri Adi sasas sasas asas", x: 0, y: 0, fontSizeMM: 3)
        element.wrapsText = true; element.fitWidthMM = 12
        #expect(!ElementGeometry.hidesText(element))
        element.boxHeightMM = 4
        #expect(ElementGeometry.hidesText(element))
        element.boxHeightMM = 40
        #expect(!ElementGeometry.hidesText(element))
    }
}

@MainActor
struct TemplateCategoryTests {
    @Test func changingTheCategoryRewritesTheFileAndKeepsTheOpenLabelClean() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterCategory-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Vampire.tprlabel")
        var document = LabelDocument(); document.mediaCategory = ""
        try LabelTemplate.encode(document).write(to: url)

        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterCategory-\(UUID())")!)
        session.load(url)
        try session.setCategory(" Perfume ", of: url)
        #expect(try LabelTemplate.decode(Data(contentsOf: url)).mediaCategory == "Perfume")
        #expect(session.document.mediaCategory == "Perfume" && !session.isDirty)
    }
}

struct CalibrationTests {
    private func job(_ separation: MediaSeparation) -> String? {
        var document = LabelDocument()
        document.separation = separation
        return LabelPrintService.sensorCalibrationJob(for: document).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func commandFollowsTheMediaSeparation() throws {
        let gap = try #require(job(.gap))
        #expect(gap.contains("SIZE 30.0 mm, 15.0 mm") && gap.contains("GAP 2.0 mm") && gap.contains("LIMITFEED") && gap.hasSuffix("HOME\r\n"))
        #expect(!gap.contains("DETECT")) // the RP310 ignores GAPDETECT / BLINEDETECT
        let mark = try #require(job(.blackMark))
        #expect(mark.contains("BLINE 2.0 mm") && mark.contains("HOME"))
        #expect(job(.continuous) == nil)
    }
}

@MainActor
struct LeaveEditorTests {
    @Test func leavingWithChangesAsksAndExitWithoutSavingDiscards() {
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterLeave-\(UUID())")!)
        session.route = .home(.templates)
        session.newDocument(size: CGSize(width: 30, height: 15))
        #expect(session.route == .editor)
        session.leaveEditor()                                   // nothing changed: straight back
        #expect(session.route == .home(.templates) && session.discardPrompt == nil)

        session.continueEditing()
        session.document.elements.append(LabelElement.make(.text))
        session.leaveEditor()
        #expect(session.route == .editor && session.discardPrompt?.leavesEditor == true)
        session.answerDiscardPrompt(save: nil)                  // Cancel: stay, keep the change
        #expect(session.route == .editor && session.document.elements.count == 1)

        session.leaveEditor()
        session.answerDiscardPrompt(save: false)                // Exit Without Saving
        #expect(session.route == .home(.templates) && session.document.elements.isEmpty && !session.isDirty)
    }
}

@MainActor
struct SaveAndThumbnailTests {
    @Test func newLabelsSaveIntoTheTemplatesFolderWithUniqueNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterSave-\(UUID())")
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterSave-\(UUID())")!)
        session.templatesFolder = folder
        session.newDocument(size: CGSize(width: 30, height: 15))
        var text = LabelElement.make(.text); text.content = "HAWAS\nICE"
        session.document.elements = [text]
        #expect(session.suggestedName == "HAWAS ICE")
        #expect(!session.save())                      // never saved: asks for a name
        #expect(session.savePrompt?.suggestedName == "HAWAS ICE")
        let first = try #require(session.saveInTemplatesFolder(named: "HAWAS ICE"))
        #expect(first.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL && !session.isDirty)
        session.saveAs()
        let copy = try #require(session.saveInTemplatesFolder(named: "HAWAS ICE"))
        #expect(copy.lastPathComponent == "HAWAS ICE 2.tprlabel")
    }

    @Test func templatesOutsideTheFolderMoveIn() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterMove-\(UUID())")
        let outside = base.appendingPathComponent("Downloads"), folder = base.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let url = outside.appendingPathComponent("Fantasy.tprlabel")
        try LabelTemplate.encode(LabelDocument()).write(to: url)
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterMove-\(UUID())")!)
        session.templatesFolder = folder
        session.load(url)
        #expect(!session.isInTemplatesFolder(url))
        let moved = try session.moveToTemplatesFolder([url])
        #expect(moved.count == 1 && session.isInTemplatesFolder(moved[0]) && !FileManager.default.fileExists(atPath: url.path))
        #expect(session.displayName == "Fantasy" && session.recentURLs.first == moved[0])
    }

    @Test func thumbnailIsCachedByContent() {
        var document = LabelDocument()
        document.elements = [LabelElement.make(.text)]
        let key = ThumbnailCache.key(for: document)
        #expect(key != nil && key == ThumbnailCache.key(for: document))
        #expect(ThumbnailCache.image(for: document) != nil)
        document.elements[0].content = "Changed"
        #expect(ThumbnailCache.key(for: document) != key)
    }
}

@MainActor
struct RelocateFolderTests {
    @Test func relocatingMovesEveryTemplateAndFollowsTheOpenLabel() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterRelocate-\(UUID())")
        let local = base.appendingPathComponent("Documents/TPrinter Templates"), cloud = base.appendingPathComponent("Cloud/TPrinter Templates")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for name in ["Fantasy", "HAWAS ICE"] {
            try LabelTemplate.encode(LabelDocument()).write(to: local.appendingPathComponent("\(name).tprlabel"))
        }
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterRelocate-\(UUID())")!)
        session.templatesFolder = local
        session.load(local.appendingPathComponent("Fantasy.tprlabel"))
        #expect(try session.relocateTemplatesFolder(to: cloud) == 2)
        #expect(session.templatesFolder.standardizedFileURL.path == cloud.standardizedFileURL.path)
        #expect(session.isInTemplatesFolder(cloud.appendingPathComponent("Fantasy.tprlabel")))
        #expect(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("HAWAS ICE.tprlabel").path))
        #expect(!FileManager.default.fileExists(atPath: local.path)) // empty old folder removed
        #expect(session.displayName == "Fantasy" && session.recentURLs.first?.deletingLastPathComponent().standardizedFileURL == cloud.standardizedFileURL)
        #expect(try session.relocateTemplatesFolder(to: local) == 2) // and back
    }
}

struct USBDiscoveryTests {
    @Test func listingUSBPrintersWorksWithOrWithoutOne() {
        let printers = USBPrinterConnection.connectedPrinters()
        #expect(Set(printers.map(\.id)).count == printers.count) // no duplicates, and no crash when none
    }
}

@MainActor
struct PDFLabelsTests {
    /// A two-page portrait PDF (A6-ish) with a black box on each page, like a courier label.
    private func makePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterPDF-\(UUID()).pdf")
        var box = CGRect(x: 0, y: 0, width: 298, height: 420)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 30, y: 40, width: 238, height: 340))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func media(width: Double, height: Double) -> Media {
        Media(name: "Test \(width)x\(height)", category: "Shipping", widthMM: width, heightMM: height)
    }

    @Test func everyPageBecomesALabel() throws {
        let pages = PDFLabels.pages(in: [try makePDF()])
        #expect(pages.count == 2 && pages[1].index == 1 && pages[1].title.hasSuffix("page 2"))
    }

    @Test func portraitPageFitsAPortraitLabelWithoutTurning() throws {
        let page = try #require(PDFLabels.pages(in: [try makePDF()]).first)
        let document = try #require(PDFLabels.document(for: page, media: media(width: 100, height: 150), options: .init()))
        let element = try #require(document.elements.first)
        let size = ElementGeometry.sizeMM(of: element)
        #expect(size.height > size.width)                      // still portrait
        #expect(element.x >= 0.9 && element.y >= 0.9)           // inside the 1 mm margin
        #expect(element.x + size.width <= 99.2 && element.y + size.height <= 149.2)
        #expect(!element.dithers && !element.trimsImage)
    }

    @Test func portraitPageTurnsOnALandscapeLabel() throws {
        let page = try #require(PDFLabels.pages(in: [try makePDF()]).first)
        let turned = try #require(PDFLabels.document(for: page, media: media(width: 100, height: 60), options: .init()))
        let size = ElementGeometry.sizeMM(of: try #require(turned.elements.first))
        #expect(size.width > size.height)
        var noTurn = PDFLabels.Options(); noTurn.rotates = false
        let upright = try #require(PDFLabels.document(for: page, media: media(width: 100, height: 60), options: noTurn))
        let uprightSize = ElementGeometry.sizeMM(of: try #require(upright.elements.first))
        #expect(uprightSize.height > uprightSize.width)
    }

    @Test func labelPrintsAsOneBitmapJob() throws {
        let page = try #require(PDFLabels.pages(in: [try makePDF()]).first)
        let document = try #require(PDFLabels.document(for: page, media: media(width: 100, height: 150), options: .init()))
        let job = String(decoding: try LabelPrintService.job(for: document), as: UTF8.self)
        #expect(job.contains("SIZE 100.0 mm, 150.0 mm") && job.contains("BITMAP") && job.contains("PRINT 1,1"))
    }
}

@MainActor
struct MediaStarterTests {
    @Test func existingLibrariesGetTheNewShippingSizesOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterMedia-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "TPrinterMedia-\(UUID())")!
        // A library saved before the new sizes existed.
        let old = Media.starters.filter { !Media.laterStarters.contains($0.name) }
        try JSONEncoder().encode(old).write(to: folder.appendingPathComponent("media.json"))

        let library = MediaLibrary(directory: folder, defaults: defaults)
        let square = try #require(library.media(named: "Shipping 3 × 3 in"))
        let small = try #require(library.media(named: "Shipping 2 × 3 in"))
        #expect(square.widthMM == 76.2 && square.heightMM == 76.2 && small.widthMM == 50.8 && small.heightMM == 76.2)
        // Next to the other shipping media.
        let names = library.media.map(\.name)
        #expect(names.firstIndex(of: "Shipping 3 × 3 in")! < names.firstIndex(of: "Food date 40 × 20")!)

        // Deleted by the user: not added back.
        library.delete(small.id)
        #expect(MediaLibrary(directory: folder, defaults: defaults).media(named: "Shipping 2 × 3 in") == nil)
    }
}

@MainActor
struct PrintWithTPrinterTests {
    @Test func pdfsFromAPrintWindowAreKeptAndOpenTheLabelsWindow() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterIncoming-\(UUID()).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try #require(CGContext(temp as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()

        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterIncoming-\(UUID())")!)
        session.receivePDFs([temp])
        let kept = try #require(session.incomingPDFs.first)
        #expect(session.showsPDFLabels)
        #expect(kept.path.hasPrefix(PDFService.inbox.path))        // a copy the print system can't delete
        try FileManager.default.removeItem(at: temp)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(PDFLabels.pages(in: [kept]).count == 1)
        try? FileManager.default.removeItem(at: kept)
    }
}

struct MeasureUnitTests {
    @Test func convertsAndFormatsEachUnit() {
        #expect(MeasureUnit.mm.size(30, 15) == "30 × 15 mm")
        #expect(MeasureUnit.cm.size(30, 15) == "3 × 1.5 cm")
        #expect(MeasureUnit.inch.length(50.8) == "2 in")
        #expect(MeasureUnit.inch.compactSize(76.2, 76.2) == "3×3 in")
        #expect(abs(MeasureUnit.inch.mm(1) - 25.4) < 0.0001 && abs(MeasureUnit.cm.value(15) - 1.5) < 0.0001)
    }

    @Test func steppingStaysOnTheUnitsGrid() {
        // 1 mm steps become 1/16 in steps in inches, and 0.1 cm in centimetres.
        let upInch = MeasureUnit.inch.stepped(25.4, stepMM: 1, direction: 1, in: 0...300)
        #expect(abs(upInch - 25.4 * (1 + 1.0 / 16)) < 0.001)
        let downCM = MeasureUnit.cm.stepped(30, stepMM: 1, direction: -1, in: 0...300)
        #expect(abs(downCM - 29) < 0.001)
        #expect(MeasureUnit.mm.stepped(5, stepMM: 1, direction: -1, in: 5...120) == 5) // clamped
    }
}

struct HistoryKindTests {
    @Test func olderRecordsWithoutAKindFallBackToBatchOrSingle() throws {
        let old = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"templateName":"Fantasy","labels":1,"mediaName":"30 × 15 mm","printer":"RP310","result":"printed","detail":"","wasBatch":true}]"#
        let records = try JSONDecoder().decode([PrintRecord].self, from: Data(old.utf8))
        #expect(records[0].kind == nil && records[0].jobKind == .batch)
        var pdf = records[0]; pdf.kind = .pdf
        let roundTrip = try JSONDecoder().decode(PrintRecord.self, from: JSONEncoder().encode(pdf))
        #expect(roundTrip.jobKind == .pdf)
    }
}

@MainActor
struct BatchModelTests {
    private func csv(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterBatch-\(UUID()).csv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func rowsMissingAValueStartUntickedAndRangeOverrides() throws {
        let model = BatchPrintModel()
        model.load(try csv("sku,name\n1,Tea\n2,\n3,Cocoa\n"), fields: ["name", "sku"])
        #expect(model.excluded == [1])
        #expect(model.printRows == [0, 2])
        #expect(model.missingValues(inRow: 1, fields: ["name", "sku"]) == ["name"])
        model.usesRange = true
        model.firstRow = 2; model.lastRow = 3
        #expect(model.printRows == [1, 2])
    }

    @Test func fieldsCanReadFromAColumnWithAnotherName() throws {
        let model = BatchPrintModel()
        model.load(try csv("Product Name;Code\nGreen Tea;100234\n"), fields: ["name"])
        #expect(model.column(for: "name") == nil && model.table?.delimiter == ";")
        model.setColumn("Product Name", for: "name")
        var template = LabelDocument()
        template.elements = [LabelElement(kind: .text, content: "{{name}}", x: 0, y: 0)]
        #expect(model.filled(template, row: 1).elements[0].content == "Green Tea")
    }
}
