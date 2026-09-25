import Foundation

/// Builds a TSPL (TSC Printer Language) job as raw bytes.
///
/// Commands are ASCII lines terminated by CRLF; `BITMAP` embeds binary data inline.
struct TSPLCommandBuilder {
    private(set) var data = Data()

    private mutating func line(_ command: String) {
        data.append(contentsOf: Array(command.utf8))
        data.append(contentsOf: [0x0D, 0x0A])
    }

    /// Escapes a string for use inside a TSPL quoted parameter.
    static func quote(_ text: String) -> String {
        // TSPL uses \["] to embed a double quote.
        "\"" + text.replacingOccurrences(of: "\"", with: "\\[\"]") + "\""
    }

    private static func mm(_ value: Double) -> String {
        String(format: "%.1f mm", value)
    }

    /// Job header. `SET TEAR OFF` is what makes the RP310 place labels correctly: in tear mode it
    /// pushes each label to the tear bar and pulls the paper back too far before the next job, so
    /// printing starts ~3 mm early (verified 2026-09-24; SHIFT/OFFSET/GAP offset/GAPDETECT don't fix it,
    /// and extending SIZE to compensate feeds blank labels).
    /// `SIZE` is the whole printed row (all arrangement cells + margins); separation follows the media.
    mutating func setup(_ document: LabelDocument) {
        let sheet = document.arrangement.sheetSize(label: CGSize(width: document.widthMM, height: document.heightMM))
        line("SET TEAR OFF")
        line("SIZE \(Self.mm(sheet.width)), \(Self.mm(sheet.height))")
        switch document.separation {
        case .gap: line("GAP \(Self.mm(document.gapMM)), 0 mm")
        case .blackMark: line("BLINE \(Self.mm(document.gapMM)), 0 mm")
        case .continuous: line("GAP 0 mm, 0 mm")
        }
        line("DENSITY \(min(max(document.density, 0), 15))")
        line("SPEED \(max(document.speed, 1))")
        line("DIRECTION \(document.flipped ? 0 : 1),0")
        line("REFERENCE 0,0")
        line("CLS")
    }

    mutating func text(x: Int, y: Int, font: String, rotation: Int = 0, xMul: Int, yMul: Int, content: String) {
        line("TEXT \(x),\(y),\"\(font)\",\(rotation),\(xMul),\(yMul),\(Self.quote(content))")
    }

    mutating func barcode128(x: Int, y: Int, height: Int, humanReadable: Bool, narrow: Int, content: String) {
        let wide = narrow
        line("BARCODE \(x),\(y),\"128\",\(height),\(humanReadable ? 1 : 0),0,\(narrow),\(wide),\(Self.quote(content))")
    }

    mutating func qrCode(x: Int, y: Int, cellWidth: Int, content: String) {
        line("QRCODE \(x),\(y),M,\(min(max(cellWidth, 1), 10)),A,0,\(Self.quote(content))")
    }

    /// - Parameter packedRows: 1 bit per dot, MSB first, `0` = black. `widthBytes * height` bytes.
    mutating func bitmap(x: Int, y: Int, widthBytes: Int, height: Int, packedRows: Data) {
        precondition(packedRows.count == widthBytes * height, "bitmap size mismatch")
        data.append(contentsOf: Array("BITMAP \(x),\(y),\(widthBytes),\(height),0,".utf8))
        data.append(packedRows)
        data.append(contentsOf: [0x0D, 0x0A])
    }

    /// Sensor calibration for the label's media. The RP310 ignores `GAPDETECT` / `BLINEDETECT` (sent,
    /// no reaction, no status — 2026-09-25) and Rongta's own SDK never uses them; it uses `HOME`, which
    /// feeds until the sensor finds the next label's start. So: the label size and separation (as for a
    /// print), a feed limit so a missed gap can't run the roll out, then `HOME`.
    /// Continuous paper has nothing to measure: returns false and adds nothing.
    @discardableResult
    mutating func sensorCalibration(_ document: LabelDocument) -> Bool {
        guard document.separation != .continuous else { return false }
        let sheet = document.arrangement.sheetSize(label: CGSize(width: document.widthMM, height: document.heightMM))
        line("SET TEAR OFF")
        line("SIZE \(Self.mm(sheet.width)), \(Self.mm(sheet.height))")
        switch document.separation {
        case .gap: line("GAP \(Self.mm(document.gapMM)), 0 mm")
        case .blackMark: line("BLINE \(Self.mm(document.gapMM)), 0 mm")
        case .continuous: break
        }
        // Up to three labels' worth of paper to find the gap / mark.
        line("LIMITFEED \(Int(((sheet.height + document.gapMM) * 3).rounded(.up))) mm")
        line("HOME")
        return true
    }

    mutating func print(copies: Int) {
        line("PRINT 1,\(max(copies, 1))")
    }

    mutating func raw(_ command: String) {
        line(command)
    }
}
