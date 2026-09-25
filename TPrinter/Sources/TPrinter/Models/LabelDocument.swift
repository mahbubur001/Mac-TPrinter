import Foundation

/// Printer resolution: 203 dpi ≈ 8 dots per millimetre.
let dotsPerMM: Double = 8

enum LabelElementKind: String, Codable, CaseIterable, Identifiable {
    case text
    case barcode
    case qrCode
    case image
    case icon
    case shape
    case date
    case counter

    var id: String { rawValue }

    /// Kinds drawn as text (share font, size and style settings).
    var isTextual: Bool { self == .text || self == .date || self == .counter }

    var title: String {
        switch self {
        case .text: "Text"
        case .barcode: "Barcode"
        case .qrCode: "QR Code"
        case .image: "Image"
        case .icon: "Icon"
        case .shape: "Shape"
        case .date: "Date"
        case .counter: "Counter"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "textformat"
        case .barcode: "barcode"
        case .qrCode: "qrcode"
        case .image: "photo"
        case .icon: "star.square"
        case .shape: "square.on.circle"
        case .date: "calendar"
        case .counter: "number"
        }
    }
}

/// One item on the label. All geometry is in millimetres from the top-left corner.
struct LabelElement: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: LabelElementKind
    var content: String
    /// Layer name chosen by the user; empty = automatic (see `layerName`).
    var name: String = ""
    var x: Double
    var y: Double
    /// Text: cap height-ish font size in mm.
    var fontSizeMM: Double = 4
    var bold: Bool = false
    /// Text: shrink the font (never grow it) so the widest line fits `fitWidthMM`.
    var shrinksToFit: Bool = false
    /// Text: the width available when `shrinksToFit` is on.
    var fitWidthMM: Double = 20
    /// Barcode: bar height in mm.
    var barcodeHeightMM: Double = 8
    /// Barcode: width of the narrowest bar in dots.
    var barcodeModuleDots: Int = 2
    var showsBarcodeText: Bool = true
    /// QR: side length in mm.
    var qrSizeMM: Double = 14
    /// Image: the picture (PNG/JPEG/… bytes, stored in the template). `content` holds the file name.
    var imageData: Data? = nil
    /// Image: printed width in mm; height follows the picture's aspect ratio.
    var imageWidthMM: Double = 12
    /// Image: error-diffusion dithering (photos, shading) vs. a plain threshold (line-art logos).
    var dithers: Bool = true
    /// Image: 0…1, darker-than-this becomes black (threshold mode), or overall darkness bias (dither mode).
    var imageThreshold: Double = 0.5
    /// Icon: side length in mm. `content` holds the SF Symbol name (so `{{column}}` can pick icons too).
    var iconSizeMM: Double = 8

    // MARK: Any element
    /// Quarter turns: 0, 90, 180 or 270 degrees.
    var rotation: Int = 0
    /// Locked elements can't be moved or resized on the canvas.
    var isLocked: Bool = false
    /// Hidden elements aren't drawn or printed.
    var isHidden: Bool = false

    // MARK: Text style
    /// "system", "rounded", "serif", "monospaced", or an installed font family name.
    var fontFamily: String = "system"
    var fontWeight: TextWeight = .regular
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var textCase: TextCase = .asTyped
    var textAlignment: TextAlign = .leading
    /// Extra space between lines, mm.
    var lineSpacingMM: Double = 0
    /// Extra space between letters, mm.
    var letterSpacingMM: Double = 0
    /// Wrap onto several lines inside `fitWidthMM` (instead of one line / shrinking).
    var wrapsText: Bool = false
    /// Wrapped text: fixed box height in mm; lines that don't fit are hidden. 0 = grows with the text.
    var boxHeightMM: Double = 0
    /// White text on a black box.
    var invertsText: Bool = false
    /// A thin box around the text.
    var outlined: Bool = false

    // MARK: Barcode / QR / image / icon extras
    var barcodeNumberPosition: BarcodeNumberPosition = .below
    /// Size of the human-readable number under / over the bars, mm.
    var barcodeNumberSizeMM: Double = 2.5
    /// Blank margin of 10 bar widths each side, which some scanners need.
    var barcodeQuietZone: Bool = false
    /// QR error correction: "L", "M", "Q" or "H".
    var qrCorrection: String = "M"
    var invertsImage: Bool = false
    var trimsImage: Bool = true
    var iconWeight: IconWeight = .regular
    var iconFilled: Bool = false
    var barcodeType: BarcodeType = .code128
    /// Image crop as fractions of the picture (0…1); full picture by default.
    var cropX: Double = 0, cropY: Double = 0, cropWidth: Double = 1, cropHeight: Double = 1

    // MARK: Shape
    var shapeKind: ShapeKind = .rectangle
    var shapeWidthMM: Double = 12
    var shapeHeightMM: Double = 6
    var lineWidthMM: Double = 0.4
    var cornerRadiusMM: Double = 1
    var shapeFilled: Bool = false
    var dashed: Bool = false

    // MARK: Date
    /// A `DateFormatter` pattern, e.g. "dd MMM yyyy".
    var dateFormat: String = "dd MMM yyyy"
    /// Days added to today (e.g. 30 for a best-before date).
    var dateOffsetDays: Int = 0

    // MARK: Counter
    /// The value the next printed label gets.
    var counterNext: Int = 1
    var counterStep: Int = 1
    var counterDigits: Int = 4
    var counterPrefix: String = ""
    var counterSuffix: String = ""

    /// Text as printed now: the typed content, today's date, or the next counter value — with the
    /// letter-case transform. (CSV fields are filled before this, in `LabelFields`.)
    var displayText: String { displayText(counterOffset: 0, date: Date()) }

    func displayText(counterOffset: Int, date: Date) -> String {
        let raw: String
        switch kind {
        case .date: raw = formattedDate(date)
        case .counter: raw = counterText(offset: counterOffset)
        default: raw = content
        }
        switch textCase {
        case .asTyped: return raw
        case .upper: return raw.uppercased()
        case .lower: return raw.lowercased()
        }
    }

    func formattedDate(_ now: Date) -> String {
        let day = Calendar.current.date(byAdding: .day, value: dateOffsetDays, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat
        return formatter.string(from: day)
    }

    func counterText(offset: Int) -> String {
        let value = counterNext + offset * counterStep
        let digits = String(format: "%0\(max(counterDigits, 1))d", value)
        return counterPrefix + digits + counterSuffix
    }

    /// The counter advanced by `labels` steps (for the label printed `labels` after this one).
    func advancingCounter(by labels: Int) -> LabelElement {
        var copy = self
        if kind == .counter { copy.counterNext += labels * counterStep }
        return copy
    }

    /// Text drawn as plain printer text in Native TSPL mode; anything fancier is sent as a bitmap.
    var isPlainText: Bool {
        kind.isTextual && fontFamily == "system" && !italic && !underline && !strikethrough && !invertsText && !outlined
            && !wrapsText && rotation == 0 && letterSpacingMM == 0 && !displayText.contains(where: \.isNewline)
    }

    /// What the layers list shows: the custom name, or a sensible automatic one.
    var layerName: String {
        let custom = name.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        switch kind {
        case .icon: return "Icon"
        case .image: return content.isEmpty ? kind.title : content
        case .shape: return shapeKind.title
        case .date: return "Date · \(displayText)"
        case .counter: return "Counter · \(displayText)"
        default:
            let text = content.replacingOccurrences(of: "\n", with: " ")
            return text.isEmpty ? kind.title : text
        }
    }

    static func make(_ kind: LabelElementKind) -> LabelElement {
        switch kind {
        case .text:
            LabelElement(kind: .text, content: "Text", x: 2, y: 2)
        case .barcode:
            LabelElement(kind: .barcode, content: "123456789", x: 2, y: 10)
        case .qrCode:
            LabelElement(kind: .qrCode, content: "https://example.com", x: 16, y: 1.5, qrSizeMM: 12)
        case .shape:
            LabelElement(kind: .shape, content: "", x: 1, y: 1)
        case .date:
            LabelElement(kind: .date, content: "", x: 2, y: 2, fontSizeMM: 2.5)
        case .counter:
            LabelElement(kind: .counter, content: "", x: 2, y: 2, fontSizeMM: 2.5)
        case .image:
            LabelElement(kind: .image, content: "Image", x: 2, y: 2)
        case .icon:
            LabelElement(kind: .icon, content: "shippingbox", x: 2, y: 2)
        }
    }

    static func image(_ data: Data, named name: String) -> LabelElement {
        var element = make(.image)
        element.imageData = data
        element.content = name
        return element
    }
}

