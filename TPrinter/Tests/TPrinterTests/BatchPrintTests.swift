import Foundation
import Testing
@testable import TPrinter

struct CSVTableTests {
    @Test func parsesHeadersAndRows() throws {
        let table = try CSVTable.parse("sku,name\nA1,Apple\nB2,Banana\n")
        #expect(table.headers == ["sku", "name"])
        #expect(table.rows == [["A1", "Apple"], ["B2", "Banana"]])
        #expect(table.record(at: 1) == ["sku": "B2", "name": "Banana"])
    }

    @Test func handlesQuotesEscapesAndEmbeddedDelimitersAndNewlines() throws {
        let csv = "name,note\r\n\"Smith, John\",\"He said \"\"hi\"\"\"\r\n\"Multi\nline\",x\r\n"
        let table = try CSVTable.parse(csv)
        #expect(table.rows == [["Smith, John", "He said \"hi\""], ["Multi\nline", "x"]])
    }

    @Test func detectsSemicolonAndTabDelimiters() throws {
        #expect(try CSVTable.parse("a;b\n1;2").rows == [["1", "2"]])
        #expect(try CSVTable.parse("a\tb\n1\t2").rows == [["1", "2"]])
    }

    @Test func stripsBOMSkipsBlankLinesAndPadsShortRows() throws {
        let table = try CSVTable.parse("\u{FEFF}sku,name,price\n\nA1,Apple\n\n")
        #expect(table.headers == ["sku", "name", "price"])
        #expect(table.rows == [["A1", "Apple", ""]])
    }

    @Test func namesEmptyAndDuplicateHeaders() throws {
        #expect(try CSVTable.parse("sku,,SKU\n1,2,3").headers == ["sku", "Column 2", "Column 3"])
    }

    @Test func emptyFileIsAnError() {
        #expect(throws: CSVTable.ParseError.self) { try CSVTable.parse("") }
    }
}

struct LabelFieldsTests {
    private func document(_ contents: [String]) -> LabelDocument {
        var document = LabelDocument()
        document.elements = contents.map { LabelElement(kind: .text, content: $0, x: 0, y: 0) }
        return document
    }

    @Test func findsFieldNamesOnceInOrder() {
        let doc = document(["{{name}} – {{ price }}", "{{SKU}}", "{{name}}"])
        #expect(LabelFields.names(in: doc) == ["name", "price", "SKU"])
    }

    @Test func fillsCaseInsensitivelyAndKeepsUnknownFields() {
        let doc = document(["{{Name}}: {{price}} ({{missing}})"])
        let filled = LabelFields.fill(doc, with: ["name": "Apple", "PRICE": "1.20"])
        #expect(filled.elements[0].content == "Apple: 1.20 ({{missing}})")
        #expect(LabelFields.missing(in: doc, columns: ["name", "PRICE"]) == ["missing"])
    }
}

struct SingleLabelJobTests {
    /// Multi-label jobs misplace labels on the RP310, so every job must hold exactly one label.
    @MainActor @Test func copiesNeverGoIntoOneJob() throws {
        var document = LabelDocument()
        document.copies = 5
        let text = String(decoding: try LabelPrintService.job(for: document), as: UTF8.self)
        #expect(text.components(separatedBy: "PRINT ").count - 1 == 1)
        #expect(text.hasSuffix("PRINT 1,1\r\n"))
        #expect(text.components(separatedBy: "BITMAP ").count - 1 == 1)
    }

    @MainActor @Test func filledRowGoesIntoTheJob() throws {
        var template = LabelDocument()
        template.printMethod = .nativeTSPL
        template.elements = [LabelElement(kind: .text, content: "{{sku}}", x: 1, y: 1)]
        let job = try LabelPrintService.job(for: LabelFields.fill(template, with: ["sku": "B2"]))
        #expect(String(decoding: job, as: UTF8.self).contains("\"B2\""))
    }
}

@MainActor
struct BatchRowStatusTests {
    @Test func rowsOutsideTheRangeAreSkipped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("sku,name\n1,A\n2,B\n3,C\n4,D\n".utf8).write(to: url)
        let model = BatchPrintModel()
        model.load(url)
        #expect(model.rowCount == 4 && model.lastRow == 4)
        model.usesRange = true // print a from–to range instead of the ticked rows
        model.firstRow = 2; model.lastRow = 3
        #expect(model.selectedRowCount == 2)
        #expect(model.status(ofRow: 1, queueDone: nil) == .skipped)
        #expect(model.status(ofRow: 2, queueDone: nil) == .waiting)
        #expect(model.status(ofRow: 4, queueDone: nil) == .skipped)
        let template = LabelDocument()
        #expect(model.filled(template, row: 2) == template, "no fields: template unchanged")
    }
}
