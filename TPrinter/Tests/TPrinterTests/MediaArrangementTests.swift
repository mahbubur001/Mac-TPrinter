import CoreGraphics
import Foundation
import Testing
@testable import TPrinter

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("TPrinterTests-\(UUID())", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
struct MediaLibraryTests {
    @Test func seedsStartersAndPersistsChanges() {
        let dir = tempDir()
        let library = MediaLibrary(directory: dir)
        #expect(library.media.count == Media.starters.count)
        #expect(library.categories.contains("Shipping"))

        var custom = Media(name: "Jar lid 45 × 45", category: "Food", widthMM: 45, heightMM: 45)
        library.save(custom)
        custom.gapMM = 3
        library.save(custom) // update, not duplicate
        library.delete(library.media[0].id)

        let reopened = MediaLibrary(directory: dir)
        #expect(reopened.media.count == Media.starters.count)
        #expect(reopened.media.first { $0.name == "Jar lid 45 × 45" }?.gapMM == 3)
        #expect(reopened.media(inCategory: "food").count == 2)
    }
}

@MainActor
struct HistoryAndNoticeTests {
    @Test func historyKeepsNewestFirstAndCountsToday() {
        let history = PrintHistory(directory: tempDir())
        history.add(PrintRecord(date: Date().addingTimeInterval(-3 * 86_400), templateName: "Old", labels: 5, mediaName: "m", printer: "p", result: .printed))
        history.add(PrintRecord(date: Date(), templateName: "A", labels: 3, mediaName: "m", printer: "p", result: .printed))
        history.add(PrintRecord(date: Date(), templateName: "B", labels: 2, mediaName: "m", printer: "p", result: .failed))
        #expect(history.records.first?.templateName == "B")
        #expect(history.labelsPrintedToday == 3)
    }

    @Test func noticesCountUnread() {
        let notices = NoticeCenter()
        notices.post(.success, "Printed")
        notices.post(.info, "Connected")
        #expect(notices.unread == 2)
        notices.markAllRead()
        #expect(notices.unread == 0 && notices.notices.count == 2)
    }
}

struct ArrangementTests {
    private let label = CGSize(width: 30, height: 15)

    @Test func singleIsTheLabelItself() {
        #expect(LabelArrangement.single.isSingle)
        #expect(LabelArrangement.single.sheetSize(label: label) == label)
        #expect(LabelArrangement.single.cellOrigins(label: label) == [.zero])
    }

    @Test func gridWithMarginsAndSpacing() {
        var a = LabelArrangement()
        a.rows = 2; a.columns = 3
        a.marginLeftMM = 2; a.marginRightMM = 2; a.marginTopMM = 1
        a.spacingHorizontalMM = 1; a.spacingVerticalMM = 2
        #expect(a.cellCount == 6)
        #expect(a.sheetSize(label: label) == CGSize(width: 2 + 2 + 90 + 2, height: 1 + 30 + 2))
        let cells = a.cellOrigins(label: label)
        #expect(cells[1] == CGPoint(x: 33, y: 1))   // second column
        #expect(cells[3] == CGPoint(x: 2, y: 18))   // second row
    }
}

@MainActor
struct MediaPrintingTests {
    @Test func separationPicksTheRightCommand() {
        var document = LabelDocument()
        document.separation = .blackMark
        var tspl = TSPLCommandBuilder(); tspl.setup(document)
        #expect(String(decoding: tspl.data, as: UTF8.self).contains("BLINE 2.0 mm, 0 mm"))
        document.separation = .continuous
        tspl = TSPLCommandBuilder(); tspl.setup(document)
        #expect(String(decoding: tspl.data, as: UTF8.self).contains("GAP 0 mm, 0 mm"))
    }

    @Test func arrangementPrintsTheWholeRowInOneJob() throws {
        var document = LabelDocument()
        document.arrangement.columns = 2
        document.arrangement.spacingHorizontalMM = 2
        let text = String(decoding: try LabelPrintService.job(for: document), as: UTF8.self)
        #expect(text.contains("SIZE 62.0 mm, 15.0 mm"))
        #expect(text.contains("BITMAP 0,0,62,120,0,"), "62 mm × 8 dots = 496 dots = 62 bytes wide")
        #expect(text.components(separatedBy: "PRINT ").count - 1 == 1)
    }

    @Test func nativeModeRepeatsElementsPerCell() throws {
        var document = LabelDocument()
        document.printMethod = .nativeTSPL
        document.elements = [LabelElement(kind: .text, content: "A", x: 1, y: 1)]
        document.arrangement.columns = 2
        document.arrangement.spacingHorizontalMM = 2
        let text = String(decoding: try LabelPrintService.job(for: document), as: UTF8.self)
        #expect(text.contains("TEXT 8,8,"))            // cell 1: 1 mm
        #expect(text.contains("TEXT 264,8,"))          // cell 2: 1 + 30 + 2 = 33 mm
    }

    @Test func labelFromMediaTakesItsSettings() throws {
        var media = Media(name: "Parcel 60 × 40", category: "Shipping", widthMM: 60, heightMM: 40, gapMM: 3, separation: .blackMark)
        media.defaultDarkness = 11
        let document = LabelDocument(media: media)
        #expect(document.widthMM == 60 && document.heightMM == 40 && document.gapMM == 3)
        #expect(document.separation == .blackMark && document.density == 11)
        #expect(document.mediaTitle == "Parcel 60 × 40" && document.elements.isEmpty)
        #expect(try LabelTemplate.decode(LabelTemplate.encode(document)) == document)
    }
}

@MainActor
struct RouteTests {
    @Test func newLabelFlowAndEditorRoutes() {
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterRoute-\(UUID())")!)
        #expect(session.route == .home(.dashboard))
        session.startNewLabel()
        #expect(session.route == .newLabel)
        session.newDocument(media: Media.starters[1], arrangement: .single, printMethod: .nativeTSPL)
        #expect(session.route == .editor)
        #expect(session.document.widthMM == 40 && session.document.printMethod == .nativeTSPL)
        #expect(!session.isDirty)
        session.showBatch()
        #expect(session.route == .home(.batch))
    }
}

@MainActor
struct HistoryPageTests {
    @Test func totalsAndRemoval() {
        let history = PrintHistory(directory: tempDir())
        let old = PrintRecord(date: Date().addingTimeInterval(-10 * 86_400), templateName: "Old", labels: 4, mediaName: "m", printer: "p", result: .printed)
        let recent = PrintRecord(date: Date().addingTimeInterval(-2 * 86_400), templateName: "Recent", labels: 3, mediaName: "m", printer: "p", result: .printed)
        let failed = PrintRecord(date: Date(), templateName: "Failed", labels: 9, mediaName: "m", printer: "p", result: .failed)
        [old, recent, failed].forEach(history.add)
        #expect(history.labelsPrintedThisWeek == 3)
        #expect(history.labelsPrintedTotal == 7)
        history.delete(recent.id)
        #expect(history.records.map(\.templateName) == ["Failed", "Old"])
    }

    @Test func openInEditorGivesAnUnsavedCopy() {
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterCopy-\(UUID())")!)
        var printed = LabelDocument()
        printed.elements[0].content = "As printed"
        session.openCopy(of: printed)
        #expect(session.route == .editor)
        #expect(session.fileURL == nil && session.isDirty)
        #expect(session.document.elements[0].content == "As printed")
    }
}

@MainActor
struct NoticeTopicTests {
    @Test func turnedOffTopicsArentPosted() {
        let defaults = UserDefaults(suiteName: "TPrinterNotice-\(UUID())")!
        let notices = NoticeCenter(defaults: defaults)
        defaults.set(false, forKey: NoticeTopic.printer.settingKey)
        notices.post(.info, "Printer connected", topic: .printer)
        notices.post(.success, "Printed", topic: .prints)
        #expect(notices.notices.map(\.title) == ["Printed"])
        #expect(notices.isEnabled(.prints) && !notices.isEnabled(.printer))
    }
}
