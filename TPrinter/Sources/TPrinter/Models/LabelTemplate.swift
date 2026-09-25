import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// `.tprlabel` — declared in Support/Info.plist (UTExportedTypeDeclarations).
    static let tprinterLabel = UTType(exportedAs: "net.restobox.tprinter.label", conformingTo: .json)
}

/// On-disk label template: `{ "format": "tprinter-label", "version": 1, "label": { …LabelDocument… } }`.
enum LabelTemplate {
    static let fileExtension = "tprlabel"
    static let format = "tprinter-label"
    static let currentVersion = 1

    enum TemplateError: LocalizedError {
        case notATemplate
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .notATemplate: "This file is not a TPrinter label template."
            case .newerVersion(let version): "This template was made by a newer version of TPrinter (format \(version))."
            }
        }
    }

    private struct File: Codable {
        var format: String
        var version: Int
        var label: LabelDocument
    }

    private struct Header: Decodable {
        var format: String?
        var version: Int?
    }

    static func encode(_ document: LabelDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(format: format, version: currentVersion, label: document))
    }

    static func decode(_ data: Data) throws -> LabelDocument {
        let header = try? JSONDecoder().decode(Header.self, from: data)
        guard header?.format == format else { throw TemplateError.notATemplate }
        if let version = header?.version, version > currentVersion { throw TemplateError.newerVersion(version) }
        return try JSONDecoder().decode(File.self, from: data).label
    }
}

// MARK: - Tolerant decoding
// Missing keys fall back to defaults so templates keep opening as fields are added.

extension LabelDocument {
    enum CodingKeys: String, CodingKey {
        case widthMM, heightMM, gapMM, density, speed, copies, flipped, printMethod
        case mediaName, mediaCategory, separation, arrangement, elements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LabelDocument()
        self.init(
            widthMM: try c.decodeIfPresent(Double.self, forKey: .widthMM) ?? d.widthMM,
            heightMM: try c.decodeIfPresent(Double.self, forKey: .heightMM) ?? d.heightMM,
            gapMM: try c.decodeIfPresent(Double.self, forKey: .gapMM) ?? d.gapMM,
            density: try c.decodeIfPresent(Int.self, forKey: .density) ?? d.density,
            speed: try c.decodeIfPresent(Int.self, forKey: .speed) ?? d.speed,
            copies: try c.decodeIfPresent(Int.self, forKey: .copies) ?? d.copies,
            flipped: try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? d.flipped,
            printMethod: try c.decodeIfPresent(PrintMethod.self, forKey: .printMethod) ?? d.printMethod,
            mediaName: try c.decodeIfPresent(String.self, forKey: .mediaName) ?? "",
            mediaCategory: try c.decodeIfPresent(String.self, forKey: .mediaCategory) ?? "",
            separation: try c.decodeIfPresent(MediaSeparation.self, forKey: .separation) ?? .gap,
            arrangement: try c.decodeIfPresent(LabelArrangement.self, forKey: .arrangement) ?? .single,
            elements: try c.decodeIfPresent([LabelElement].self, forKey: .elements) ?? []
        )
    }
}

extension LabelElement {
    enum CodingKeys: String, CodingKey {
        case id, kind, content, name, x, y, fontSizeMM, bold, shrinksToFit, fitWidthMM, barcodeHeightMM, barcodeModuleDots, showsBarcodeText, qrSizeMM
        case imageData, imageWidthMM, dithers, imageThreshold, iconSizeMM
        case rotation, isLocked, isHidden, fontFamily, fontWeight, italic, underline, strikethrough, textCase, textAlignment
        case lineSpacingMM, letterSpacingMM, wrapsText, invertsText, outlined, boxHeightMM
        case barcodeNumberPosition, barcodeNumberSizeMM, barcodeQuietZone, qrCorrection, invertsImage, trimsImage, iconWeight, iconFilled
        case barcodeType, cropX, cropY, cropWidth, cropHeight
        case shapeKind, shapeWidthMM, shapeHeightMM, lineWidthMM, cornerRadiusMM, shapeFilled, dashed
        case dateFormat, dateOffsetDays, counterNext, counterStep, counterDigits, counterPrefix, counterSuffix
    }

    /// Starts from the kind's defaults and overrides whatever the file has, so any field can be missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = LabelElement.make(try c.decode(LabelElementKind.self, forKey: .kind))
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T) throws {
            if let decoded = try c.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = ""
        try read(.content, into: &content); try read(.name, into: &name)
        try read(.x, into: &x); try read(.y, into: &y)
        try read(.fontSizeMM, into: &fontSizeMM); try read(.bold, into: &bold)
        try read(.shrinksToFit, into: &shrinksToFit); try read(.fitWidthMM, into: &fitWidthMM)
        try read(.barcodeHeightMM, into: &barcodeHeightMM); try read(.barcodeModuleDots, into: &barcodeModuleDots)
        try read(.showsBarcodeText, into: &showsBarcodeText); try read(.qrSizeMM, into: &qrSizeMM)
        if let data = try c.decodeIfPresent(Data.self, forKey: .imageData) { imageData = data }
        try read(.imageWidthMM, into: &imageWidthMM); try read(.dithers, into: &dithers)
        try read(.imageThreshold, into: &imageThreshold); try read(.iconSizeMM, into: &iconSizeMM)
        try read(.rotation, into: &rotation); try read(.isLocked, into: &isLocked); try read(.isHidden, into: &isHidden)
        try read(.fontFamily, into: &fontFamily)
        // Older templates only had `bold`.
        fontWeight = try c.decodeIfPresent(TextWeight.self, forKey: .fontWeight) ?? (bold ? .bold : .regular)
        try read(.italic, into: &italic); try read(.underline, into: &underline); try read(.strikethrough, into: &strikethrough)
        try read(.textCase, into: &textCase); try read(.textAlignment, into: &textAlignment)
        try read(.lineSpacingMM, into: &lineSpacingMM); try read(.letterSpacingMM, into: &letterSpacingMM)
        try read(.wrapsText, into: &wrapsText); try read(.invertsText, into: &invertsText); try read(.outlined, into: &outlined)
        try read(.boxHeightMM, into: &boxHeightMM)
        try read(.barcodeNumberPosition, into: &barcodeNumberPosition); try read(.barcodeNumberSizeMM, into: &barcodeNumberSizeMM)
        try read(.barcodeQuietZone, into: &barcodeQuietZone); try read(.qrCorrection, into: &qrCorrection)
        try read(.invertsImage, into: &invertsImage); try read(.trimsImage, into: &trimsImage)
        try read(.iconWeight, into: &iconWeight); try read(.iconFilled, into: &iconFilled)
        try read(.barcodeType, into: &barcodeType)
        try read(.cropX, into: &cropX); try read(.cropY, into: &cropY); try read(.cropWidth, into: &cropWidth); try read(.cropHeight, into: &cropHeight)
        try read(.shapeKind, into: &shapeKind); try read(.shapeWidthMM, into: &shapeWidthMM); try read(.shapeHeightMM, into: &shapeHeightMM)
        try read(.lineWidthMM, into: &lineWidthMM); try read(.cornerRadiusMM, into: &cornerRadiusMM)
        try read(.shapeFilled, into: &shapeFilled); try read(.dashed, into: &dashed)
        try read(.dateFormat, into: &dateFormat); try read(.dateOffsetDays, into: &dateOffsetDays)
        try read(.counterNext, into: &counterNext); try read(.counterStep, into: &counterStep); try read(.counterDigits, into: &counterDigits)
        try read(.counterPrefix, into: &counterPrefix); try read(.counterSuffix, into: &counterSuffix)
    }
}