enum TextWeight: String, Codable, CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold, heavy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TextCase: String, Codable, CaseIterable, Identifiable {
    case asTyped, upper, lower
    var id: String { rawValue }
    var title: String { self == .asTyped ? "Aa" : self == .upper ? "AA" : "aa" }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
}

enum BarcodeNumberPosition: String, Codable, CaseIterable, Identifiable {
    case below, above
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum IconWeight: String, Codable, CaseIterable, Identifiable {
    case light, regular, bold
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle, rounded, ellipse, line
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .rounded: "Rounded"
        case .ellipse: "Ellipse"
        case .line: "Line"
        }
    }
    var systemImage: String {
        switch self {
        case .rectangle: "rectangle"
        case .rounded: "app"
        case .ellipse: "oval"
        case .line: "line.diagonal"
        }
    }
}

enum BarcodeType: String, Codable, CaseIterable, Identifiable {
    case code128, ean13, ean8, upcA, code39, itf14, codabar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .code128: "Code 128"
        case .ean13: "EAN-13"
        case .ean8: "EAN-8"
        case .upcA: "UPC-A"
        case .code39: "Code 39"
        case .itf14: "ITF-14"
        case .codabar: "Codabar"
        }
    }
    var hint: String {
        switch self {
        case .code128: "Letters, numbers and symbols."
        case .ean13: "12 digits; the 13th (check digit) is added."
        case .ean8: "7 digits; the 8th (check digit) is added."
        case .upcA: "11 digits; the 12th (check digit) is added."
        case .code39: "Capital letters, digits and - . $ / + % space."
        case .itf14: "13 digits; the 14th (check digit) is added."
        case .codabar: "Digits and - $ : / . +, starts and ends with A–D."
        }
    }
}

