import Foundation

enum LabelPrintError: LocalizedError {
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: "Could not render the label image."
        }
    }
}

/// Turns a `LabelDocument` into the bytes the printer understands.
enum LabelPrintService {
    @MainActor
    /// One label per job — always. On the RP310 a job holding several labels (multiple `PRINT`s or
    /// `PRINT 1,n` copies) misplaces every label after the first and feeds blank labels (tested
    /// 2026-09-24, with and without switching `SIZE` mid-job). Copies are sent as separate jobs.
    static func job(for document: LabelDocument) throws -> Data {
        var tspl = TSPLCommandBuilder()
        tspl.setup(document)
        let label = CGSize(width: document.widthMM, height: document.heightMM)
        let cells = document.arrangement.cellOrigins(label: label)
        switch document.printMethod {
        case .image:
            let bitmap = document.arrangement.isSingle
                ? LabelRasterizer.render(document)
                : LabelRasterizer.renderSheet(document, cellOrigins: cells)
            guard let bitmap else { throw LabelPrintError.renderFailed }
            tspl.bitmap(x: 0, y: 0, widthBytes: bitmap.widthBytes, height: bitmap.height, packedRows: bitmap.rows)
        case .nativeTSPL:
            // The same design in every cell, shifted to the cell's origin.
            for origin in cells {
                let shifted = document.elements.map { element -> LabelElement in
                    var moved = element
                    moved.x += origin.x
                    moved.y += origin.y
                    return moved
                }
                appendNative(shifted, to: &tspl)
            }
        }
        tspl.print(copies: 1)
        return tspl.data
    }

    @MainActor
    static func appendNative(_ elements: [LabelElement], to tspl: inout TSPLCommandBuilder) {
        for element in elements {
            let x = Int((element.x * dotsPerMM).rounded())
            let y = Int((element.y * dotsPerMM).rounded())
            // Anything the printer can't draw itself (styled / rotated text, rotated codes) goes as dots.
            let needsBitmap = element.kind.isTextual ? !element.isPlainText : element.rotation != 0 || element.barcodeQuietZone
                || (element.kind == .barcode && (element.barcodeNumberPosition == .above || element.barcodeType != .code128))
            if element.isHidden { continue }
            if needsBitmap, element.kind != .image, element.kind != .icon {
                if let bitmap = LabelRasterizer.render(element) {
                    tspl.bitmap(x: x, y: y, widthBytes: bitmap.widthBytes, height: bitmap.height, packedRows: bitmap.rows)
                }
                continue
            }
            switch element.kind {
            case .text, .date, .counter:
                let (font, multiplier) = TextFit.nativeFont(for: element)
                tspl.text(x: x, y: y, font: font, xMul: multiplier, yMul: multiplier,
                          content: element.displayText)
            case .barcode:
                tspl.barcode128(
                    x: x, y: y,
                    height: Int((element.barcodeHeightMM * dotsPerMM).rounded()),
                    humanReadable: element.showsBarcodeText,
                    narrow: element.barcodeModuleDots,
                    content: element.content
                )
            case .qrCode:
                // Estimate modules for a typical short payload (version ~3 → 29 modules).
                let cell = Int((element.qrSizeMM * dotsPerMM / 29).rounded(.down))
                tspl.qrCode(x: x, y: y, cellWidth: cell, content: element.content)
            case .image, .icon, .shape:
                // No printer-native equivalent: send the element's own dots.
                if let bitmap = LabelRasterizer.render(element) {
                    tspl.bitmap(x: x, y: y, widthBytes: bitmap.widthBytes, height: bitmap.height, packedRows: bitmap.rows)
                }
            }
        }
    }

    /// A small self-contained test label sized for the default 30 × 15 mm stock (240 × 120 dots).
    static func testJob(date: Date = Date()) -> Data {
        let document = LabelDocument()
        var tspl = TSPLCommandBuilder()
        tspl.setup(document)
        tspl.raw("BOX 2,2,\(document.widthDots - 2),\(document.heightDots - 2),2")
        tspl.text(x: 12, y: 10, font: "3", xMul: 1, yMul: 1, content: "TPrinter test")
        tspl.text(x: 12, y: 40, font: "2", xMul: 1, yMul: 1, content: asciiTimestamp(date))
        tspl.barcode128(x: 12, y: 68, height: 40, humanReadable: false, narrow: 1, content: "TPRINTER")
        tspl.print(copies: 1)
        return tspl.data
    }

    /// Outlines the exact label area so misalignment is easy to see on paper.
    static func alignmentJob(for document: LabelDocument) -> Data {
        var tspl = TSPLCommandBuilder()
        tspl.setup(document)
        let right = document.widthDots - 1, bottom = document.heightDots - 1
        tspl.raw("BOX 0,0,\(right),\(bottom),2")
        tspl.raw("BAR \(document.widthDots / 2),0,1,\(document.heightDots)")
        tspl.raw("BAR 0,\(document.heightDots / 2),\(document.widthDots),1")
        tspl.text(x: 8, y: 8, font: "1", xMul: 1, yMul: 1, content: "TOP")
        tspl.text(x: 8, y: bottom - 20, font: "1", xMul: 1, yMul: 1, content: "BOTTOM")
        tspl.text(x: document.widthDots / 2 + 6, y: 8, font: "1", xMul: 1, yMul: 1,
                  content: "TEAR OFF")
        tspl.print(copies: 1)
        return tspl.data
    }

    /// Makes the printer measure label + gap (or black-mark) length with its sensor, feeding a few
    /// labels. nil for continuous paper, which has no labels to measure.
    static func sensorCalibrationJob(for document: LabelDocument) -> Data? {
        var tspl = TSPLCommandBuilder()
        return tspl.sensorCalibration(document) ? tspl.data : nil
    }

    /// Printer fonts are ASCII-only; the system date format can contain e.g. U+202F before "PM".
    static func asciiTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