enum PrintMethod: String, Codable, CaseIterable, Identifiable {
    /// Render the preview to a 1-bit image and send it with TSPL BITMAP (WYSIWYG).
    case image
    /// Use the printer's own TEXT / BARCODE / QRCODE commands.
    case nativeTSPL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "Image (exact preview)"
        case .nativeTSPL: "Native TSPL commands"
        }
    }
}

struct LabelDocument: Codable, Hashable {
    var widthMM: Double = 30
    var heightMM: Double = 15
    var gapMM: Double = 2
    /// TSPL DENSITY 0…15 (darkness).
    var density: Int = 8
    /// TSPL SPEED in inches/second.
    var speed: Int = 4
    var copies: Int = 1
    /// Rotate output 180° (TSPL DIRECTION 1 vs 0).
    var flipped: Bool = false
    var printMethod: PrintMethod = .image
    /// The media (paper roll) this label was made for; empty when it wasn't made from a saved media.
    var mediaName: String = ""
    var mediaCategory: String = ""
    /// How the printer finds each label: gap, black mark or continuous.
    var separation: MediaSeparation = .gap
    /// Rows × columns of this label per printed row (multi-across media), with margins and spacing.
    var arrangement: LabelArrangement = .single
    /// Default layout for a 30 × 15 mm label: text + barcode on the left, QR on the right.
    var elements: [LabelElement] = [
        LabelElement(kind: .text, content: "Hello Label", x: 1.5, y: 1.5, fontSizeMM: 3, bold: true),
        LabelElement(kind: .barcode, content: "123456789", x: 1.5, y: 6, barcodeHeightMM: 4.5, barcodeModuleDots: 1),
        LabelElement(kind: .qrCode, content: "https://example.com", x: 18.5, y: 2.5, qrSizeMM: 11),
    ]

    var widthDots: Int { Int((widthMM * dotsPerMM).rounded()) }
    var heightDots: Int { Int((heightMM * dotsPerMM).rounded()) }

    var hasCounters: Bool { elements.contains { $0.kind == .counter } }

    /// The label as it prints `labels` labels from now: every counter moved on that many steps.
    func advancingCounters(by labels: Int) -> LabelDocument {
        guard labels != 0, hasCounters else { return self }
        var copy = self
        copy.elements = elements.map { $0.advancingCounter(by: labels) }
        return copy
    }
}
